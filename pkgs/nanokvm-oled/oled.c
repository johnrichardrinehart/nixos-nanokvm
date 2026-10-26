// nanokvm-oled: status screen for the NanoKVM's 128x64 monochrome OLED.
//
//   nanokvm-oled [FB]        redraw FB (default /dev/fb0) every 2 s
//   nanokvm-oled --pbm FILE  draw one frame as a PBM image (preview)
//
// Reads /proc, /sys, the kernel command line and nanokvm-ab's runtime
// flags; never the card. ssd1307fb exposes a 1 bpp framebuffer: pixel
// (x, y) is bit x % 8 (LSB first) of byte y * 16 + x / 8, and every write()
// is sent to the panel.
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <math.h>
#include <fcntl.h>

#include "fonts.h" // font_small (Spleen 5x8), font_big (Spleen 8x16), PSF2

#define W 128
#define H 64
#define STRIDE (W / 8)

static uint8_t fb[STRIDE * H];
static const char *state_dir = "/run/nanokvm-ab";
static const char *iface = "eth0";

/* ---- drawing ------------------------------------------------------------ */

static void px(int x, int y, int on)
{
	if (x < 0 || y < 0 || x >= W || y >= H)
		return;
	uint8_t *b = &fb[y * STRIDE + x / 8];
	if (on)
		*b |= 1u << (x % 8);
	else
		*b &= ~(1u << (x % 8));
}

static void fill(int x, int y, int w, int h, int on)
{
	for (int j = y; j < y + h; j++)
		for (int i = x; i < x + w; i++)
			px(i, j, on);
}

static void frame(int x, int y, int w, int h)
{
	fill(x, y, w, 1, 1);
	fill(x, y + h - 1, w, 1, 1);
	fill(x, y, 1, h, 1);
	fill(x + w - 1, y, 1, h, 1);
}

struct font {
	const uint8_t *glyphs;
	uint32_t count, bytes, height, width;
};

// Linux console fonts: PSF1 (Spleen 8x16) or PSF2 (Spleen 5x8).
static struct font psf(const uint8_t *data)
{
	if (data[0] == 0x36 && data[1] == 0x04) {
		// PSF1: magic, mode (bit 0: 512 glyphs), charsize; 8 px wide.
		return (struct font){ data + 4, data[2] & 1 ? 512 : 256, data[3], data[3], 8 };
	}
	uint32_t h[8]; // magic, version, headersize, flags, length, charsize, height, width
	memcpy(h, data, sizeof h);
	if (h[0] != 0x864ab572) {
		fprintf(stderr, "nanokvm-oled: unknown font format\n");
		exit(1);
	}
	return (struct font){ data + h[2], h[4], h[5], h[6], h[7] };
}

// Draws text at (x, y); returns the x after it. `on` 0 draws inverted
// (for text on a filled bar).
static int text(const struct font *f, int x, int y, const char *s, int on)
{
	int row = (f->width + 7) / 8;
	for (; *s; s++, x += f->width) {
		uint8_t c = (uint8_t)*s;
		if (c >= f->count)
			c = '?';
		const uint8_t *g = f->glyphs + c * f->bytes;
		for (uint32_t j = 0; j < f->height; j++)
			for (uint32_t i = 0; i < f->width; i++)
				if (g[j * row + i / 8] & (0x80 >> (i % 8)))
					px(x + i, y + j, on);
	}
	return x;
}

static int text_width(const struct font *f, const char *s)
{
	return (int)(strlen(s) * f->width);
}

// 8x8 icons, one byte per row, MSB on the left.
static const uint8_t icon_eth[8] = { 0x00, 0x7e, 0x42, 0x5a, 0x5a, 0x42, 0x7e, 0x24 };
static const uint8_t icon_heart[8] = { 0x00, 0x66, 0xff, 0xff, 0x7e, 0x3c, 0x18, 0x00 };
static const uint8_t icon_hourglass[8] = { 0x7e, 0x42, 0x24, 0x18, 0x18, 0x24, 0x5a, 0x7e };
static const uint8_t icon_check[8] = { 0x00, 0x01, 0x03, 0x06, 0x8c, 0xd8, 0x70, 0x20 };
static const uint8_t icon_cross[8] = { 0x00, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x00 };
static const uint8_t icon_clock[8] = { 0x3c, 0x42, 0x91, 0x91, 0x9d, 0x81, 0x42, 0x3c };
// The project's mark in miniature: a six-armed asterisk (7x7).
static const uint8_t icon_flake[8] = { 0x10, 0x92, 0x54, 0x38, 0x54, 0x92, 0x10, 0x00 };

#ifndef NANOKVM_VERSION
#define NANOKVM_VERSION "dev"
#endif

static void icon(int x, int y, const uint8_t *bits, int on)
{
	for (int j = 0; j < 8; j++)
		for (int i = 0; i < 8; i++)
			if (bits[j] & (0x80 >> i))
				px(x + i, y + j, on);
}

// Bar gauge: outline with a filled share `frac` (0..1).
static void gauge(int x, int y, int w, int h, double frac)
{
	if (frac < 0)
		frac = 0;
	if (frac > 1)
		frac = 1;
	frame(x, y, w, h);
	fill(x + 2, y + 2, (int)((w - 4) * frac + 0.5), h - 4, 1);
}

/* ---- data ----------------------------------------------------------------- */

static int read_line(const char *path, char *buf, size_t n)
{
	FILE *f = fopen(path, "r");
	if (!f)
		return -1;
	int ok = fgets(buf, (int)n, f) != NULL;
	fclose(f);
	if (!ok)
		return -1;
	buf[strcspn(buf, "\n")] = 0;
	return 0;
}

// CPU utilisation (0..1) since the previous call, from /proc/stat's
// aggregate line: 1 - (idle + iowait) / total.
static double cpu_busy(void)
{
	static unsigned long long prev_total, prev_idle;
	unsigned long long v[8] = { 0 }, total = 0, idle;
	char line[256];
	if (read_line("/proc/stat", line, sizeof line) ||
	    sscanf(line, "cpu %llu %llu %llu %llu %llu %llu %llu %llu", &v[0], &v[1], &v[2], &v[3],
		   &v[4], &v[5], &v[6], &v[7]) < 4)
		return 0;
	for (int i = 0; i < 8; i++)
		total += v[i];
	idle = v[3] + v[4];
	double busy = 0;
	if (total > prev_total)
		busy = 1.0 - (double)(idle - prev_idle) / (double)(total - prev_total);
	prev_total = total;
	prev_idle = idle;
	return busy;
}

static int exists(const char *dir, const char *name)
{
	char p[256];
	snprintf(p, sizeof p, "%s/%s", dir, name);
	return access(p, F_OK) == 0;
}

static void cmdline_get(const char *key, char *out, size_t n)
{
	char buf[4096];
	out[0] = 0;
	if (read_line("/proc/cmdline", buf, sizeof buf))
		return;
	size_t k = strlen(key);
	for (char *w = strtok(buf, " "); w; w = strtok(NULL, " "))
		if (!strncmp(w, key, k) && w[k] == '=') {
			snprintf(out, n, "%s", w + k + 1);
			return;
		}
}

static void ipv4(char *out, size_t n)
{
	struct ifaddrs *list, *a;
	out[0] = 0;
	if (getifaddrs(&list))
		return;
	for (a = list; a; a = a->ifa_next)
		if (a->ifa_addr && a->ifa_addr->sa_family == AF_INET && !strcmp(a->ifa_name, iface)) {
			inet_ntop(AF_INET, &((struct sockaddr_in *)a->ifa_addr)->sin_addr, out, (socklen_t)n);
			break;
		}
	freeifaddrs(list);
}

static void ipv6_link_local(char *out, size_t n)
{
	struct ifaddrs *list, *a;
	out[0] = 0;
	if (getifaddrs(&list))
		return;
	for (a = list; a; a = a->ifa_next)
		if (a->ifa_addr && a->ifa_addr->sa_family == AF_INET6 && !strcmp(a->ifa_name, iface)) {
			const struct in6_addr *in = &((struct sockaddr_in6 *)a->ifa_addr)->sin6_addr;
			if (IN6_IS_ADDR_LINKLOCAL(in)) {
				inet_ntop(AF_INET6, in, out, (socklen_t)n);
				break;
			}
		}
	freeifaddrs(list);
}

// ntpd's event script keeps this file while the clock is synchronised
// (modules/board.nix); it lives on a tmpfs, so a reboot clears it.
static int ntp_synced(void)
{
	return access("/run/ntp-synced", F_OK) == 0;
}

/* ---- screen --------------------------------------------------------------- */

static void draw(void)
{
	struct font small = psf(font_small), big = psf(font_big);
	char host[64] = "", ip[INET_ADDRSTRLEN], buf[128], slot[8], trial[8];

	memset(fb, 0, sizeof fb);

	// Header: inverted bar, hostname left, slot and state right.
	fill(0, 0, W, 11, 1);
	cmdline_get("nanokvm.slot", slot, sizeof slot);
	cmdline_get("nanokvm.trial", trial, sizeof trial);
	int healthy = exists(state_dir, "healthy");
	int on_trial = !strcmp(trial, "1") && !exists(state_dir, "committed");
	snprintf(buf, sizeof buf, "SLOT %c", slot[0] ? slot[0] - 'a' + 'A' : '?');
	int x = W - 3 - 9 - text_width(&small, buf);
	text(&small, x, 2, buf, 0);
	icon(W - 11, 1, on_trial ? icon_hourglass : healthy ? icon_check : icon_cross, 0);
	gethostname(host, sizeof host - 1);
	icon(2, 1, icon_flake, 0);
	host[(x - 13 - 5) / small.width] = 0; // keep clear of the slot label
	text(&small, 13, 2, host, 0);

	// Large clock, 5 s each: uptime (clock icon), then UTC and US Eastern
	// time once NTP has set the clock (labelled in small type).
	ipv4(ip, sizeof ip);
	char oper[32] = "", speed[32] = "", u[64] = "";
	snprintf(buf, sizeof buf, "/sys/class/net/%s/operstate", iface);
	read_line(buf, oper, sizeof oper);
	snprintf(buf, sizeof buf, "/sys/class/net/%s/speed", iface);
	read_line(buf, speed, sizeof speed);
	int up = !strcmp(oper, "up");
	read_line("/proc/uptime", u, sizeof u);
	long s = atol(u);
	time_t now = time(NULL);
	// Wall-clock times only while ntpd reports the clock synchronised; the
	// rows then rotate on wall-clock 5 s boundaries, else on uptime ones.
	int synced = ntp_synced();
	long tick = synced ? (long)(now / 5) : s / 5;
	int phase = synced ? (int)(tick % 3) : 0;
	const char *label = NULL;
	if (phase == 0) {
		if (s >= 86400)
			snprintf(buf, sizeof buf, "%ldd %02ld:%02ld", s / 86400, s % 86400 / 3600, s % 3600 / 60);
		else
			snprintf(buf, sizeof buf, "%02ld:%02ld:%02ld", s / 3600, s % 3600 / 60, s % 60);
	} else {
		struct tm tm;
		if (phase == 1) {
			gmtime_r(&now, &tm);
			label = "UTC";
		} else {
			// musl reads POSIX TZ rules without a zoneinfo database.
			setenv("TZ", "EST5EDT,M3.2.0,M11.1.0", 1);
			tzset();
			localtime_r(&now, &tm);
			label = tm.tm_isdst ? "EDT" : "EST";
		}
		strftime(buf, sizeof buf, "%H:%M:%S", &tm);
	}
	int bw = text_width(&big, buf);
	int lw = label ? text_width(&small, label) + 2 : 11;
	int x0 = (W - bw - lw) / 2;
	if (label)
		text(&small, x0, 16, label, 1);
	else
		icon(x0, 16, icon_clock, 1);
	text(&big, x0 + lw, 12, buf, 1);
	for (int i = 0; i < W; i += 2)
		px(i, 28, 1);

	// Link and health.
	icon(2, 30, icon_eth, 1);
	snprintf(buf, sizeof buf, "%s", up ? (speed[0] ? speed : "up") : "down");
	if (up && speed[0])
		strcat(buf, "M");
	text(&small, 13, 30, buf, 1);
	icon(66, 30, icon_heart, 1);
	text(&small, 77, 30, on_trial ? "trial" : healthy ? "healthy" : "booting", 1);

	// SoC temperature, 20..90 C.
	char t[32] = "";
	read_line("/sys/class/thermal/thermal_zone0/temp", t, sizeof t);
	double temp = atof(t) / 1000;
	text(&small, 2, 39, "TEMP", 1);
	gauge(24, 39, 72, 8, (temp - 20) / 70);
	snprintf(buf, sizeof buf, "%.0fC", temp);
	text(&small, W - 2 - text_width(&small, buf), 39, buf, 1);

	// CPU utilisation since the previous frame.
	double cpu = cpu_busy();
	text(&small, 2, 48, "CPU", 1);
	gauge(24, 48, 72, 8, cpu);
	snprintf(buf, sizeof buf, "%.0f%%", cpu * 100);
	text(&small, W - 2 - text_width(&small, buf), 48, buf, 1);

	// Bottom row, rotating every 5 s through whichever of these exist: the
	// DHCP address, the IPv6 link-local address (reachable over a direct
	// cable: ssh root@fe80::...%<interface>) and the MAC address.
	char lines[3][64];
	int n = 0;
	if (ip[0])
		snprintf(lines[n++], sizeof lines[0], "IPv4 %s", ip);
	ipv6_link_local(lines[n], sizeof lines[0]);
	if (lines[n][0])
		n++;
	snprintf(buf, sizeof buf, "/sys/class/net/%s/address", iface);
	read_line(buf, t, sizeof t);
	if (t[0])
		snprintf(lines[n++], sizeof lines[0], "MAC %s", t);
	if (n)
		text(&small, (W - text_width(&small, lines[tick % n])) / 2, 56, lines[tick % n], 1);
}

static int write_pbm(const char *path)
{
	FILE *f = fopen(path, "wb");
	if (!f)
		return 1;
	fprintf(f, "P4\n%d %d\n", W, H);
	for (int y = 0; y < H; y++)
		for (int b = 0; b < STRIDE; b++) {
			// PBM rows are MSB-first; the framebuffer is LSB-first.
			uint8_t v = fb[y * STRIDE + b], r = 0;
			for (int i = 0; i < 8; i++)
				if (v & (1u << i))
					r |= 0x80 >> i;
			fputc(r, f);
		}
	return fclose(f) != 0;
}

// Line from (x0, y0) to (x1, y1), `w` pixels thick (Bresenham).
static void line(int x0, int y0, int x1, int y1, int w)
{
	int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
	int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
	for (int err = dx + dy;;) {
		fill(x0 - w / 2, y0 - w / 2, w, w, 1);
		if (x0 == x1 && y0 == y1)
			break;
		int e2 = 2 * err;
		if (e2 >= dy) {
			err += dy;
			x0 += sx;
		}
		if (e2 <= dx) {
			err += dx;
			y0 += sy;
		}
	}
}

// The project's mark: a six-armed snowflake (after Nix's), radius r.
static void snowflake(int cx, int cy, double r)
{
	for (int k = 0; k < 6; k++) {
		double a = M_PI / 2 + k * M_PI / 3;
		int ex = cx + (int)lround(r * cos(a)), ey = cy - (int)lround(r * sin(a));
		line(cx, cy, ex, ey, 2);
		// A branch pair at 55% of the arm, angled 60 degrees off it.
		int bx = cx + (int)lround(0.55 * r * cos(a)), by = cy - (int)lround(0.55 * r * sin(a));
		for (int s = -1; s <= 1; s += 2) {
			double b = a + s * M_PI / 3;
			line(bx, by, bx + (int)lround(0.35 * r * cos(b)), by - (int)lround(0.35 * r * sin(b)), 1);
		}
	}
}

// Shown while the service starts: the logo, the project name and the
// build's revision.
static void splash(void)
{
	struct font small = psf(font_small), big = psf(font_big);
	memset(fb, 0, sizeof fb);
	snowflake(W / 2, 13, 12);
	const char *name = "nixos-nanokvm";
	text(&big, (W - text_width(&big, name)) / 2, 29, name, 1);
	char line[64];
	snprintf(line, sizeof line, "mixos  A/B  %s", NANOKVM_VERSION);
	text(&small, (W - text_width(&small, line)) / 2, 50, line, 1);
}

static void show(const char *dev)
{
	int fd = open(dev, O_WRONLY);
	if (fd < 0) {
		perror(dev);
		return;
	}
	if (write(fd, fb, sizeof fb) != (ssize_t)sizeof fb)
		fprintf(stderr, "nanokvm-oled: short write to %s\n", dev);
	close(fd);
}

int main(int argc, char **argv)
{
	if (getenv("NANOKVM_AB_STATE_DIR"))
		state_dir = getenv("NANOKVM_AB_STATE_DIR");
	if (argc == 3 && !strcmp(argv[1], "--pbm")) {
		cpu_busy(); // baseline, so the frame shows a real share
		usleep(500000);
		draw();
		return write_pbm(argv[2]);
	}
	if (argc == 3 && !strcmp(argv[1], "--splash-pbm")) {
		splash();
		return write_pbm(argv[2]);
	}
	const char *dev = argc > 1 ? argv[1] : "/dev/fb0";
	splash();
	show(dev);
	cpu_busy();
	sleep(3);
	// Redraw on every multiple of 5 s of the clock that is shown: wall time
	// once NTP has synchronised, uptime before. The clock then reads :00 or
	// :05 and the rotating rows change with it.
	for (;;) {
		draw();
		show(dev);
		clockid_t id = ntp_synced() ? CLOCK_REALTIME : CLOCK_BOOTTIME;
		struct timespec t;
		clock_gettime(id, &t);
		t.tv_sec = (t.tv_sec / 5 + 1) * 5;
		t.tv_nsec = 0;
		while (clock_nanosleep(id, TIMER_ABSTIME, &t, NULL) == EINTR)
			;
	}
}
