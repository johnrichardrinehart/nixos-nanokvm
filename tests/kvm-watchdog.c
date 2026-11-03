// Host-side test of nanokvm-kvm's capture watchdog (pkgs/nanokvm-kvm/watchdog.h):
// feeds it frame arrival times as the video thread does and checks when it
// restarts the capture and when it exits.
#include <stdio.h>

#include "watchdog.h"

static int failures;

#define EXPECT(cond)                                                          \
	do {                                                                  \
		if (!(cond)) {                                                \
			fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond); \
			failures++;                                           \
		}                                                             \
	} while (0)

// Runs the video loop from t0 to t1, one iteration every `step` seconds,
// with a frame every `frame_every` seconds (0: none). Records the times of
// restarts and of the exit; returns the number of restarts.
static int run(struct watchdog *w, double t0, double t1, double step, double frame_every, double *restarts,
	       int max, double *exit_at, int *recovered)
{
	int n = 0;
	double next_frame = t0;
	*exit_at = -1;
	for (double t = t0; t < t1; t += step) {
		enum wd_action a = wd_check(w, t);
		if (a == WD_EXIT) {
			*exit_at = t;
			return n;
		}
		if (a == WD_RESTART && n < max)
			restarts[n++] = t;
		if (frame_every > 0 && t >= next_frame) {
			if (wd_frame(w, t) && recovered)
				(*recovered)++;
			next_frame += frame_every;
		}
	}
	return n;
}

static int near(double a, double b) { return a > b - 0.15 && a < b + 0.15; }

int main(void)
{
	const double s = STALL_S;
	struct watchdog w;
	double r[8], exit_at;
	int rec = 0;

	// A static picture: the capture still delivers 60 frames a second
	// (measured on the board), so nothing happens in ten minutes.
	wd_reset(&w, 0);
	EXPECT(run(&w, 0, 600, 1.0 / 60, 1.0 / 60, r, 8, &exit_at, &rec) == 0);
	EXPECT(exit_at < 0);

	// A slow loop (full-frame MJPEG with a C906L wait) still sees a frame
	// every 2 s: no restart.
	wd_reset(&w, 0);
	EXPECT(run(&w, 0, 600, 0.5, 2, r, 8, &exit_at, &rec) == 0);
	EXPECT(exit_at < 0);

	// Frames stop at t = 10 and never come back: restart STALL_S later,
	// again 2 * STALL_S after that, exit 4 * STALL_S after the second
	// restart.
	wd_reset(&w, 0);
	EXPECT(run(&w, 0, 10.01, 1.0 / 60, 1.0 / 60, r, 8, &exit_at, &rec) == 0);
	int n = run(&w, 10.01, 10 + 10 * s, 0.1, 0, r, 8, &exit_at, &rec);
	EXPECT(n == 2);
	EXPECT(near(r[0], 10 + s));
	EXPECT(near(r[1], 10 + 3 * s));
	EXPECT(near(exit_at, 10 + 7 * s));
	EXPECT(near(wd_stalled(&w, exit_at), 7 * s));

	// Poll timeouts: with no frame the loop runs once a second; the first
	// restart still comes within a second of STALL_S.
	wd_reset(&w, 0);
	n = run(&w, 0, s + 2, 1, 0, r, 8, &exit_at, &rec);
	EXPECT(n == 1 && r[0] >= s && r[0] < s + 1);

	// The first restart brings frames back: one "recovered", and the next
	// stall starts the sequence again at STALL_S.
	wd_reset(&w, 0);
	n = run(&w, 0, s + 0.15, 0.1, 0, r, 8, &exit_at, &rec);
	EXPECT(n == 1 && near(r[0], s));
	rec = 0;
	EXPECT(run(&w, s + 0.2, 30, 1.0 / 60, 1.0 / 60, r, 8, &exit_at, &rec) == 0);
	EXPECT(rec == 1);
	n = run(&w, 30, 30 + s + 1, 0.1, 0, r, 8, &exit_at, &rec);
	EXPECT(n == 1 && near(r[0], 30 + s));

	// A new stream (mode, size, signal or viewers) starts from zero
	// restarts, also during a stall.
	wd_reset(&w, 0);
	n = run(&w, 0, 3 * s + 1, 0.1, 0, r, 8, &exit_at, &rec);
	EXPECT(n == 2);
	wd_reset(&w, 3 * s + 1);
	n = run(&w, 3 * s + 1, 4 * s + 1.5, 0.1, 0, r, 8, &exit_at, &rec);
	EXPECT(n == 1 && near(r[0], 4 * s + 1));
	EXPECT(exit_at < 0);

	if (failures) {
		fprintf(stderr, "%d failures\n", failures);
		return 1;
	}
	printf("watchdog: all cases pass\n");
	return 0;
}
