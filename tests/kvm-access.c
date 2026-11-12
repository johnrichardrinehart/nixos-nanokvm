// Host-side test of nanokvm-kvm's access rule (pkgs/nanokvm-kvm/access.h):
// a client of the view port may send only "key"; a client of the main port
// may send every command.
#include <stdio.h>

#include "access.h"

static int failures;

#define EXPECT(cond)                                                          \
	do {                                                                  \
		if (!(cond)) {                                                \
			fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond); \
			failures++;                                           \
		}                                                             \
	} while (0)

int main(void)
{
	// Every command of the protocol (kvm.c, ws_command), and some that are
	// near "key".
	static const char *const input[] = {
		"k 4 1",       "k 4 0",        "m 100 100 1 0", "r",
		"mode mjpeg",  "mode h264",    "atx power 200", "atx reset 200",
		"atx-wired power 1", "key ",   "keys",          "",
	};
	for (size_t i = 0; i < sizeof input / sizeof *input; i++) {
		EXPECT(command_allowed(0, input[i]));
		EXPECT(!command_allowed(1, input[i]));
	}
	EXPECT(command_allowed(0, "key"));
	EXPECT(command_allowed(1, "key"));

	if (failures) {
		fprintf(stderr, "%d failures\n", failures);
		return 1;
	}
	puts("access: ok");
	return 0;
}
