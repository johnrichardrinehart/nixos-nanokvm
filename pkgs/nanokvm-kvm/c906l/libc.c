// The few C library functions libjpeg needs. The firmware runs above
// 2 GiB, where the toolchain's medlow-built newlib cannot be linked, so it
// carries its own. The heap is a bump allocator reset before every job.
#include "fw.h"

void *memcpy(void *dst, const void *src, size_t n)
{
	uint8_t *d = dst;
	const uint8_t *s = src;
	if ((((uintptr_t)d | (uintptr_t)s) & 7) == 0) {
		for (; n >= 8; n -= 8, d += 8, s += 8)
			*(uint64_t *)(void *)d = *(const uint64_t *)(const void *)s;
	}
	while (n--)
		*d++ = *s++;
	return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
	uint8_t *d = dst;
	const uint8_t *s = src;
	if (d <= s || d >= s + n)
		return memcpy(dst, src, n);
	while (n--)
		d[n] = s[n];
	return dst;
}

void *memset(void *dst, int c, size_t n)
{
	uint8_t *d = dst;
	while (n--)
		*d++ = (uint8_t)c;
	return dst;
}

int memcmp(const void *a, const void *b, size_t n)
{
	const uint8_t *x = a, *y = b;
	for (; n; n--, x++, y++)
		if (*x != *y)
			return *x - *y;
	return 0;
}

size_t strlen(const char *s)
{
	size_t n = 0;
	while (s[n])
		n++;
	return n;
}

extern char __heap_start[], __stack_top[];
#define STACK_SIZE (64 * 1024)
static char *heap = __heap_start;

void *malloc(size_t n)
{
	n = (n + 15) & ~(size_t)15;
	if ((uintptr_t)heap + n > (uintptr_t)__stack_top - STACK_SIZE)
		return NULL;
	void *p = heap;
	heap += n;
	return p;
}

void free(void *p) { (void)p; }

void heap_reset(void) { heap = __heap_start; }
