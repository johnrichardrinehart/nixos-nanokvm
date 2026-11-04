// USB watchdog: decides when the USB gadget must be bound to the UDC again.
// It does no I/O, so tests/kvm-usb-watchdog.c runs it on the build machine.
//
// After some reboots and power cycles of the target, the bound gadget stays
// "not attached": the target does not enumerate it again until the gadget
// is bound anew (a Lenovo M920q, 2026-11-04; keyboard and mouse were dead
// until then). The watchdog binds it again when it is bound and has been
// "not attached" for USB_WD_FIRST_S; then it waits USB_WD_FIRST_S, twice
// that, and so on up to USB_WD_MAX_S between attempts while the target does
// not enumerate it (for example, because it is off). It does nothing while
// the gadget is unbound on purpose (UDC empty), or while another program
// holds the gadget (that program reconfigures it and binds by itself).
#ifndef NANOKVM_USB_WATCHDOG_H
#define NANOKVM_USB_WATCHDOG_H

#define USB_WD_FIRST_S 3.0
#define USB_WD_MAX_S 60.0

struct usb_watchdog {
	double since; // "not attached" while bound since then (0: not so)
	double next;  // no attempt before this
	double wait;  // the wait after the next attempt
};

static inline void usb_wd_reset(struct usb_watchdog *w)
{
	w->since = w->next = 0;
	w->wait = USB_WD_FIRST_S;
}

// One check at time t (> 0). Returns 1 when the gadget must be bound again.
static inline int usb_wd_check(struct usb_watchdog *w, double t, int bound, int held, int not_attached)
{
	if (!bound || held || !not_attached) {
		usb_wd_reset(w);
		return 0;
	}
	if (w->since == 0)
		w->since = t;
	if (t - w->since < USB_WD_FIRST_S || t < w->next)
		return 0;
	w->next = t + w->wait;
	w->wait = w->wait * 2 > USB_WD_MAX_S ? USB_WD_MAX_S : w->wait * 2;
	return 1;
}

#endif
