// Host-side test of nanokvm-kvm's USB watchdog (pkgs/nanokvm-kvm/usb_watchdog.h):
// checks it once a second, as the daemon does, and records when it binds
// the gadget again.
#include <stdio.h>

#include "usb_watchdog.h"

static int failures;

#define EXPECT(cond)                                                          \
	do {                                                                  \
		if (!(cond)) {                                                \
			fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond); \
			failures++;                                           \
		}                                                             \
	} while (0)

// Checks once a second from t0 to t1 (exclusive) with fixed inputs; records
// the times of the binds and returns their number.
static int run(struct usb_watchdog *w, int t0, int t1, int bound, int held, int not_attached, int *binds, int max)
{
	int n = 0;
	for (int t = t0; t < t1; t++)
		if (usb_wd_check(w, t, bound, held, not_attached) && n < max)
			binds[n++] = t;
	return n;
}

int main(void)
{
	struct usb_watchdog w;
	int b[16];

	// Enumerated by the target: nothing for an hour.
	usb_wd_reset(&w);
	EXPECT(run(&w, 1, 3601, 1, 0, 0, b, 16) == 0);

	// Bound and "not attached" (the target missed it after a reboot): the
	// first bind after 3 s, then after waits of 3, 6, 12, 24, 48, 60, 60 s.
	usb_wd_reset(&w);
	int n = run(&w, 100, 400, 1, 0, 1, b, 16);
	const int want[] = { 103, 106, 112, 124, 148, 196, 256, 316, 376 };
	EXPECT(n == (int)(sizeof want / sizeof want[0]));
	for (int i = 0; i < n && i < (int)(sizeof want / sizeof want[0]); i++)
		EXPECT(b[i] == want[i]);

	// The target enumerates it after the second bind: the backoff starts
	// again at the next loss.
	usb_wd_reset(&w);
	EXPECT(run(&w, 100, 107, 1, 0, 1, b, 16) == 2);
	EXPECT(run(&w, 107, 500, 1, 0, 0, b, 16) == 0);
	EXPECT(run(&w, 500, 510, 1, 0, 1, b, 16) == 2 && b[0] == 503 && b[1] == 506);

	// A short loss (a reboot of the target re-enumerates within 3 s): none.
	usb_wd_reset(&w);
	EXPECT(run(&w, 100, 102, 1, 0, 1, b, 16) == 0);
	EXPECT(run(&w, 102, 103, 1, 0, 0, b, 16) == 0);
	EXPECT(run(&w, 103, 105, 1, 0, 1, b, 16) == 0);

	// Unbound on purpose (UDC empty) or held by another program: none, also
	// when that lasts; afterwards the 3 s count from the start.
	usb_wd_reset(&w);
	EXPECT(run(&w, 100, 1000, 0, 0, 1, b, 16) == 0);
	EXPECT(run(&w, 1000, 2000, 1, 1, 1, b, 16) == 0);
	EXPECT(run(&w, 2000, 2004, 1, 0, 1, b, 16) == 1 && b[0] == 2003);

	if (failures) {
		fprintf(stderr, "%d failures\n", failures);
		return 1;
	}
	puts("usb watchdog: ok");
	return 0;
}
