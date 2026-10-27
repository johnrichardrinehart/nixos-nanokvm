// Firmware-internal declarations: the C library subset it carries itself
// (libc.c), cache maintenance (main.c) and the JPEG job (jpeg.c).
#ifndef NANOKVM_C906L_FW_H
#define NANOKVM_C906L_FW_H

#include <stddef.h>
#include <stdint.h>

#include "protocol.h"

void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
void *malloc(size_t n);
void free(void *p);
void heap_reset(void);

void cache_invalidate(const volatile void *p, size_t n);
void cache_clean(const volatile void *p, size_t n);

uint32_t jpeg(const struct c906l_job *j, uint8_t *out, size_t room, uint32_t *length);

#endif
