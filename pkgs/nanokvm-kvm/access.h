// Which WebSocket commands a client may send (kvm.c, ws_command).
//
// A client of the view port (--view-port) only watches: it may ask for a
// full picture ("key"), and nothing that reaches the target (keys, pointer,
// ATX buttons) or changes the server's settings (video mode, ATX wiring).
// The view port is the server's decision, not the page's: a page or a
// script on that port cannot turn input on.
#ifndef NANOKVM_ACCESS_H
#define NANOKVM_ACCESS_H

#include <string.h>

static inline int command_allowed(int view_only, const char *cmd)
{
	return !view_only || !strcmp(cmd, "key");
}

#endif
