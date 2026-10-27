// JPEG job: IJG libjpeg, raw YCbCr input converted from the UYVY frame a
// strip at a time (the whole frame's planes would not fit the firmware's
// 1 MiB), written straight into the output region.
#include "fw.h"

#include <stdio.h> // FILE, for jpeglib.h's declarations only
#include "jpeglib.h"

struct fail {
	struct jpeg_error_mgr mgr;
	void *jmp[5]; // __builtin_setjmp buffer
	uint32_t result;
};

static void error_exit(j_common_ptr c)
{
	struct fail *f = (struct fail *)c->err;
	__builtin_longjmp(f->jmp, 1);
}
static void emit_message(j_common_ptr c, int level) { (void)c; (void)level; }
static void output_message(j_common_ptr c) { (void)c; }
static void format_message(j_common_ptr c, char *buf) { (void)c; buf[0] = 0; }
static void reset_error_mgr(j_common_ptr c) { (void)c; }

struct dest {
	struct jpeg_destination_mgr mgr;
	struct fail *fail;
};
static void init_destination(j_compress_ptr c) { (void)c; }
// The output region is the whole buffer: needing more is an error.
static boolean empty_output_buffer(j_compress_ptr c)
{
	struct dest *d = (struct dest *)c->dest;
	d->fail->result = C906L_ERR_SPACE;
	error_exit((j_common_ptr)c);
	return FALSE;
}
static void term_destination(j_compress_ptr c) { (void)c; }

uint32_t jpeg(const struct c906l_job *j, uint8_t *out, size_t room, uint32_t *length)
{
	const unsigned W = j->width, H = j->height, half = j->half;
	if (!W || !H || W > 4096 || H > 4096 || (W & 1))
		return C906L_ERR_ARGS;
	const unsigned w = half ? W / 2 : W, h = half ? H / 2 : H;
	const unsigned cw = w / 2, rows = half ? 16 : 8, crow = 8;
	const uint8_t *frame = (const uint8_t *)(uintptr_t)j->frame;

	heap_reset();
	struct jpeg_compress_struct c;
	struct fail fail = { .result = C906L_ERR_JPEG };
	struct dest dest = { .fail = &fail };
	fail.mgr.error_exit = error_exit;
	fail.mgr.emit_message = emit_message;
	fail.mgr.output_message = output_message;
	fail.mgr.format_message = format_message;
	fail.mgr.reset_error_mgr = reset_error_mgr;
	c.err = &fail.mgr;
	if (__builtin_setjmp(fail.jmp)) {
		jpeg_destroy_compress(&c);
		return fail.result;
	}
	jpeg_create_compress(&c);
	dest.mgr.next_output_byte = out;
	dest.mgr.free_in_buffer = room;
	dest.mgr.init_destination = init_destination;
	dest.mgr.empty_output_buffer = empty_output_buffer;
	dest.mgr.term_destination = term_destination;
	c.dest = &dest.mgr;

	c.image_width = w;
	c.image_height = h;
	c.input_components = 3;
	c.in_color_space = JCS_YCbCr;
	jpeg_set_defaults(&c);
	jpeg_set_quality(&c, (int)j->quality, TRUE);
	c.raw_data_in = TRUE;
	c.dct_method = JDCT_IFAST;
	c.comp_info[0].h_samp_factor = 2;
	c.comp_info[0].v_samp_factor = half ? 2 : 1;
	c.comp_info[1].h_samp_factor = c.comp_info[1].v_samp_factor = 1;
	c.comp_info[2].h_samp_factor = c.comp_info[2].v_samp_factor = 1;
	jpeg_start_compress(&c, TRUE);

	// One strip: `rows` luma rows and 8 chroma rows.
	uint8_t *y = malloc((size_t)w * rows), *u = malloc((size_t)cw * crow), *v = malloc((size_t)cw * crow);
	if (!y || !u || !v) {
		jpeg_destroy_compress(&c);
		return C906L_ERR_JPEG;
	}
	JSAMPROW ry[16], ru[8], rv[8];
	JSAMPARRAY planes[3] = { ry, ru, rv };
	while (c.next_scanline < h) {
		unsigned l = c.next_scanline;
		for (unsigned i = 0; i < rows; i++) {
			unsigned r = l + i < h ? l + i : h - 1;
			const uint8_t *s = frame + (size_t)(half ? 2 * r : r) * j->stride;
			cache_invalidate(s, (size_t)W * 2);
			uint8_t *py = y + (size_t)i * w;
			ry[i] = py;
			if (half) {
				for (unsigned x = 0; x < w; x++)
					py[x] = s[4 * x + 1];
			} else {
				for (unsigned x = 0; x < W / 2; x++) {
					py[2 * x] = s[4 * x + 1];
					py[2 * x + 1] = s[4 * x + 3];
				}
			}
			// Chroma rows: every row at full size, every other at half.
			if (!half || !(i & 1)) {
				unsigned ci = half ? i / 2 : i;
				uint8_t *pu = u + (size_t)ci * cw, *pv = v + (size_t)ci * cw;
				ru[ci] = pu;
				rv[ci] = pv;
				unsigned step = half ? 8 : 4;
				for (unsigned x = 0; x < cw; x++) {
					pu[x] = s[step * x];
					pv[x] = s[step * x + 2];
				}
			}
		}
		jpeg_write_raw_data(&c, planes, rows);
	}
	jpeg_finish_compress(&c);
	*length = (uint32_t)(room - dest.mgr.free_in_buffer);
	jpeg_destroy_compress(&c);
	cache_clean(out, *length);
	return C906L_OK;
}
