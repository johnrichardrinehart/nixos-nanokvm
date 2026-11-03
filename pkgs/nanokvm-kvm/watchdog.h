// Capture watchdog: decides when an HDMI capture that stopped delivering
// frames must be restarted, and when the process must exit so that runit
// starts it again. It does no I/O, so tests/kvm-watchdog.c runs it on the
// build machine.
//
// It watches frame arrival at the capture, not changed pictures: the
// LT6911 sends every frame while it has a signal, and the capture driver
// completes a buffer for each, also when the picture does not change (on
// the board, 61 to 64 frames a second with a static picture).
#ifndef NANOKVM_WATCHDOG_H
#define NANOKVM_WATCHDOG_H

#define STALL_S 3.0     // no frame for this long: restart the capture
#define RESTARTS_MAX 2  // restarts without a frame before the exit
#define EXIT_STALLED 75 // exit status that asks runit for a restart (EX_TEMPFAIL)

enum wd_action { WD_OK, WD_RESTART, WD_EXIT };

struct watchdog {
	double frame_at; // last good frame, or when watching started
	double step_at;  // last restart, or frame_at
	int restarts;    // restarts since frame_at
};

// Starts to watch a new stream (new mode, size, signal or viewers).
static inline void wd_reset(struct watchdog *w, double t)
{
	w->frame_at = w->step_at = t;
	w->restarts = 0;
}

// A good frame came in. Returns 1 when it ends a stall.
static inline int wd_frame(struct watchdog *w, double t)
{
	int recovered = w->restarts > 0;
	wd_reset(w, t);
	return recovered;
}

// Seconds without a frame.
static inline double wd_stalled(const struct watchdog *w, double t) { return t - w->frame_at; }

// While the capture must stream: restart it after STALL_S without a
// frame, again after 2 * STALL_S more, and exit after 4 * STALL_S more.
// The growing waits limit the restart rate.
static inline enum wd_action wd_check(struct watchdog *w, double t)
{
	if (t - w->step_at < STALL_S * (double)(1 << w->restarts))
		return WD_OK;
	if (w->restarts >= RESTARTS_MAX)
		return WD_EXIT;
	w->restarts++;
	w->step_at = t;
	return WD_RESTART;
}

#endif
