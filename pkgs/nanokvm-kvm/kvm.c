// nanokvm-kvm: the NanoKVM's web KVM.
//
// One process, two threads:
//   - the video thread owns HDMI capture (/dev/video0, UYVY from the LT6911
//     bridge) and produces WebSocket messages in the selected mode:
//       tiles      changed 32x32 tiles of the native frame, LZ4-compressed
//       mjpeg      whole frames as JPEG (libjpeg-turbo), full size
//       mjpeg-half JPEG at half size, scaled by the VPSS when present
//       h264       Annex-B from sg2002-h264-bridge (VPSS + Coda980), only
//                  when built with the encoder
//   - the main thread serves the web UI over HTTP, fans video messages out
//     to WebSocket clients, and turns their input into USB HID reports
//     (/dev/hidg0 keyboard, /dev/hidg1 absolute mouse) and ATX button
//     presses (GPIO).
//
// Video is paced by the slowest client: the video thread emits a frame
// only when every client has drained the previous one, and in the meantime
// accumulates which tiles changed, so a slow link gets fewer, larger
// updates rather than a growing backlog.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <linux/dma-heap.h>
#include <linux/gpio.h>
#include <linux/v4l2-subdev.h>
#include <linux/videodev2.h>
#include <lz4.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
// jpeglib.h needs FILE.
#include <jpeglib.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef WEB_DIR
#define WEB_DIR "www"
#endif

#include <syslog.h>

extern char **environ;

// To syslog (runit services have no log of their own here) and stderr.
static void logf_(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vsyslog(LOG_INFO, fmt, ap);
	va_end(ap);
	va_start(ap, fmt);
	fputs("nanokvm-kvm: ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}
#define log logf_

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;
	do
		r = ioctl(fd, req, arg);
	while (r < 0 && errno == EINTR);
	return r;
}

// ---------------------------------------------------------------------------
// Messages: reference-counted, with room in front for the WebSocket header
// so every client sends the same bytes.

#define WS_HEADROOM 10

struct msg {
	atomic_int refs;
	size_t len;    // bytes from data + off
	size_t off;    // start of the WebSocket frame within data
	int key;       // h264: starts with an IDR picture
	uint8_t data[];
};

static struct msg *msg_new(size_t payload)
{
	struct msg *m = malloc(sizeof *m + WS_HEADROOM + payload);
	if (!m)
		return NULL;
	atomic_init(&m->refs, 1);
	m->len = payload;
	m->off = WS_HEADROOM;
	m->key = 0;
	return m;
}

static uint8_t *msg_payload(struct msg *m) { return m->data + WS_HEADROOM; }

// Writes the frame header in front of `len` payload bytes.
static void msg_frame(struct msg *m, size_t len, int text)
{
	uint8_t h[WS_HEADROOM];
	size_t n = 0;
	h[n++] = 0x80 | (text ? 1 : 2);
	if (len < 126)
		h[n++] = (uint8_t)len;
	else if (len < 65536) {
		h[n++] = 126;
		h[n++] = (uint8_t)(len >> 8);
		h[n++] = (uint8_t)len;
	} else {
		h[n++] = 127;
		for (int i = 7; i >= 0; i--)
			h[n++] = (uint8_t)(len >> (8 * i));
	}
	m->off = WS_HEADROOM - n;
	memcpy(m->data + m->off, h, n);
	m->len = n + len;
}

static struct msg *msg_text(const char *s)
{
	size_t len = strlen(s);
	struct msg *m = msg_new(len);
	if (!m)
		return NULL;
	memcpy(msg_payload(m), s, len);
	msg_frame(m, len, 1);
	return m;
}

static void msg_unref(struct msg *m)
{
	if (m && atomic_fetch_sub(&m->refs, 1) == 1)
		free(m);
}

// Video thread -> main thread queue.
static pthread_mutex_t q_lock = PTHREAD_MUTEX_INITIALIZER;
static struct msg *q_items[64];
static int q_len;
static int q_event;

static void post(struct msg *m)
{
	if (!m)
		return;
	pthread_mutex_lock(&q_lock);
	if (q_len < (int)(sizeof q_items / sizeof *q_items))
		q_items[q_len++] = m;
	else
		msg_unref(m);
	pthread_mutex_unlock(&q_lock);
	uint64_t one = 1;
	if (write(q_event, &one, 8) < 0) {
	}
}

// ---------------------------------------------------------------------------
// Shared state between the threads.

enum mode { MODE_TILES, MODE_MJPEG, MODE_MJPEG_HALF, MODE_H264, MODE_COUNT };
static const char *mode_names[MODE_COUNT] = { "tiles", "mjpeg", "mjpeg-half", "h264" };

static const char *h264_bridge; // NULL: no encoder
static int jpeg_quality = 70;
static int max_fps = 30;

static atomic_int want_mode = MODE_TILES;
static atomic_int want_frame;   // every client drained its queue
static atomic_int want_key;     // a client joined: send everything
static atomic_int n_viewers;

// Last status line from the video thread (JSON fields, no braces).
static pthread_mutex_t st_lock = PTHREAD_MUTEX_INITIALIZER;
static char video_status[256] = "\"signal\":false,\"width\":0,\"height\":0,\"fps\":0,\"kbps\":0";

static void set_video_status(int signal, int w, int h, double fps, double kbps, double enc_ms)
{
	pthread_mutex_lock(&st_lock);
	snprintf(video_status, sizeof video_status,
		 "\"signal\":%s,\"width\":%d,\"height\":%d,\"fps\":%.1f,\"kbps\":%.0f,\"encode_ms\":%.1f",
		 signal ? "true" : "false", w, h, fps, kbps, enc_ms);
	pthread_mutex_unlock(&st_lock);
}

// ---------------------------------------------------------------------------
// Device lookup by V4L2 name (mdev has no /dev/v4l/by-path).

static int find_v4l(const char *prefix, const char *needle, char *out, size_t outlen)
{
	DIR *d = opendir("/sys/class/video4linux");
	if (!d)
		return -1;
	struct dirent *e;
	int found = -1;
	while ((e = readdir(d))) {
		if (strncmp(e->d_name, prefix, strlen(prefix)) != 0)
			continue;
		char path[300], name[128] = "";
		snprintf(path, sizeof path, "/sys/class/video4linux/%s/name", e->d_name);
		FILE *f = fopen(path, "r");
		if (!f)
			continue;
		if (fgets(name, sizeof name, f) && strstr(name, needle)) {
			snprintf(out, outlen, "/dev/%s", e->d_name);
			found = 0;
		}
		fclose(f);
		if (!found)
			break;
	}
	closedir(d);
	return found;
}

// ---------------------------------------------------------------------------
// HDMI capture.

#define CAP_BUFS 3

// Capture buffers come from the CMA dma-heap when the kernel has one: those
// are mapped cached, so reading a frame runs at memory speed (with a cache
// invalidate per frame, DMA_BUF_IOCTL_SYNC). The driver's own MMAP buffers
// sit in a no-map pool and are mapped uncached: a 4 MB frame then takes
// ~85 ms just to read.
struct capture {
	int fd;
	int w, h, stride;
	int nbufs;
	enum v4l2_memory memory;
	void *mem[CAP_BUFS];
	size_t len[CAP_BUFS];
	int dmabuf[CAP_BUFS];
	struct v4l2_pix_format fmt;
};

// Returns 1 with the source size when the bridge reports a signal.
static int hdmi_signal(int *w, int *h)
{
	char path[64];
	if (find_v4l("v4l-subdev", "lt6911", path, sizeof path) < 0)
		return 0;
	int fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return 0;
	struct v4l2_dv_timings t = { 0 };
	int ok = xioctl(fd, VIDIOC_SUBDEV_QUERY_DV_TIMINGS, &t) == 0 && t.bt.width;
	close(fd);
	if (ok) {
		*w = (int)t.bt.width;
		*h = (int)t.bt.height;
	}
	return ok;
}

static void capture_close(struct capture *c)
{
	if (c->fd < 0)
		return;
	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	xioctl(c->fd, VIDIOC_STREAMOFF, &type);
	for (int i = 0; i < c->nbufs; i++) {
		if (c->mem[i])
			munmap(c->mem[i], c->len[i]);
		if (c->dmabuf[i] >= 0)
			close(c->dmabuf[i]);
	}
	struct v4l2_requestbuffers rb = { .count = 0, .type = type, .memory = c->memory };
	xioctl(c->fd, VIDIOC_REQBUFS, &rb);
	close(c->fd);
	c->fd = -1;
}

// A contiguous heap (CMA); the system heap's buffers are scattered, which
// the capture DMA cannot take.
static int cma_heap(void)
{
	DIR *d = opendir("/dev/dma_heap");
	struct dirent *e;
	int fd = -1;
	while (d && fd < 0 && (e = readdir(d))) {
		if (e->d_name[0] == '.' || !strcmp(e->d_name, "system"))
			continue;
		char p[300];
		snprintf(p, sizeof p, "/dev/dma_heap/%s", e->d_name);
		fd = open(p, O_RDONLY | O_CLOEXEC);
	}
	if (d)
		closedir(d);
	return fd;
}

static int capture_buffers(struct capture *c, enum v4l2_memory memory)
{
	int heap = -1;
	if (memory == V4L2_MEMORY_DMABUF && (heap = cma_heap()) < 0)
		return -1;
	c->memory = memory;
	struct v4l2_requestbuffers rb = { .count = CAP_BUFS, .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = memory };
	if (xioctl(c->fd, VIDIOC_REQBUFS, &rb) < 0 || rb.count < 1)
		goto fail;
	c->nbufs = rb.count < CAP_BUFS ? (int)rb.count : CAP_BUFS;
	for (int i = 0; i < c->nbufs; i++) {
		struct v4l2_buffer b = { .type = rb.type, .memory = memory, .index = (unsigned)i };
		if (memory == V4L2_MEMORY_DMABUF) {
			struct dma_heap_allocation_data a = { .len = c->fmt.sizeimage, .fd_flags = O_RDWR | O_CLOEXEC };
			if (xioctl(heap, DMA_HEAP_IOCTL_ALLOC, &a) < 0)
				goto fail;
			c->dmabuf[i] = (int)a.fd;
			c->len[i] = c->fmt.sizeimage;
			c->mem[i] = mmap(NULL, c->len[i], PROT_READ, MAP_SHARED, c->dmabuf[i], 0);
			b.m.fd = c->dmabuf[i];
			b.length = (unsigned)c->len[i];
		} else {
			if (xioctl(c->fd, VIDIOC_QUERYBUF, &b) < 0)
				goto fail;
			c->len[i] = b.length;
			c->mem[i] = mmap(NULL, b.length, PROT_READ, MAP_SHARED, c->fd, b.m.offset);
			struct v4l2_exportbuffer eb = { .type = rb.type, .index = (unsigned)i, .flags = O_CLOEXEC };
			if (xioctl(c->fd, VIDIOC_EXPBUF, &eb) == 0)
				c->dmabuf[i] = eb.fd;
		}
		if (c->mem[i] == MAP_FAILED) {
			c->mem[i] = NULL;
			goto fail;
		}
		if (xioctl(c->fd, VIDIOC_QBUF, &b) < 0)
			goto fail;
	}
	if (heap >= 0)
		close(heap);
	return 0;
fail:
	for (int i = 0; i < CAP_BUFS; i++) {
		if (c->mem[i])
			munmap(c->mem[i], c->len[i]);
		if (c->dmabuf[i] >= 0)
			close(c->dmabuf[i]);
		c->mem[i] = NULL;
		c->dmabuf[i] = -1;
	}
	rb.count = 0;
	xioctl(c->fd, VIDIOC_REQBUFS, &rb);
	c->nbufs = 0;
	if (heap >= 0)
		close(heap);
	return -1;
}

static int capture_open(struct capture *c, int w, int h)
{
	char path[64];
	memset(c, 0, sizeof *c);
	c->fd = -1;
	for (int i = 0; i < CAP_BUFS; i++)
		c->dmabuf[i] = -1;
	if (find_v4l("video", "CSI capture", path, sizeof path) < 0) {
		log("no HDMI capture device");
		return -1;
	}
	c->fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (c->fd < 0)
		return -1;
	struct v4l2_format f = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
	f.fmt.pix.width = (unsigned)w;
	f.fmt.pix.height = (unsigned)h;
	f.fmt.pix.pixelformat = V4L2_PIX_FMT_UYVY;
	f.fmt.pix.field = V4L2_FIELD_NONE;
	if (xioctl(c->fd, VIDIOC_S_FMT, &f) < 0 && xioctl(c->fd, VIDIOC_G_FMT, &f) < 0)
		goto fail;
	if (f.fmt.pix.pixelformat != V4L2_PIX_FMT_UYVY) {
		log("capture does not deliver UYVY");
		goto fail;
	}
	c->fmt = f.fmt.pix;
	c->w = (int)f.fmt.pix.width;
	c->h = (int)f.fmt.pix.height;
	c->stride = (int)f.fmt.pix.bytesperline;
	if (c->stride < c->w * 2)
		c->stride = c->w * 2;
	if (capture_buffers(c, V4L2_MEMORY_DMABUF) < 0) {
		log("capture: no cached CMA heap buffers, using the driver's uncached ones");
		if (capture_buffers(c, V4L2_MEMORY_MMAP) < 0)
			goto fail;
	}
	enum v4l2_buf_type type = f.type;
	if (xioctl(c->fd, VIDIOC_STREAMON, &type) < 0) {
		log("capture: STREAMON: %s", strerror(errno));
		goto fail;
	}
	return 0;
fail:
	capture_close(c);
	return -1;
}

static void dmabuf_sync(const struct capture *c, int idx, uint64_t flags)
{
	if (c->memory != V4L2_MEMORY_DMABUF)
		return;
	struct dma_buf_sync s = { .flags = flags | DMA_BUF_SYNC_READ };
	xioctl(c->dmabuf[idx], DMA_BUF_IOCTL_SYNC, &s);
}

// Takes the newest filled buffer (requeueing older ones), ready for the CPU.
static int capture_dq(struct capture *c, struct v4l2_buffer *b)
{
	*b = (struct v4l2_buffer){ .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = c->memory };
	if (xioctl(c->fd, VIDIOC_DQBUF, b) < 0)
		return -1;
	struct v4l2_buffer nb = { .type = b->type, .memory = c->memory };
	while (xioctl(c->fd, VIDIOC_DQBUF, &nb) == 0) {
		xioctl(c->fd, VIDIOC_QBUF, b);
		*b = nb;
		nb = (struct v4l2_buffer){ .type = b->type, .memory = c->memory };
	}
	dmabuf_sync(c, (int)b->index, DMA_BUF_SYNC_START);
	return 0;
}

static void capture_q(struct capture *c, struct v4l2_buffer *b)
{
	dmabuf_sync(c, (int)b->index, DMA_BUF_SYNC_END);
	if (c->memory == V4L2_MEMORY_DMABUF) {
		b->m.fd = c->dmabuf[b->index];
		b->length = (unsigned)c->len[b->index];
	}
	xioctl(c->fd, VIDIOC_QBUF, b);
}

// ---------------------------------------------------------------------------
// VPSS (mem2mem): UYVY capture buffer (imported DMA-BUF) -> NV12 at another
// size, into a CMA-heap buffer mapped cached. Used for mjpeg-half; falls
// back to CPU decimation if unavailable.

struct vpss {
	int fd;
	int w, h;   // output
	int out;    // NV12 output DMA-BUF
	void *mem;  // its cached mapping
	size_t len;
	int stride; // output Y stride
};

static void vpss_close(struct vpss *v)
{
	if (v->fd < 0)
		return;
	enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	xioctl(v->fd, VIDIOC_STREAMOFF, &t);
	t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	xioctl(v->fd, VIDIOC_STREAMOFF, &t);
	if (v->mem)
		munmap(v->mem, v->len);
	if (v->out >= 0)
		close(v->out);
	close(v->fd);
	v->fd = -1;
	v->out = -1;
	v->mem = NULL;
}

static int vpss_open(struct vpss *v, const struct capture *c, int ow, int oh)
{
	char path[64];
	memset(v, 0, sizeof *v);
	v->fd = v->out = -1;
	if (c->dmabuf[0] < 0 || find_v4l("video", "vpss", path, sizeof path) < 0)
		return -1;
	int heap = cma_heap();
	if (heap < 0)
		return -1;
	v->fd = open(path, O_RDWR | O_CLOEXEC);
	if (v->fd < 0)
		goto fail;
	struct v4l2_format in = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT };
	in.fmt.pix = c->fmt;
	in.fmt.pix.priv = V4L2_PIX_FMT_PRIV_MAGIC;
	struct v4l2_format out = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
	out.fmt.pix = c->fmt;
	out.fmt.pix.priv = V4L2_PIX_FMT_PRIV_MAGIC;
	out.fmt.pix.width = (unsigned)ow;
	out.fmt.pix.height = (unsigned)oh;
	out.fmt.pix.pixelformat = V4L2_PIX_FMT_NV12;
	out.fmt.pix.bytesperline = 0;
	out.fmt.pix.sizeimage = 0;
	if (xioctl(v->fd, VIDIOC_S_FMT, &in) < 0 || xioctl(v->fd, VIDIOC_S_FMT, &out) < 0 ||
	    out.fmt.pix.pixelformat != V4L2_PIX_FMT_NV12)
		goto fail;
	v->w = (int)out.fmt.pix.width;
	v->h = (int)out.fmt.pix.height;
	v->stride = (int)out.fmt.pix.bytesperline ? (int)out.fmt.pix.bytesperline : v->w;
	// The OUTPUT queue imports the capture buffers 1:1 by index.
	struct v4l2_requestbuffers rb = { .count = (unsigned)c->nbufs, .type = V4L2_BUF_TYPE_VIDEO_OUTPUT, .memory = V4L2_MEMORY_DMABUF };
	if (xioctl(v->fd, VIDIOC_REQBUFS, &rb) < 0)
		goto fail;
	rb = (struct v4l2_requestbuffers){ .count = 1, .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_DMABUF };
	if (xioctl(v->fd, VIDIOC_REQBUFS, &rb) < 0)
		goto fail;
	struct dma_heap_allocation_data a = { .len = out.fmt.pix.sizeimage, .fd_flags = O_RDWR | O_CLOEXEC };
	if (xioctl(heap, DMA_HEAP_IOCTL_ALLOC, &a) < 0)
		goto fail;
	v->out = (int)a.fd;
	v->len = out.fmt.pix.sizeimage;
	v->mem = mmap(NULL, v->len, PROT_READ, MAP_SHARED, v->out, 0);
	if (v->mem == MAP_FAILED) {
		v->mem = NULL;
		goto fail;
	}
	enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	if (xioctl(v->fd, VIDIOC_STREAMON, &t) < 0)
		goto fail;
	t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (xioctl(v->fd, VIDIOC_STREAMON, &t) < 0)
		goto fail;
	close(heap);
	return 0;
fail:
	close(heap);
	vpss_close(v);
	return -1;
}

// Scales capture buffer `idx` into v->mem; 0 on success.
static int vpss_run(struct vpss *v, const struct capture *c, int idx)
{
	struct v4l2_buffer src = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT, .memory = V4L2_MEMORY_DMABUF, .index = (unsigned)idx };
	src.m.fd = c->dmabuf[idx];
	src.length = (unsigned)c->len[idx];
	src.bytesused = (unsigned)(c->stride * c->h);
	struct v4l2_buffer dst = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_DMABUF, .index = 0 };
	dst.m.fd = v->out;
	dst.length = (unsigned)v->len;
	if (xioctl(v->fd, VIDIOC_QBUF, &dst) < 0 || xioctl(v->fd, VIDIOC_QBUF, &src) < 0)
		return -1;
	struct pollfd p = { .fd = v->fd, .events = POLLIN };
	if (poll(&p, 1, 1000) <= 0)
		return -1;
	if (xioctl(v->fd, VIDIOC_DQBUF, &src) < 0 || xioctl(v->fd, VIDIOC_DQBUF, &dst) < 0)
		return -1;
	struct dma_buf_sync s = { .flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ };
	xioctl(v->out, DMA_BUF_IOCTL_SYNC, &s);
	return (dst.flags & V4L2_BUF_FLAG_ERROR) ? -1 : 0;
}

static void vpss_done(struct vpss *v)
{
	struct dma_buf_sync s = { .flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ };
	xioctl(v->out, DMA_BUF_IOCTL_SYNC, &s);
}

// ---------------------------------------------------------------------------
// Encoders. `ref` is the last frame sent (a cached copy of the capture),
// updated tile by tile; `dirty` marks tiles changed since the last message.

#define TILE 32

struct tiles {
	int w, h, tw, th; // frame size, tiles across/down
	uint8_t *ref;     // w * h * 2, packed UYVY
	uint8_t *dirty;   // tw * th
	int any_dirty;
};

static void tiles_free(struct tiles *t)
{
	free(t->ref);
	free(t->dirty);
	memset(t, 0, sizeof *t);
}

static int tiles_init(struct tiles *t, int w, int h)
{
	tiles_free(t);
	t->w = w;
	t->h = h;
	t->tw = (w + TILE - 1) / TILE;
	t->th = (h + TILE - 1) / TILE;
	t->ref = calloc((size_t)w * h, 2);
	t->dirty = malloc((size_t)t->tw * t->th);
	if (!t->ref || !t->dirty)
		return -1;
	memset(t->dirty, 1, (size_t)t->tw * t->th);
	t->any_dirty = 1;
	return 0;
}

// musl's memcmp compares byte by byte. Tile rows start 8-byte aligned
// (tiles are 32 pixels, 64 bytes, wide); only a frame's last, narrower
// column can leave a tail.
static int same(const uint8_t *a, const uint8_t *b, size_t n)
{
	const uint64_t *x = (const uint64_t *)(const void *)a, *y = (const uint64_t *)(const void *)b;
	size_t words = n / 8;
	for (size_t i = 0; i < words; i++)
		if (x[i] != y[i])
			return 0;
	for (size_t i = words * 8; i < n; i++)
		if (a[i] != b[i])
			return 0;
	return 1;
}

// Compares the capture with `ref`, copies changed tiles and marks them.
// Returns the number of changed tiles.
static int tiles_update(struct tiles *t, const uint8_t *cap, int stride)
{
	int changed = 0;
	const size_t rb = (size_t)t->w * 2;
	for (int ty = 0; ty < t->th; ty++) {
		int y0 = ty * TILE, y1 = y0 + TILE < t->h ? y0 + TILE : t->h;
		for (int tx = 0; tx < t->tw; tx++) {
			int x0 = tx * TILE, x1 = x0 + TILE < t->w ? x0 + TILE : t->w;
			size_t bytes = (size_t)(x1 - x0) * 2;
			int y = y0;
			for (; y < y1; y++)
				if (!same(cap + (size_t)y * stride + x0 * 2, t->ref + y * rb + x0 * 2, bytes))
					break;
			if (y == y1)
				continue;
			for (; y < y1; y++)
				memcpy(t->ref + y * rb + x0 * 2, cap + (size_t)y * stride + x0 * 2, bytes);
			t->dirty[ty * t->tw + tx] = 1;
			changed++;
		}
	}
	if (changed)
		t->any_dirty = 1;
	return changed;
}

static void put16(uint8_t *p, unsigned v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t *p, uint32_t v) { put16(p, v & 0xffff); put16(p + 2, v >> 16); }

// Message: u8 1, u8 0, u16 w, u16 h, u16 count, then per tile
// u16 x, u16 y, u16 w, u16 h, u32 size, LZ4 block of the tile's UYVY rows.
static struct msg *tiles_message(struct tiles *t)
{
	int n = 0;
	for (int i = 0; i < t->tw * t->th; i++)
		n += t->dirty[i];
	if (!n)
		return NULL;
	const int raw = TILE * TILE * 2;
	size_t cap = 8 + (size_t)n * (12 + (size_t)LZ4_compressBound(raw));
	struct msg *m = msg_new(cap);
	if (!m)
		return NULL;
	uint8_t *p = msg_payload(m), *o = p + 8;
	p[0] = 1;
	p[1] = 0;
	put16(p + 2, (unsigned)t->w);
	put16(p + 4, (unsigned)t->h);
	put16(p + 6, (unsigned)n);
	static uint8_t buf[TILE * TILE * 2];
	const size_t rb = (size_t)t->w * 2;
	for (int ty = 0; ty < t->th; ty++)
		for (int tx = 0; tx < t->tw; tx++) {
			if (!t->dirty[ty * t->tw + tx])
				continue;
			t->dirty[ty * t->tw + tx] = 0;
			int x0 = tx * TILE, y0 = ty * TILE;
			int w = x0 + TILE < t->w ? TILE : t->w - x0;
			int h = y0 + TILE < t->h ? TILE : t->h - y0;
			for (int y = 0; y < h; y++)
				memcpy(buf + y * w * 2, t->ref + (y0 + y) * rb + x0 * 2, (size_t)w * 2);
			int size = LZ4_compress_default((const char *)buf, (char *)o + 12, w * h * 2,
							LZ4_compressBound(raw));
			put16(o, (unsigned)x0);
			put16(o + 2, (unsigned)y0);
			put16(o + 4, (unsigned)w);
			put16(o + 6, (unsigned)h);
			put32(o + 8, (uint32_t)size);
			o += 12 + size;
		}
	t->any_dirty = 0;
	msg_frame(m, (size_t)(o - p), 0);
	return m;
}

// JPEG from planar Y, Cb, Cr rows. `v420`: chroma has half the rows.
struct planes {
	int w, h;
	uint8_t *y, *u, *v;
	int ys, cs; // strides
	int v420;
};

// Message: u8 2, u8 0, u16 w, u16 h (the whole picture), u16 y, then a JPEG
// of the band of rows from y down: only the rows that changed are sent.
static struct msg *jpeg_message(const struct planes *pl, int quality, int fw, int fh, int y)
{
	struct jpeg_compress_struct c;
	struct jpeg_error_mgr e;
	unsigned char *out = NULL;
	unsigned long outlen = 0;
	c.err = jpeg_std_error(&e);
	jpeg_create_compress(&c);
	jpeg_mem_dest(&c, &out, &outlen);
	c.image_width = (unsigned)pl->w;
	c.image_height = (unsigned)pl->h;
	c.input_components = 3;
	c.in_color_space = JCS_YCbCr;
	jpeg_set_defaults(&c);
	jpeg_set_quality(&c, quality, TRUE);
	c.raw_data_in = TRUE;
	c.dct_method = JDCT_IFAST;
	c.comp_info[0].h_samp_factor = 2;
	c.comp_info[0].v_samp_factor = pl->v420 ? 2 : 1;
	c.comp_info[1].h_samp_factor = c.comp_info[1].v_samp_factor = 1;
	c.comp_info[2].h_samp_factor = c.comp_info[2].v_samp_factor = 1;
	jpeg_start_compress(&c, TRUE);
	const int rows = pl->v420 ? 16 : 8;
	const int ch = pl->v420 ? pl->h / 2 : pl->h;
	JSAMPROW ry[16], ru[8], rv[8];
	JSAMPARRAY arr[3] = { ry, ru, rv };
	while (c.next_scanline < c.image_height) {
		int l = (int)c.next_scanline;
		for (int i = 0; i < rows; i++)
			ry[i] = pl->y + (size_t)(l + i < pl->h ? l + i : pl->h - 1) * pl->ys;
		int cl = pl->v420 ? l / 2 : l;
		for (int i = 0; i < 8; i++) {
			int r = cl + i < ch ? cl + i : ch - 1;
			ru[i] = pl->u + (size_t)r * pl->cs;
			rv[i] = pl->v + (size_t)r * pl->cs;
		}
		jpeg_write_raw_data(&c, arr, (JDIMENSION)rows);
	}
	jpeg_finish_compress(&c);
	jpeg_destroy_compress(&c);
	struct msg *m = msg_new(8 + outlen);
	if (m) {
		uint8_t *p = msg_payload(m);
		p[0] = 2;
		p[1] = 0;
		put16(p + 2, (unsigned)fw);
		put16(p + 4, (unsigned)fh);
		put16(p + 6, (unsigned)y);
		memcpy(p + 8, out, outlen);
		msg_frame(m, 8 + outlen, 0);
	}
	free(out);
	return m;
}

// Planar 4:2:2 (full) or 4:2:0 (half, 2x2 decimation) from packed UYVY.
static void uyvy_planes(struct planes *pl, const uint8_t *src, int w, int h, int half)
{
	const size_t rb = (size_t)w * 2;
	if (!half) {
		pl->w = w;
		pl->h = h;
		pl->ys = w;
		pl->cs = w / 2;
		pl->v420 = 0;
		for (int y = 0; y < h; y++) {
			const uint8_t *s = src + y * rb;
			uint8_t *py = pl->y + (size_t)y * w, *pu = pl->u + (size_t)y * pl->cs, *pv = pl->v + (size_t)y * pl->cs;
			for (int x = 0; x < w / 2; x++) {
				pu[x] = s[4 * x];
				py[2 * x] = s[4 * x + 1];
				pv[x] = s[4 * x + 2];
				py[2 * x + 1] = s[4 * x + 3];
			}
		}
		return;
	}
	pl->w = w / 2;
	pl->h = h / 2;
	pl->ys = pl->w;
	pl->cs = pl->w / 2;
	pl->v420 = 1;
	for (int y = 0; y < pl->h; y++) {
		const uint8_t *s = src + (size_t)(2 * y) * rb;
		uint8_t *py = pl->y + (size_t)y * pl->ys;
		for (int x = 0; x < pl->w; x++)
			py[x] = s[4 * x + 1];
	}
	for (int y = 0; y < pl->h / 2; y++) {
		const uint8_t *s = src + (size_t)(4 * y) * rb;
		uint8_t *pu = pl->u + (size_t)y * pl->cs, *pv = pl->v + (size_t)y * pl->cs;
		for (int x = 0; x < pl->cs; x++) {
			pu[x] = s[8 * x];
			pv[x] = s[8 * x + 2];
		}
	}
}

// Planar 4:2:0 from rows [y0, y1) of the VPSS's NV12 output (y0 even).
static void nv12_planes(struct planes *pl, const uint8_t *nv12, int w, int h, int stride, int y0, int y1)
{
	pl->w = w;
	pl->h = y1 - y0;
	pl->ys = w;
	pl->cs = w / 2;
	pl->v420 = 1;
	for (int y = 0; y < pl->h; y++)
		memcpy(pl->y + (size_t)y * w, nv12 + (size_t)(y0 + y) * stride, (size_t)w);
	const uint8_t *uv = nv12 + (size_t)stride * h + (size_t)(y0 / 2) * stride;
	for (int y = 0; y < pl->h / 2; y++) {
		const uint8_t *s = uv + (size_t)y * stride;
		uint8_t *pu = pl->u + (size_t)y * pl->cs, *pv = pl->v + (size_t)y * pl->cs;
		for (int x = 0; x < w / 2; x++) {
			pu[x] = s[2 * x];
			pv[x] = s[2 * x + 1];
		}
	}
}

// ---------------------------------------------------------------------------
// C906L offload: nanokvm-kvm loads c906l/main.c's firmware into the region
// in lib/c906l.nix and starts the 700 MHz C906L there. In the MJPEG modes
// it encodes the bottom part of each changed band while this core encodes
// the top (protocol.h). Without the firmware or on any failure, everything
// runs here.

#include "c906l/protocol.h"

static const char *c906l_firmware; // --c906l PATH

static struct {
	int ready;
	uint8_t *region; // mapped cached; shared lines go through civa()
	volatile struct c906l_status *status;
	volatile struct c906l_job *job;
	uint8_t *out, *in;
	uint32_t seq;
	int active, w, h, y; // the band in flight: picture size, first row
	double t0;
} c906l;

// Clean and invalidate the data cache over [p, p + n): th.dcache.civa, the
// one T-Head cache operation user mode may execute, then th.sync.s.
static void civa(const volatile void *p, size_t n)
{
	uintptr_t a = (uintptr_t)p & ~(uintptr_t)63, end = (uintptr_t)p + n;
	for (; a < end; a += 64) {
		register uintptr_t a0 __asm__("a0") = a;
		__asm__ volatile(".long 0x0275000b" ::"r"(a0) : "memory");
	}
	__asm__ volatile(".long 0x0190000b" ::: "memory");
}

static void *devmem_map(int fd, unsigned long phys, size_t len)
{
	void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)phys);
	return p == MAP_FAILED ? NULL : p;
}

static void reg_update(volatile uint32_t *r, uint32_t clear, uint32_t set)
{
	*r = (*r & ~clear) | set;
	__sync_synchronize();
}

static void c906l_post(const struct c906l_job *j)
{
	volatile struct c906l_job *d = c906l.job;
	d->type = j->type;
	d->width = j->width;
	d->height = j->height;
	d->stride = j->stride;
	d->frame = j->frame;
	d->quality = j->quality;
	d->half = j->half;
	civa(d, sizeof *d);
	d->seq = ++c906l.seq;
	civa(d, sizeof *d);
	c906l.active = 1;
	c906l.t0 = now();
}

static const volatile struct c906l_status *c906l_status(void)
{
	civa(c906l.status, sizeof *c906l.status);
	return c906l.status;
}

// 1 when Linux owns none of the region: an older fip.bin, which does not
// hide it from Linux, leaves it in System RAM.
static int c906l_region_free(void)
{
	FILE *f = fopen("/proc/iomem", "r");
	char line[128];
	unsigned long a, b;
	int ok = f != NULL;
	while (ok && fgets(line, sizeof line, f))
		if (sscanf(line, "%lx-%lx", &a, &b) == 2 && strstr(line, ": System RAM") &&
		    a < C906L_BASE + C906L_SIZE && b >= C906L_BASE)
			ok = 0;
	if (f)
		fclose(f);
	return ok;
}

// Loads the firmware and (re)starts the C906L. A running firmware is parked
// first, so the reset never cuts it off mid-transfer (the TRM asks for a
// quiet bus).
static int c906l_start(void)
{
	if (!c906l_region_free()) {
		log("c906l: 0x%lx is Linux's memory (fip.bin predates the C906L); not starting it", C906L_BASE);
		return -1;
	}
	int fd = open("/dev/mem", O_RDWR | O_CLOEXEC);          // the region: cached
	int io = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC); // registers
	if (fd < 0 || io < 0) {
		log("c906l: /dev/mem: %s", strerror(errno));
		return -1;
	}
	c906l.region = devmem_map(fd, C906L_BASE, C906L_SIZE);
	volatile uint32_t *rst = devmem_map(io, 0x03003000, 4096);
	volatile uint32_t *sec = devmem_map(io, 0x020b0000, 4096);
	close(fd);
	close(io);
	if (!c906l.region || !rst || !sec) {
		log("c906l: cannot map the region or its control registers");
		return -1;
	}
	uint8_t *control = c906l.region + (C906L_CONTROL - C906L_BASE);
	c906l.status = (void *)control;
	c906l.job = (void *)(control + 64);
	c906l.out = c906l.region + (C906L_OUTPUT - C906L_BASE);
	c906l.in = c906l.region + (C906L_INPUT - C906L_BASE);

	if ((rst[0x24 / 4] & (1u << 6)) && c906l_status()->magic == C906L_MAGIC) {
		struct c906l_job park = { .type = C906L_JOB_PARK };
		c906l.seq = c906l_status()->done;
		c906l_post(&park);
		for (int i = 0; i < 100 && !c906l_status()->parked; i++)
			usleep(10000);
	}

	FILE *f = fopen(c906l_firmware, "rb");
	if (!f) {
		log("c906l: %s: %s", c906l_firmware, strerror(errno));
		return -1;
	}
	size_t n = fread(c906l.region, 1, C906L_CONTROL - C906L_BASE, f);
	fclose(f);
	memset(control, 0, 4096);
	civa(c906l.region, C906L_CONTROL - C906L_BASE + 4096);

	// The FSBL's reset_c906l: hold, set the reset vector, release.
	reg_update(&rst[0x24 / 4], 1u << 6, 0);
	reg_update(&sec[0x04 / 4], 0, 1u << 13);
	sec[0x20 / 4] = (uint32_t)C906L_BASE;
	sec[0x24 / 4] = (uint32_t)(C906L_BASE >> 32);
	__sync_synchronize();
	reg_update(&rst[0x24 / 4], 0, 1u << 6);

	uint32_t beat = 0;
	for (int i = 0; i < 100; i++) {
		usleep(10000);
		const volatile struct c906l_status *s = c906l_status();
		if (s->magic != C906L_MAGIC || s->version != C906L_VERSION)
			continue;
		if (!beat)
			beat = s->heartbeat + 1;
		else if (s->heartbeat >= beat) {
			c906l.seq = s->done;
			c906l.active = 0;
			c906l.ready = 1;
			log("c906l: firmware running (%zu bytes)", n);
			return 0;
		}
	}
	log("c906l: firmware did not come up");
	return -1;
}

static int c906l_done(void) { return c906l_status()->done == c906l.seq; }

// Waits for the job in flight; 0 when it finished, -1 when the C906L
// stopped answering (offload then turns off).
static int c906l_wait(void)
{
	for (int i = 0; i < 4000 && !c906l_done(); i++)
		usleep(500);
	c906l.active = 0;
	if (c906l_done())
		return 0;
	log("c906l: job %u timed out; compressing on this core from now on", c906l.seq);
	c906l.ready = 0;
	return -1;
}

// The finished band as a WebSocket message, or NULL.
static struct msg *c906l_message(void)
{
	const volatile struct c906l_status *s = c906l_status();
	uint32_t len = s->length;
	c906l.active = 0;
	if (s->result != C906L_OK || len > C906L_OUTPUT_SIZE) {
		log("c906l: job failed (%u)", s->result);
		return NULL;
	}
	struct msg *m = msg_new(8 + len);
	if (!m)
		return NULL;
	uint8_t *p = msg_payload(m);
	p[0] = 2;
	p[1] = 0;
	put16(p + 2, (unsigned)c906l.w);
	put16(p + 4, (unsigned)c906l.h);
	put16(p + 6, (unsigned)c906l.y);
	civa(c906l.out, len);
	memcpy(p + 8, c906l.out, len);
	msg_frame(m, 8 + len, 0);
	return m;
}

// Hands rows [y0, y1) of the frame to the C906L, copied into its input slot
// (at half size, only the even rows it reads; y0 is even).
static void c906l_submit(const uint8_t *frame, int stride, int w, int h, int y0, int y1, int half)
{
	const size_t rb = (size_t)w * 2;
	uint8_t *in = c906l.in + (size_t)y0 * rb;
	for (int y = y0; y < y1; y += half ? 2 : 1)
		memcpy(c906l.in + (size_t)y * rb, frame + (size_t)y * stride, rb);
	civa(in, rb * (size_t)(y1 - y0));
	struct c906l_job j = {
		.type = C906L_JOB_JPEG,
		.width = (uint32_t)w,
		.height = (uint32_t)(y1 - y0),
		.stride = (uint32_t)rb,
		.frame = C906L_INPUT + (uint64_t)y0 * rb,
		.quality = (uint32_t)jpeg_quality,
		.half = (uint32_t)half,
	};
	c906l.w = half ? w / 2 : w;
	c906l.h = half ? h / 2 : h;
	c906l.y = half ? y0 / 2 : y0;
	c906l_post(&j);
}

// ---------------------------------------------------------------------------
// H.264: sg2002-h264-bridge writes Annex-B to a pipe; split it into access
// units (one picture each, with any SPS/PPS/SEI in front).

struct h264 {
	pid_t pid;
	int fd;
	uint8_t *buf;
	size_t len, cap;
	int w, h;
};

static void h264_stop(struct h264 *s)
{
	if (s->pid > 0) {
		kill(s->pid, SIGTERM);
		waitpid(s->pid, NULL, 0);
	}
	if (s->fd >= 0)
		close(s->fd);
	free(s->buf);
	memset(s, 0, sizeof *s);
	s->fd = -1;
}

static int h264_start(struct h264 *s, int w, int h)
{
	char cap[64], enc[64], scl[64];
	memset(s, 0, sizeof *s);
	s->fd = -1;
	if (find_v4l("video", "CSI capture", cap, sizeof cap) < 0 ||
	    find_v4l("video", "coda", enc, sizeof enc) < 0 ||
	    find_v4l("video", "vpss", scl, sizeof scl) < 0) {
		log("h264: capture, Coda or VPSS device missing");
		return -1;
	}
	int p[2];
	if (pipe2(p, O_CLOEXEC) < 0)
		return -1;
	posix_spawn_file_actions_t fa;
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_adddup2(&fa, p[1], 1);
	char fps[16];
	snprintf(fps, sizeof fps, "%d", max_fps);
	// Every picture an IDR (--gop 1): the Coda980's P pictures smear static
	// content within a few frames of each IDR (seen on hardware, decoded by
	// ffmpeg too). Intra-only costs ~11 KB a frame on a desktop, ~3 Mbit/s
	// at 30 fps, and lets a lagging viewer resume at any frame.
	char *argv[] = { (char *)h264_bridge, cap, enc, "--scaler-node", scl, "--output", "-",
			 "--max-fps", fps, "--gop", "1", "--bitrate", "8000000", NULL };
	int r = posix_spawn(&s->pid, h264_bridge, &fa, NULL, argv, environ);
	posix_spawn_file_actions_destroy(&fa);
	close(p[1]);
	if (r != 0) {
		close(p[0]);
		log("h264: cannot run %s: %s", h264_bridge, strerror(r));
		return -1;
	}
	s->fd = p[0];
	s->w = w;
	s->h = h;
	return 0;
}

static size_t next_start(const uint8_t *b, size_t from, size_t len)
{
	for (size_t i = from; i + 3 <= len; i++)
		if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1)
			return i > 0 && b[i - 1] == 0 ? i - 1 : i;
	return len;
}

// Reads what the bridge wrote and posts every complete access unit.
// Returns -1 when the bridge is gone.
static int h264_pump(struct h264 *s, size_t *bytes_out, int *frames_out)
{
	if (s->cap - s->len < 65536) {
		s->cap = s->cap ? s->cap * 2 : 1 << 20;
		s->buf = realloc(s->buf, s->cap);
	}
	ssize_t n = read(s->fd, s->buf + s->len, s->cap - s->len);
	if (n <= 0)
		return n < 0 && errno == EINTR ? 0 : -1;
	s->len += (size_t)n;
	// An access unit ends where the NAL after a picture slice starts.
	size_t au = 0, i = next_start(s->buf, 0, s->len);
	int key = 0, pic = 0;
	while (i < s->len) {
		size_t sc = s->buf[i + 2] == 1 ? 3 : 4;
		if (i + sc >= s->len)
			break;
		size_t nxt = next_start(s->buf, i + sc, s->len);
		if (nxt == s->len)
			break; // incomplete NAL
		int type = s->buf[i + sc] & 0x1f;
		int vcl = type == 1 || type == 5;
		// A new picture starts with a non-VCL NAL (SPS, PPS, SEI, AUD) or a
		// slice whose first_mb_in_slice is 0 (ue(v) 0 is a single 1 bit).
		if (pic && (!vcl || (s->buf[i + sc + 1] & 0x80))) {
			// `i` starts the next unit: send [au, i).
			struct msg *m = msg_new(6 + (i - au));
			if (m) {
				uint8_t *p = msg_payload(m);
				p[0] = 3;
				p[1] = (uint8_t)key;
				put16(p + 2, (unsigned)s->w);
				put16(p + 4, (unsigned)s->h);
				memcpy(p + 6, s->buf + au, i - au);
				msg_frame(m, 6 + (i - au), 0);
				m->key = key;
				*bytes_out += i - au;
				(*frames_out)++;
				post(m);
			}
			au = i;
			key = pic = 0;
		}
		if (type == 1 || type == 5) {
			pic = 1;
			key |= type == 5;
		}
		i = nxt;
	}
	memmove(s->buf, s->buf + au, s->len - au);
	s->len -= au;
	return 0;
}

// ---------------------------------------------------------------------------
// Video thread.

struct vstat {
	double last_emit, enc_ms;
	int frames;
	size_t bytes;
};

// Queues a picture for the viewers and accounts for it.
static void emit(struct vstat *s, struct msg *m, double t0)
{
	if (!m)
		return;
	atomic_store(&want_frame, 0);
	s->bytes += m->len;
	s->frames++;
	s->last_emit = t0;
	double dt = (now() - t0) * 1000;
	s->enc_ms = s->enc_ms ? s->enc_ms * 0.8 + dt * 0.2 : dt;
	post(m);
}

// The C906L's share of a band's rows. It encodes its part while this core
// encodes the rest and then goes on to the next frame; the share grows
// while its band is done by the time the next one is due, and shrinks
// when this core has to wait for it.
static double c906l_share = 0.4;

// Sends the C906L's finished band. `wait`: the next band is due, so wait
// for it (pictures go out in order); else only take a band already done.
static void c906l_collect(struct vstat *vs, int wait)
{
	if (!c906l.active || (!wait && !c906l_done()))
		return;
	double t = now();
	if (c906l_wait() < 0) {
		atomic_store(&want_key, 1); // its rows never arrive: resend all
		return;
	}
	// Done before its successor was due: give it more; waited for: less.
	c906l_share *= wait && now() - t > 0.001 ? 0.95 : 1.03;
	c906l_share = c906l_share < 0.1 ? 0.1 : c906l_share > 0.9 ? 0.9 : c906l_share;
	struct msg *m = c906l_message();
	if (m) {
		vs->bytes += m->len;
		post(m);
	}
}

// On reconfiguring: wait out the band in flight and drop it.
static void c906l_drain(void)
{
	if (c906l.active)
		c906l_wait();
}

// Rows [y0, y1) of the dirty tile rows, which are then clean.
static void tiles_take_rows(struct tiles *t, int *y0, int *y1)
{
	int r0 = t->th, r1 = -1;
	for (int ty = 0; ty < t->th; ty++)
		for (int tx = 0; tx < t->tw; tx++)
			if (t->dirty[ty * t->tw + tx]) {
				r0 = ty < r0 ? ty : r0;
				r1 = ty;
				break;
			}
	memset(t->dirty, 0, (size_t)t->tw * t->th);
	t->any_dirty = 0;
	*y0 = r0 * TILE;
	*y1 = (r1 + 1) * TILE < t->h ? (r1 + 1) * TILE : t->h;
}

// This core's JPEG of source rows [y0, y1): from the VPSS's half-size NV12
// when there is one, else from the reference frame.
static struct msg *jpeg_band(struct planes *pl, const struct tiles *t, const uint8_t *nv12, int nv12_stride,
			     int half, int y0, int y1)
{
	if (nv12)
		nv12_planes(pl, nv12, t->w / 2, t->h / 2, nv12_stride, y0 / 2, y1 / 2);
	else
		uyvy_planes(pl, t->ref + (size_t)y0 * t->w * 2, t->w, y1 - y0, half);
	return half ? jpeg_message(pl, jpeg_quality, t->w / 2, t->h / 2, y0 / 2)
		    : jpeg_message(pl, jpeg_quality, t->w, t->h, y0);
}

// Sends source rows [y0, y1) as JPEG. With the C906L up, it takes the
// bottom part, which goes out when done (c906l_collect), and this core
// encodes the top.
static void mjpeg_send(struct vstat *vs, double t0, struct planes *pl, const struct tiles *t, const uint8_t *frame,
		       int stride, const uint8_t *nv12, int nv12_stride, int half, int y0, int y1)
{
	const int mcu = half ? 32 : 16; // source rows per JPEG MCU row
	int split = y1;
	c906l_collect(vs, 1);
	if (c906l.ready && (size_t)t->w * t->h * 2 <= C906L_INPUT_SIZE && y1 - y0 >= 2 * mcu) {
		split = y0 + (int)((y1 - y0) * (1 - c906l_share)) / mcu * mcu;
		if (split < y0 + mcu)
			split = y0 + mcu;
		if (split >= y1)
			split = y0 + (y1 - y0 - 1) / mcu * mcu;
		c906l_submit(frame, stride, t->w, t->h, split, y1, half);
	}
	emit(vs, jpeg_band(pl, t, nv12, nv12_stride, half, y0, split), t0);
	c906l_collect(vs, 0);
}

static void *video_main(void *arg)
{
	(void)arg;
	struct capture cap = { .fd = -1 };
	struct vpss vp = { .fd = -1 };
	struct tiles tl = { 0 };
	struct h264 hs = { .fd = -1 };
	struct planes pl = { 0 };
	int mode = -1, sw = 0, sh = 0;
	double stat_t = now();
	struct vstat vs = { 0 };
	int vpss_ok = 0;

	for (;;) {
		int want = atomic_load(&want_mode);
		int w = 0, h = 0, sig = hdmi_signal(&w, &h);
		int idle = atomic_load(&n_viewers) == 0;

		// (Re)configure on mode, signal or size changes; stop when nobody
		// is watching.
		int running = cap.fd >= 0 || hs.fd >= 0;
		if (running && (idle || !sig || want != mode || w != sw || h != sh)) {
			c906l_drain();
			capture_close(&cap);
			vpss_close(&vp);
			h264_stop(&hs);
			running = 0;
		}
		if (!running && sig && !idle) {
			mode = want;
			sw = w;
			sh = h;
			if (mode == MODE_H264) {
				if (h264_start(&hs, w, h) < 0) {
					sleep(2);
					continue;
				}
			} else {
				if (capture_open(&cap, w, h) < 0) {
					sleep(1);
					continue;
				}
				tiles_init(&tl, cap.w, cap.h);
				free(pl.y);
				pl.y = malloc((size_t)cap.w * cap.h * 2);
				pl.u = pl.y + (size_t)cap.w * cap.h;
				pl.v = pl.u + (size_t)cap.w * cap.h / 2;
				vpss_ok = mode == MODE_MJPEG_HALF && vpss_open(&vp, &cap, cap.w / 2, cap.h / 2) == 0;
				log("streaming %s %dx%d%s", mode_names[mode], cap.w, cap.h,
				    mode == MODE_MJPEG_HALF ? (vpss_ok ? " (VPSS scaling)" : " (CPU scaling)") : "");
			}
			atomic_store(&want_key, 1);
		}
		if (!running && (!sig || idle)) {
			double t = now();
			if (t - stat_t >= 1) {
				set_video_status(sig, w, h, 0, 0, 0);
				stat_t = t;
			}
			usleep(idle ? 250000 : 500000);
			continue;
		}

		if (hs.fd >= 0) {
			struct pollfd p = { .fd = hs.fd, .events = POLLIN };
			if (poll(&p, 1, 1000) > 0 && h264_pump(&hs, &vs.bytes, &vs.frames) < 0) {
				log("h264 bridge exited");
				h264_stop(&hs);
				sleep(1);
			}
		} else if (cap.fd >= 0) {
			struct pollfd p = { .fd = cap.fd, .events = POLLIN };
			if (poll(&p, 1, 1000) <= 0) {
				c906l_drain();
				capture_close(&cap); // signal lost or stalled; re-probe
				vpss_close(&vp);
				continue;
			}
			// Take the newest frame, requeue older ones.
			struct v4l2_buffer b;
			if (capture_dq(&cap, &b) < 0)
				continue;
			double t0 = now();
			c906l_collect(&vs, 0);
			int key = atomic_exchange(&want_key, 0);
			if (key) {
				memset(tl.dirty, 1, (size_t)tl.tw * tl.th);
				tl.any_dirty = 1;
			}
			const uint8_t *frame = cap.mem[b.index];
			if (!(b.flags & V4L2_BUF_FLAG_ERROR) && t0 - vs.last_emit >= 1.0 / max_fps &&
			    atomic_load(&want_frame)) {
				tiles_update(&tl, frame, cap.stride);
				if (tl.any_dirty && mode == MODE_TILES)
					emit(&vs, tiles_message(&tl), t0);
				else if (tl.any_dirty) {
					int y0, y1, half = mode == MODE_MJPEG_HALF;
					tiles_take_rows(&tl, &y0, &y1);
					const uint8_t *nv12 = NULL;
					if (half && vpss_ok && vpss_run(&vp, &cap, (int)b.index) == 0)
						nv12 = vp.mem;
					mjpeg_send(&vs, t0, &pl, &tl, frame, cap.stride, nv12, vp.stride, half, y0, y1);
					if (nv12)
						vpss_done(&vp);
				}
			}
			capture_q(&cap, &b);
		}

		double t = now();
		if (t - stat_t >= 1) {
			set_video_status(1, sw, sh, vs.frames / (t - stat_t), vs.bytes * 8 / 1000.0 / (t - stat_t), vs.enc_ms);
			vs.frames = 0;
			vs.bytes = 0;
			stat_t = t;
		}
	}
	return NULL;
}

// ---------------------------------------------------------------------------
// USB HID.

static int hid_kbd = -1, hid_mouse = -1;
static uint8_t kbd_mods, kbd_keys[6];
static uint8_t kbd_leds;

struct report { int fd; uint8_t len; uint8_t data[8]; };
static struct report hid_q[1024];
static int hid_qh, hid_qn;

static void hid_open(void)
{
	if (hid_kbd < 0)
		hid_kbd = open("/dev/hidg0", O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (hid_mouse < 0)
		hid_mouse = open("/dev/hidg1", O_RDWR | O_NONBLOCK | O_CLOEXEC);
}

// USB gadget on the HID port: a boot keyboard (hidg0) and an absolute
// pointer (hidg1), which needs no pointer acceleration on the target.
static const uint8_t kbd_desc[] = {
	0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00, 0x25, 0x01,
	0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x03, 0x95, 0x05, 0x75, 0x01,
	0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x03, 0x95, 0x06,
	0x75, 0x08, 0x15, 0x00, 0x26, 0xff, 0x00, 0x05, 0x07, 0x19, 0x00, 0x2a, 0xff, 0x00, 0x81, 0x00,
	0xc0,
};
static const uint8_t mouse_desc[] = {
	0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x05,
	0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x03, 0x81, 0x03,
	0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00, 0x26, 0xff, 0x7f, 0x75, 0x10, 0x95, 0x02, 0x81,
	0x02, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06, 0xc0, 0xc0,
};

static int put_file(const char *dir, const char *name, const void *data, size_t len)
{
	char p[256];
	snprintf(p, sizeof p, "%s/%s", dir, name);
	int fd = open(p, O_WRONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	ssize_t n = write(fd, data, len);
	close(fd);
	return n == (ssize_t)len ? 0 : -1;
}
#define put_str(dir, name, s) put_file(dir, name, s, strlen(s))

static void gadget_setup(void)
{
	const char *g = "/sys/kernel/config/usb_gadget/nanokvm";
	char p[256];
	if (access(g, F_OK) == 0 || mkdir(g, 0755) < 0) {
		return;
	}
	put_str(g, "idVendor", "0x1d6b");  // Linux Foundation
	put_str(g, "idProduct", "0x0104"); // multifunction composite gadget
	put_str(g, "bcdDevice", "0x0100");
	snprintf(p, sizeof p, "%s/strings/0x409", g);
	mkdir(p, 0755);
	put_str(p, "manufacturer", "nixos-nanokvm");
	put_str(p, "product", "NanoKVM keyboard and mouse");
	put_str(p, "serialnumber", "nanokvm");
	snprintf(p, sizeof p, "%s/configs/c.1", g);
	mkdir(p, 0755);
	put_str(p, "MaxPower", "100");
	snprintf(p, sizeof p, "%s/configs/c.1/strings/0x409", g);
	mkdir(p, 0755);
	put_str(p, "configuration", "HID");
	struct { const char *name, *protocol, *len; const uint8_t *desc; size_t dlen; } fn[] = {
		{ "hid.keyboard", "1", "8", kbd_desc, sizeof kbd_desc },
		{ "hid.mouse", "2", "6", mouse_desc, sizeof mouse_desc },
	};
	for (size_t i = 0; i < 2; i++) {
		snprintf(p, sizeof p, "%s/functions/%s", g, fn[i].name);
		mkdir(p, 0755);
		put_str(p, "protocol", fn[i].protocol);
		put_str(p, "subclass", i == 0 ? "1" : "0");
		put_str(p, "report_length", fn[i].len);
		put_file(p, "report_desc", fn[i].desc, fn[i].dlen);
		char link[256];
		snprintf(link, sizeof link, "%s/configs/c.1/%s", g, fn[i].name);
		if (symlink(p, link) < 0)
			log("gadget: %s: %s", link, strerror(errno));
	}
	DIR *d = opendir("/sys/class/udc");
	struct dirent *e;
	while (d && (e = readdir(d)))
		if (e->d_name[0] != '.') {
			if (put_str(g, "UDC", e->d_name) < 0)
				log("gadget: bind %s: %s", e->d_name, strerror(errno));
			break;
		}
	if (d)
		closedir(d);
}

static void hid_queue(int fd, const uint8_t *data, int len)
{
	if (fd < 0)
		return;
	// Coalesce pointer motion: replace a queued mouse report with the same
	// buttons and no wheel.
	if (fd == hid_mouse && hid_qn) {
		struct report *last = &hid_q[(hid_qh + hid_qn - 1) % 1024];
		if (last->fd == fd && last->data[0] == data[0] && last->data[5] == 0 && data[5] == 0) {
			memcpy(last->data, data, (size_t)len);
			return;
		}
	}
	if (hid_qn == 1024)
		return;
	struct report *r = &hid_q[(hid_qh + hid_qn++) % 1024];
	r->fd = fd;
	r->len = (uint8_t)len;
	memcpy(r->data, data, (size_t)len);
}

// Writes queued reports until the host stops taking them.
static void hid_flush(void)
{
	while (hid_qn) {
		struct report *r = &hid_q[hid_qh];
		ssize_t n = write(r->fd, r->data, r->len);
		if (n < 0 && errno == EAGAIN)
			return;
		if (n < 0 && errno != EINTR) {
			// Host gone (ESHUTDOWN): drop what is queued.
			hid_qn = 0;
			return;
		}
		hid_qh = (hid_qh + 1) % 1024;
		hid_qn--;
	}
}

static void kbd_send(void)
{
	uint8_t r[8] = { kbd_mods, 0 };
	memcpy(r + 2, kbd_keys, 6);
	hid_queue(hid_kbd, r, 8);
}

static void kbd_key(int usage, int down)
{
	if (usage >= 0xe0 && usage <= 0xe7) {
		uint8_t bit = (uint8_t)(1 << (usage - 0xe0));
		kbd_mods = down ? kbd_mods | bit : kbd_mods & (uint8_t)~bit;
	} else if (usage > 0 && usage < 256) {
		int at = -1;
		for (int i = 0; i < 6; i++)
			if (kbd_keys[i] == usage)
				at = i;
		if (down && at < 0) {
			for (int i = 0; i < 6; i++)
				if (!kbd_keys[i]) {
					kbd_keys[i] = (uint8_t)usage;
					break;
				}
		} else if (!down && at >= 0) {
			memmove(kbd_keys + at, kbd_keys + at + 1, (size_t)(5 - at));
			kbd_keys[5] = 0;
		}
	} else
		return;
	kbd_send();
}

static void kbd_release(void)
{
	kbd_mods = 0;
	memset(kbd_keys, 0, sizeof kbd_keys);
	kbd_send();
}

static void mouse_abs(int x, int y, int buttons, int wheel)
{
	x = x < 0 ? 0 : x > 32767 ? 32767 : x;
	y = y < 0 ? 0 : y > 32767 ? 32767 : y;
	wheel = wheel < -127 ? -127 : wheel > 127 ? 127 : wheel;
	uint8_t r[6] = { (uint8_t)buttons, (uint8_t)x, (uint8_t)(x >> 8), (uint8_t)y, (uint8_t)(y >> 8), (uint8_t)(int8_t)wheel };
	hid_queue(hid_mouse, r, 6);
}

static const char *usb_state(void)
{
	static char s[32];
	FILE *f = NULL;
	DIR *d = opendir("/sys/class/udc");
	struct dirent *e;
	strcpy(s, "none");
	while (d && (e = readdir(d))) {
		if (e->d_name[0] == '.')
			continue;
		char p[300];
		snprintf(p, sizeof p, "/sys/class/udc/%s/state", e->d_name);
		if ((f = fopen(p, "r"))) {
			if (fgets(s, sizeof s, f))
				s[strcspn(s, "\n")] = 0;
			fclose(f);
		}
	}
	if (d)
		closedir(d);
	return s;
}

// ---------------------------------------------------------------------------
// ATX header: GPIOA23 power button, GPIOA25 reset button (outputs, high
// presses), GPIOA24 power LED (input, low while the LED is lit), as in
// Sipeed's server. The service muxes the pads.

static int atx_buttons = -1, atx_led = -1;
static int atx_release_line = -1;
static double atx_release_at;

static int gpio_chip_by_label(const char *label)
{
	for (int i = 0; i < 16; i++) {
		char p[32];
		snprintf(p, sizeof p, "/dev/gpiochip%d", i);
		int fd = open(p, O_RDWR | O_CLOEXEC);
		if (fd < 0)
			continue;
		struct gpiochip_info ci = { 0 };
		if (xioctl(fd, GPIO_GET_CHIPINFO_IOCTL, &ci) == 0 && !strcmp(ci.label, label))
			return fd;
		close(fd);
	}
	return -1;
}

static void atx_open(void)
{
	int chip = gpio_chip_by_label("3020000.gpio");
	if (chip < 0) {
		log("ATX: GPIO port A not found");
		return;
	}
	struct gpio_v2_line_request r = { .offsets = { 23, 25 }, .num_lines = 2 };
	r.config.flags = GPIO_V2_LINE_FLAG_OUTPUT;
	strcpy(r.consumer, "nanokvm-atx");
	if (xioctl(chip, GPIO_V2_GET_LINE_IOCTL, &r) == 0)
		atx_buttons = r.fd;
	else
		log("ATX buttons: %s", strerror(errno));
	struct gpio_v2_line_request l = { .offsets = { 24 }, .num_lines = 1 };
	l.config.flags = GPIO_V2_LINE_FLAG_INPUT;
	strcpy(l.consumer, "nanokvm-atx-led");
	if (xioctl(chip, GPIO_V2_GET_LINE_IOCTL, &l) == 0)
		atx_led = l.fd;
	close(chip);
}

static void atx_set(int line, int on)
{
	if (atx_buttons < 0)
		return;
	struct gpio_v2_line_values v = { .mask = 1ull << line, .bits = on ? 1ull << line : 0 };
	xioctl(atx_buttons, GPIO_V2_LINE_SET_VALUES_IOCTL, &v);
}

static void atx_press(int line, int ms)
{
	if (atx_release_line >= 0)
		atx_set(atx_release_line, 0);
	atx_set(line, 1);
	atx_release_line = line;
	atx_release_at = now() + ms / 1000.0;
}

static int atx_power_led(void)
{
	if (atx_led < 0)
		return -1;
	struct gpio_v2_line_values v = { .mask = 1 };
	if (xioctl(atx_led, GPIO_V2_LINE_GET_VALUES_IOCTL, &v) < 0)
		return -1;
	return !(v.bits & 1); // the LED input is active low
}

// ---------------------------------------------------------------------------
// HTTP + WebSocket.

static void sha1(const uint8_t *data, size_t len, uint8_t out[20])
{
	uint32_t h[5] = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 };
	size_t total = ((len + 8) / 64 + 1) * 64;
	uint8_t *m = calloc(total, 1);
	memcpy(m, data, len);
	m[len] = 0x80;
	uint64_t bits = (uint64_t)len * 8;
	for (int i = 0; i < 8; i++)
		m[total - 1 - i] = (uint8_t)(bits >> (8 * i));
	for (size_t off = 0; off < total; off += 64) {
		uint32_t w[80];
		for (int i = 0; i < 16; i++)
			w[i] = (uint32_t)m[off + 4 * i] << 24 | (uint32_t)m[off + 4 * i + 1] << 16 |
			       (uint32_t)m[off + 4 * i + 2] << 8 | m[off + 4 * i + 3];
		for (int i = 16; i < 80; i++) {
			uint32_t x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
			w[i] = x << 1 | x >> 31;
		}
		uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
		for (int i = 0; i < 80; i++) {
			uint32_t f, k;
			if (i < 20) { f = (b & c) | (~b & d); k = 0x5A827999; }
			else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1; }
			else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
			else { f = b ^ c ^ d; k = 0xCA62C1D6; }
			uint32_t t = (a << 5 | a >> 27) + f + e + k + w[i];
			e = d; d = c; c = b << 30 | b >> 2; b = a; a = t;
		}
		h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
	}
	free(m);
	for (int i = 0; i < 5; i++)
		for (int j = 0; j < 4; j++)
			out[4 * i + j] = (uint8_t)(h[i] >> (24 - 8 * j));
}

static void base64(const uint8_t *in, size_t len, char *out)
{
	static const char t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	size_t o = 0;
	for (size_t i = 0; i < len; i += 3) {
		uint32_t v = (uint32_t)in[i] << 16 | (i + 1 < len ? (uint32_t)in[i + 1] << 8 : 0) | (i + 2 < len ? in[i + 2] : 0);
		out[o++] = t[v >> 18 & 63];
		out[o++] = t[v >> 12 & 63];
		out[o++] = i + 1 < len ? t[v >> 6 & 63] : '=';
		out[o++] = i + 2 < len ? t[v & 63] : '=';
	}
	out[o] = 0;
}

#define MAX_CLIENTS 8
#define OUT_MAX 64

struct client {
	int fd;
	int ws;            // upgraded
	int closing;       // close after the queue drains
	int need_key;      // h264: skip until the next IDR
	uint8_t in[65536];
	size_t in_len;
	struct msg *out[OUT_MAX];
	int out_n;
	size_t out_off;    // bytes of out[0] already sent
};

static struct client clients[MAX_CLIENTS];

static void client_drop(struct client *c)
{
	for (int i = 0; i < c->out_n; i++)
		msg_unref(c->out[i]);
	if (c->ws)
		atomic_fetch_sub(&n_viewers, 1);
	close(c->fd);
	memset(c, 0, sizeof *c);
	c->fd = -1;
}

static void client_send(struct client *c, struct msg *m)
{
	if (c->out_n == OUT_MAX) {
		msg_unref(m);
		return;
	}
	c->out[c->out_n++] = m;
}

static void send_text(struct client *c, const char *s)
{
	struct msg *m = msg_text(s);
	if (m)
		client_send(c, m);
}

// Returns -1 on a dead connection.
static int client_flush(struct client *c)
{
	while (c->out_n) {
		struct msg *m = c->out[0];
		ssize_t n = send(c->fd, m->data + m->off + c->out_off, m->len - c->out_off, MSG_NOSIGNAL);
		if (n < 0)
			return errno == EAGAIN || errno == EINTR ? 0 : -1;
		c->out_off += (size_t)n;
		if (c->out_off < m->len)
			return 0;
		msg_unref(m);
		memmove(c->out, c->out + 1, sizeof *c->out * (size_t)--c->out_n);
		c->out_off = 0;
	}
	return c->closing ? -1 : 0;
}

static const char *content_type(const char *path)
{
	const char *ext = strrchr(path, '.');
	if (!ext)
		return "application/octet-stream";
	if (!strcmp(ext, ".html"))
		return "text/html; charset=utf-8";
	if (!strcmp(ext, ".js"))
		return "text/javascript; charset=utf-8";
	if (!strcmp(ext, ".css"))
		return "text/css; charset=utf-8";
	if (!strcmp(ext, ".svg"))
		return "image/svg+xml";
	return "application/octet-stream";
}

static void http_reply(struct client *c, int code, const char *type, const void *body, size_t len)
{
	char head[256];
	int n = snprintf(head, sizeof head,
			 "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
			 "Cache-Control: no-cache\r\nConnection: close\r\n\r\n",
			 code, code == 200 ? "OK" : "Not Found", type, len);
	struct msg *m = msg_new((size_t)n + len);
	if (!m)
		return;
	memcpy(msg_payload(m), head, (size_t)n);
	memcpy(msg_payload(m) + n, body, len);
	m->len = (size_t)n + len;
	client_send(c, m);
	c->closing = 1;
}

static void serve_file(struct client *c, const char *url)
{
	char path[512];
	if (!strcmp(url, "/"))
		url = "/index.html";
	if (strstr(url, "..") || strlen(url) > 100) {
		http_reply(c, 404, "text/plain", "not found\n", 10);
		return;
	}
	snprintf(path, sizeof path, "%s%s", WEB_DIR, url);
	FILE *f = fopen(path, "rb");
	if (!f) {
		http_reply(c, 404, "text/plain", "not found\n", 10);
		return;
	}
	fseek(f, 0, SEEK_END);
	long len = ftell(f);
	fseek(f, 0, SEEK_SET);
	char *body = malloc((size_t)len);
	if (body && fread(body, 1, (size_t)len, f) == (size_t)len)
		http_reply(c, 200, content_type(path), body, (size_t)len);
	free(body);
	fclose(f);
}

static void status_json(char *out, size_t len)
{
	char modes[96] = "";
	for (int i = 0; i < MODE_COUNT; i++) {
		if (i == MODE_H264 && !h264_bridge)
			continue;
		size_t l = strlen(modes);
		snprintf(modes + l, sizeof modes - l, "%s\"%s\"", l ? "," : "", mode_names[i]);
	}
	pthread_mutex_lock(&st_lock);
	snprintf(out, len,
		 "{\"t\":\"status\",\"mode\":\"%s\",\"modes\":[%s],%s,\"usb\":\"%s\",\"power_led\":%d,"
		 "\"leds\":%d,\"viewers\":%d,\"c906l\":%s}",
		 mode_names[atomic_load(&want_mode)], modes, video_status, usb_state(), atx_power_led(),
		 kbd_leds, atomic_load(&n_viewers), c906l.ready ? "true" : "false");
	pthread_mutex_unlock(&st_lock);
}

// Client commands, one per text message:
//   k USAGE DOWN        key (HID usage id), DOWN 1 or 0
//   m X Y BUTTONS WHEEL absolute pointer, X/Y 0..32767
//   r                   release every key
//   mode NAME           switch the video mode for everyone
//   key                 request a full picture
//   atx power|reset MS  hold an ATX button for MS milliseconds
static void ws_command(struct client *c, char *s)
{
	int a, b, d, e;
	char word[16];
	if (sscanf(s, "k %d %d", &a, &b) == 2)
		kbd_key(a, b);
	else if (sscanf(s, "m %d %d %d %d", &a, &b, &d, &e) == 4)
		mouse_abs(a, b, d, e);
	else if (!strcmp(s, "r"))
		kbd_release();
	else if (sscanf(s, "mode %15s", word) == 1) {
		for (int i = 0; i < MODE_COUNT; i++)
			if (!strcmp(word, mode_names[i]) && (i != MODE_H264 || h264_bridge))
				atomic_store(&want_mode, i);
	} else if (!strcmp(s, "key")) {
		atomic_store(&want_key, 1);
		c->need_key = 1;
	} else if (sscanf(s, "atx %15s %d", word, &a) == 2 && a > 0 && a <= 10000) {
		if (!strcmp(word, "power"))
			atx_press(23, a);
		else if (!strcmp(word, "reset"))
			atx_press(25, a);
	}
}

// Parses complete client frames out of c->in. Returns -1 to drop.
static int ws_input(struct client *c)
{
	size_t pos = 0;
	while (c->in_len - pos >= 2) {
		uint8_t *p = c->in + pos;
		int op = p[0] & 0x0f, masked = p[1] & 0x80;
		uint64_t len = p[1] & 0x7f;
		size_t h = 2;
		if (len == 126) {
			if (c->in_len - pos < 4)
				break;
			len = (uint64_t)p[2] << 8 | p[3];
			h = 4;
		} else if (len == 127)
			return -1; // nothing we accept is that large
		if (!masked || len > sizeof c->in - 16)
			return -1;
		if (c->in_len - pos < h + 4 + len)
			break;
		uint8_t *mask = p + h, *data = p + h + 4;
		for (uint64_t i = 0; i < len; i++)
			data[i] ^= mask[i % 4];
		if (op == 8)
			return -1;
		if (op == 1) {
			char cmd[256];
			size_t n = len < sizeof cmd - 1 ? (size_t)len : sizeof cmd - 1;
			memcpy(cmd, data, n);
			cmd[n] = 0;
			ws_command(c, cmd);
		} else if (op == 9) {
			struct msg *m = msg_new((size_t)len);
			if (m) {
				memcpy(msg_payload(m), data, (size_t)len);
				msg_frame(m, (size_t)len, 0);
				m->data[m->off] = 0x8a; // pong
				client_send(c, m);
			}
		}
		pos += h + 4 + (size_t)len;
	}
	memmove(c->in, c->in + pos, c->in_len - pos);
	c->in_len -= pos;
	return 0;
}

static int http_input(struct client *c)
{
	c->in[c->in_len < sizeof c->in ? c->in_len : sizeof c->in - 1] = 0;
	char *end = strstr((char *)c->in, "\r\n\r\n");
	if (!end)
		return c->in_len >= sizeof c->in - 1 ? -1 : 0;
	char method[8], url[128];
	if (sscanf((char *)c->in, "%7s %127s", method, url) != 2 || strcmp(method, "GET"))
		return -1;
	char *key = strcasestr((char *)c->in, "\r\nSec-WebSocket-Key:");
	if (!strcmp(url, "/ws") && key) {
		key += 20;
		while (*key == ' ')
			key++;
		char buf[128];
		size_t n = strcspn(key, "\r\n");
		if (n > 60)
			return -1;
		snprintf(buf, sizeof buf, "%.*s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", (int)n, key);
		uint8_t digest[20];
		char accept[32], head[256];
		sha1((uint8_t *)buf, strlen(buf), digest);
		base64(digest, 20, accept);
		snprintf(head, sizeof head,
			 "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
			 "Sec-WebSocket-Accept: %s\r\n\r\n",
			 accept);
		struct msg *m = msg_new(strlen(head));
		memcpy(msg_payload(m), head, strlen(head));
		m->len = strlen(head);
		client_send(c, m);
		c->ws = 1;
		c->need_key = 1;
		atomic_fetch_add(&n_viewers, 1);
		atomic_store(&want_key, 1);
		char st[512];
		status_json(st, sizeof st);
		send_text(c, st);
		size_t used = (size_t)(end + 4 - (char *)c->in);
		memmove(c->in, c->in + used, c->in_len - used);
		c->in_len -= used;
		return ws_input(c);
	}
	serve_file(c, url);
	c->in_len = 0;
	return 0;
}

static int listen_on(const char *addr, int port)
{
	int fd = -1;
	struct sockaddr_storage ss = { 0 };
	socklen_t sl;
	struct sockaddr_in6 *s6 = (void *)&ss;
	struct sockaddr_in *s4 = (void *)&ss;
	if (inet_pton(AF_INET6, addr, &s6->sin6_addr) == 1) {
		s6->sin6_family = AF_INET6;
		s6->sin6_port = htons((uint16_t)port);
		sl = sizeof *s6;
	} else if (inet_pton(AF_INET, addr, &s4->sin_addr) == 1) {
		s4->sin_family = AF_INET;
		s4->sin_port = htons((uint16_t)port);
		sl = sizeof *s4;
	} else {
		log("bad listen address %s", addr);
		return -1;
	}
	fd = socket(ss.ss_family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	if (ss.ss_family == AF_INET6) {
		int zero = 0;
		setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof zero);
	}
	if (bind(fd, (void *)&ss, sl) < 0 || listen(fd, 16) < 0) {
		log("listen %s:%d: %s", addr, port, strerror(errno));
		close(fd);
		return -1;
	}
	return fd;
}

// ---------------------------------------------------------------------------
// Benchmark: encode the live picture in every CPU mode.

// Times one stage over `n` runs; returns ms per run.
#define TIME(n, stmt)                                         \
	({                                                    \
		double t0_ = now();                           \
		for (int i_ = 0; i_ < (n); i_++) {            \
			stmt;                                 \
		}                                             \
		(now() - t0_) * 1000 / (n);                   \
	})

static size_t bench_bytes;
static void bench_take(struct msg *m)
{
	if (m)
		bench_bytes = m->len;
	msg_unref(m);
}

// Encodes the cached reference frame in every CPU mode.
static void bench_encoders(struct tiles *tl, struct planes *pl, int n, const char *when)
{
	static uint8_t *scratch;
	size_t frame = (size_t)tl->w * tl->h * 2;
	if (!scratch)
		scratch = malloc(frame);
	printf("%s:\n", when);
	printf("  %-28s %7.1f ms\n", "memcpy 4 MB (cached)", TIME(n, memcpy(scratch, tl->ref, frame)));
	double t = TIME(n, memset(tl->dirty, 1, (size_t)tl->tw * tl->th); bench_take(tiles_message(tl)));
	printf("  %-28s %7.1f ms  %8zu bytes\n", "tiles, whole picture", t, bench_bytes);
	t = TIME(n, uyvy_planes(pl, tl->ref, tl->w, tl->h, 0));
	printf("  %-28s %7.1f ms\n", "UYVY -> planar 4:2:2", t);
	t = TIME(n, bench_take(jpeg_message(pl, jpeg_quality, pl->w, pl->h, 0)));
	printf("  %-28s %7.1f ms  %8zu bytes\n", "JPEG full size", t, bench_bytes);
	t = TIME(n, uyvy_planes(pl, tl->ref, tl->w, tl->h, 1));
	printf("  %-28s %7.1f ms\n", "UYVY -> planar 4:2:0, half", t);
	t = TIME(n, bench_take(jpeg_message(pl, jpeg_quality, pl->w, pl->h, 0)));
	printf("  %-28s %7.1f ms  %8zu bytes\n", "JPEG half size", t, bench_bytes);
}

static int bench(int n)
{
	int w, h;
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (!hdmi_signal(&w, &h)) {
		fprintf(stderr, "no HDMI signal\n");
		return 1;
	}
	struct capture cap;
	if (capture_open(&cap, w, h) < 0)
		return 1;
	struct tiles tl = { 0 };
	tiles_init(&tl, cap.w, cap.h);
	struct planes pl = { 0 };
	pl.y = malloc((size_t)cap.w * cap.h * 2);
	pl.u = pl.y + (size_t)cap.w * cap.h;
	pl.v = pl.u + (size_t)cap.w * cap.h / 2;
	printf("%dx%d UYVY, %d runs per figure\n", cap.w, cap.h, n);

	// Live frames: reading the capture buffer, and how much changes.
	double read_ms = 0, cmp_ms = 0;
	int changed = 0, frames = 0;
	for (int i = 0; i < n + 1; i++) {
		struct pollfd p = { .fd = cap.fd, .events = POLLIN };
		if (poll(&p, 1, 2000) <= 0) {
			fprintf(stderr, "capture stalled (no frame in 2 s)\n");
			return 1;
		}
		struct v4l2_buffer b;
		if (capture_dq(&cap, &b) < 0) {
			fprintf(stderr, "DQBUF: %s\n", strerror(errno));
			return 1;
		}
		const uint8_t *src = cap.mem[b.index];
		double t0 = now();
		int c = tiles_update(&tl, src, cap.stride);
		double t1 = now();
		if (i > 0) { // the first frame fills the reference
			cmp_ms += (t1 - t0) * 1000;
			changed += c;
			frames++;
			read_ms += TIME(1, memcpy(pl.y, src, (size_t)cap.w * cap.h * 2));
		}
		capture_q(&cap, &b);
	}
	printf("live frames:\n");
	printf("  %-28s %7.1f ms\n", "memcpy 4 MB from capture", read_ms / frames);
	printf("  %-28s %7.1f ms  %d of %d tiles changed per frame\n", "compare with reference", cmp_ms / frames,
	       changed / frames, tl.tw * tl.th);
	bench_encoders(&tl, &pl, n, "encoders, capture streaming");

	// Half size through the VPSS: scale + colour conversion in hardware.
	struct vpss vp;
	if (vpss_open(&vp, &cap, cap.w / 2, cap.h / 2) < 0)
		printf("VPSS: unavailable\n");
	else {
		double scale_ms = 0, total_ms = 0;
		int ok = 1;
		for (int i = 0; i < n && ok; i++) {
			struct pollfd p = { .fd = cap.fd, .events = POLLIN };
			struct v4l2_buffer b;
			if (poll(&p, 1, 2000) <= 0 || capture_dq(&cap, &b) < 0)
				continue;
			double t0 = now();
			if (vpss_run(&vp, &cap, (int)b.index) < 0) {
				printf("VPSS: job did not complete\n");
				ok = 0;
			} else {
				double t1 = now();
				nv12_planes(&pl, vp.mem, vp.w, vp.h, vp.stride, 0, vp.h);
				vpss_done(&vp);
				bench_take(jpeg_message(&pl, jpeg_quality, pl.w, pl.h, 0));
				scale_ms += (t1 - t0) * 1000;
				total_ms += (now() - t0) * 1000;
			}
			capture_q(&cap, &b);
		}
		if (ok) {
			printf("VPSS half size (%dx%d NV12):\n", vp.w, vp.h);
			printf("  %-28s %7.1f ms\n", "VPSS scale + convert", scale_ms / n);
			printf("  %-28s %7.1f ms  %8zu bytes\n", "+ JPEG, per frame", total_ms / n, bench_bytes);
			vpss_close(&vp);
		}
	}

	capture_close(&cap);
	bench_encoders(&tl, &pl, n, "encoders, capture stopped");
	return 0;
}

// ---------------------------------------------------------------------------

static void usage(void)
{
	fprintf(stderr,
		"usage: nanokvm-kvm [--listen ADDR] [--port N] [--mode tiles|mjpeg|mjpeg-half|h264]\n"
		"                   [--quality Q] [--max-fps N] [--h264-bridge PATH] [--c906l FIRMWARE]\n"
		"       nanokvm-kvm --bench [FRAMES]\n");
	exit(2);
}

int main(int argc, char **argv)
{
	const char *addr = "127.0.0.1";
	int port = 8080;
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
		if (!strcmp(a, "--bench"))
			return bench(v ? atoi(v) : 30);
		if (!v)
			usage();
		if (!strcmp(a, "--listen"))
			addr = v;
		else if (!strcmp(a, "--port"))
			port = atoi(v);
		else if (!strcmp(a, "--quality"))
			jpeg_quality = atoi(v);
		else if (!strcmp(a, "--max-fps"))
			max_fps = atoi(v) > 0 ? atoi(v) : 30;
		else if (!strcmp(a, "--h264-bridge"))
			h264_bridge = v;
		else if (!strcmp(a, "--c906l"))
			c906l_firmware = v;
		else if (!strcmp(a, "--mode")) {
			int found = 0;
			for (int m = 0; m < MODE_COUNT; m++)
				if (!strcmp(v, mode_names[m])) {
					atomic_store(&want_mode, m);
					found = 1;
				}
			if (!found)
				usage();
		} else
			usage();
		i++;
	}
	if (atomic_load(&want_mode) == MODE_H264 && !h264_bridge)
		atomic_store(&want_mode, MODE_TILES);
	signal(SIGPIPE, SIG_IGN);
	openlog("nanokvm-kvm", LOG_PID, LOG_DAEMON);

	int lfd = listen_on(addr, port);
	if (lfd < 0)
		return 1;
	q_event = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
	for (int i = 0; i < MAX_CLIENTS; i++)
		clients[i].fd = -1;
	atx_open();
	gadget_setup();
	hid_open();
	log("listening on %s port %d", addr, port);

	if (c906l_firmware && c906l_start() < 0)
		log("c906l: offload off; compressing on this core");

	pthread_t vt;
	pthread_create(&vt, NULL, video_main, NULL);

	double next_status = now();
	for (;;) {
		struct pollfd p[MAX_CLIENTS + 4];
		int np = 0;
		p[np++] = (struct pollfd){ .fd = lfd, .events = POLLIN };
		p[np++] = (struct pollfd){ .fd = q_event, .events = POLLIN };
		int kbd_at = -1, out_at = -1;
		if (hid_kbd >= 0) {
			kbd_at = np;
			p[np++] = (struct pollfd){ .fd = hid_kbd, .events = POLLIN };
		}
		if (hid_qn) {
			out_at = np;
			p[np++] = (struct pollfd){ .fd = hid_q[hid_qh].fd, .events = POLLOUT };
		}
		int base = np;
		for (int i = 0; i < MAX_CLIENTS; i++)
			if (clients[i].fd >= 0)
				p[np++] = (struct pollfd){ .fd = clients[i].fd,
							   .events = POLLIN | (clients[i].out_n ? POLLOUT : 0) };
		double t = now();
		int timeout = (int)((next_status - t) * 1000);
		if (atx_release_line >= 0) {
			int ms = (int)((atx_release_at - t) * 1000);
			timeout = ms < timeout ? ms : timeout;
		}
		if (hid_qn && out_at < 0)
			timeout = 5;
		poll(p, (nfds_t)np, timeout < 0 ? 0 : timeout);
		t = now();

		if (atx_release_line >= 0 && t >= atx_release_at) {
			atx_set(atx_release_line, 0);
			atx_release_line = -1;
		}
		if (kbd_at >= 0 && p[kbd_at].revents & POLLIN) {
			uint8_t leds;
			if (read(hid_kbd, &leds, 1) == 1)
				kbd_leds = leds;
		}
		if (hid_qn)
			hid_flush();

		if (p[0].revents & POLLIN) {
			int fd = accept4(lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
			if (fd >= 0) {
				struct client *c = NULL;
				for (int i = 0; i < MAX_CLIENTS && !c; i++)
					if (clients[i].fd < 0)
						c = &clients[i];
				if (!c)
					close(fd);
				else {
					memset(c, 0, sizeof *c);
					c->fd = fd;
					int one = 1;
					setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
				}
			}
		}

		// Video messages to every viewer.
		if (p[1].revents & POLLIN) {
			uint64_t v;
			if (read(q_event, &v, 8) < 0) {
			}
			pthread_mutex_lock(&q_lock);
			for (int k = 0; k < q_len; k++) {
				struct msg *m = q_items[k];
				for (int i = 0; i < MAX_CLIENTS; i++) {
					struct client *c = &clients[i];
					if (c->fd < 0 || !c->ws)
						continue;
					int h264 = msg_payload(m)[0] == 3;
					if (h264) {
						// A viewer that fell behind skips to the next IDR.
						if (c->out_n > 4)
							c->need_key = 1;
						if (c->need_key && !m->key)
							continue;
						c->need_key = 0;
					}
					atomic_fetch_add(&m->refs, 1);
					client_send(c, m);
				}
				msg_unref(m);
			}
			q_len = 0;
			pthread_mutex_unlock(&q_lock);
		}

		for (int k = base; k < np; k++) {
			struct client *c = NULL;
			for (int i = 0; i < MAX_CLIENTS; i++)
				if (clients[i].fd == p[k].fd)
					c = &clients[i];
			if (!c)
				continue;
			int dead = (p[k].revents & (POLLERR | POLLHUP)) != 0;
			if (!dead && p[k].revents & POLLIN) {
				ssize_t n = recv(c->fd, c->in + c->in_len, sizeof c->in - 1 - c->in_len, 0);
				if (n <= 0)
					dead = n == 0 || (errno != EAGAIN && errno != EINTR);
				else {
					c->in_len += (size_t)n;
					dead = (c->ws ? ws_input(c) : http_input(c)) < 0;
				}
			}
			if (!dead)
				dead = client_flush(c) < 0;
			if (dead)
				client_drop(c);
		}

		// Ask for the next video message once every viewer has caught up.
		int ready = 1;
		for (int i = 0; i < MAX_CLIENTS; i++)
			if (clients[i].fd >= 0 && clients[i].ws && clients[i].out_n > 1)
				ready = 0;
		atomic_store(&want_frame, ready);

		if (t >= next_status) {
			next_status = t + 1;
			hid_open();
			char st[512];
			status_json(st, sizeof st);
			for (int i = 0; i < MAX_CLIENTS; i++)
				if (clients[i].fd >= 0 && clients[i].ws && clients[i].out_n < 8)
					send_text(&clients[i], st);
		}
	}
}
