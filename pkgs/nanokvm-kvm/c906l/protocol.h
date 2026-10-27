// Job protocol between nanokvm-kvm (Linux, 1 GHz C906) and its firmware on
// the 700 MHz C906L. Both sides see the region in lib/c906l.nix:
//
//   C906L_BASE + 0x000000  firmware: code, data, heap, stack (1 MiB)
//   C906L_BASE + 0x100000  control page (4 KiB): status line, job line
//   C906L_BASE + 0x200000  output (2 MiB)
//   C906L_BASE + 0x400000  input (4 MiB): the frame, packed UYVY, which
//                          Linux copies in (it cannot learn the physical
//                          address of its capture buffers)
//
// The caches of the two cores are not coherent. Linux maps the region
// cached and cleans and invalidates what it shares (th.dcache.civa, allowed
// in user mode on the C906); the firmware invalidates what it reads and
// cleans what it writes. Each 64-byte line has one writer. Linux writes a
// job's fields, then its sequence number; the firmware writes the output,
// then the status line with done = sequence.
#ifndef NANOKVM_C906L_PROTOCOL_H
#define NANOKVM_C906L_PROTOCOL_H

#include <stdint.h>

#define C906L_BASE 0x8f800000UL
#define C906L_SIZE 0x800000UL
#define C906L_CONTROL (C906L_BASE + 0x100000UL)
#define C906L_OUTPUT (C906L_BASE + 0x200000UL)
#define C906L_OUTPUT_SIZE 0x200000UL
#define C906L_INPUT (C906L_BASE + 0x400000UL)
#define C906L_INPUT_SIZE 0x400000UL

#define C906L_MAGIC 0x4c363039u // "906L"
#define C906L_VERSION 2u

enum c906l_job_type {
	C906L_JOB_NONE = 0,
	C906L_JOB_JPEG = 1, // JPEG a band of UYVY rows, full or half size
	C906L_JOB_PARK = 2, // stop touching memory and wait for a reset
};

enum c906l_result {
	C906L_OK = 0,
	C906L_ERR_TYPE = 1,
	C906L_ERR_SPACE = 2, // output larger than C906L_OUTPUT_SIZE
	C906L_ERR_JPEG = 3,
	C906L_ERR_ARGS = 4,
};

// Written by the firmware only.
struct c906l_status {
	uint32_t magic;
	uint32_t version;
	uint32_t heartbeat; // increments while idle
	uint32_t done;      // sequence number of the last finished job
	uint32_t result;    // enum c906l_result of that job
	uint32_t length;    // bytes written at C906L_OUTPUT
	uint32_t cycles;    // rdcycle ticks the job took
	uint32_t parked;
	uint32_t pad[8];
};

// Written by Linux only; seq last.
struct c906l_job {
	uint32_t type;
	uint32_t width, height, stride; // the band: `height` source rows
	uint64_t frame; // physical address of its first UYVY row
	uint32_t quality;
	uint32_t half; // JPEG at half size (2x2 decimation)
	uint32_t pad[7];
	uint32_t seq;
};

_Static_assert(sizeof(struct c906l_status) == 64, "status line");
_Static_assert(sizeof(struct c906l_job) == 64, "job line");

#endif
