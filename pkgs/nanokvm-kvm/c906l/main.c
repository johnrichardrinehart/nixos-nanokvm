// nanokvm-kvm's firmware for the 700 MHz C906L: polls the job line in the
// control page and JPEG-encodes frame bands that Linux captured (protocol.h).
// Bare metal, M-mode, no interrupts; everything else on the SoC is Linux's.
#include <stddef.h>
#include <stdint.h>

#include "fw.h"
#include "protocol.h"

static volatile struct c906l_status *const status = (void *)C906L_CONTROL;
static volatile struct c906l_job *const job = (void *)(C906L_CONTROL + 64);
static uint8_t *const out = (void *)C906L_OUTPUT;

// T-Head cache operations by physical address (XTheadCmo), raw-encoded on
// a0 as in the vendor RTOS, then sync.s.
#define LINE 64UL
#define CACHE_OP(insn, start, size)                                                     \
	do {                                                                            \
		register uintptr_t a0_ asm("a0") = (uintptr_t)(start) & ~(LINE - 1);    \
		uintptr_t end_ = (uintptr_t)(start) + (size);                           \
		for (; a0_ < end_; a0_ += LINE)                                         \
			__asm__ volatile(insn ::"r"(a0_) : "memory");                   \
		__asm__ volatile(".long 0x0190000b" ::: "memory"); /* sync.s */         \
	} while (0)
void cache_invalidate(const volatile void *p, size_t n) { CACHE_OP(".long 0x02a5000b", p, n); }
void cache_clean(const volatile void *p, size_t n) { CACHE_OP(".long 0x0295000b", p, n); }

static uint32_t cycles(void)
{
	unsigned long c;
	__asm__ volatile("rdcycle %0" : "=r"(c));
	return (uint32_t)c;
}

static void publish(uint32_t seq, uint32_t result, uint32_t length, uint32_t took)
{
	status->result = result;
	status->length = length;
	status->cycles = took;
	__asm__ volatile("fence rw, rw" ::: "memory");
	status->done = seq;
	cache_clean(status, sizeof *status);
}

int main(void)
{
	status->magic = C906L_MAGIC;
	status->version = C906L_VERSION;
	status->heartbeat = 0;
	status->parked = 0;
	cache_clean(status, sizeof *status);
	cache_invalidate(job, sizeof *job);
	uint32_t seen = job->seq;
	status->done = seen;
	cache_clean(status, sizeof *status);

	for (uint32_t spin = 0;; spin++) {
		cache_invalidate(job, sizeof *job);
		uint32_t seq = job->seq;
		if (seq == seen) {
			if ((spin & 0xffff) == 0) {
				status->heartbeat++;
				cache_clean(status, sizeof *status);
			}
			continue;
		}
		__asm__ volatile("fence r, r" ::: "memory");
		seen = seq;
		struct c906l_job j;
		memcpy(&j, (const void *)job, sizeof j);
		uint32_t t0 = cycles(), length = 0, result;
		switch (j.type) {
		case C906L_JOB_JPEG:
			result = jpeg(&j, out, C906L_OUTPUT_SIZE, &length);
			break;
		case C906L_JOB_PARK:
			status->parked = 1;
			publish(seq, C906L_OK, 0, 0);
			for (;;)
				__asm__ volatile("wfi");
		default:
			result = C906L_ERR_TYPE;
		}
		publish(seq, result, length, cycles() - t0);
	}
}
