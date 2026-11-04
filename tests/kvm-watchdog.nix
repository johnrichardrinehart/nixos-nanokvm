# nanokvm-kvm's watchdogs, built and run on the build machine:
# - the capture watchdog (pkgs/nanokvm-kvm/watchdog.h): when a stalled
#   capture is restarted, when the daemon exits, and that a static picture is
#   no stall;
# - the USB watchdog (pkgs/nanokvm-kvm/usb_watchdog.h): when the gadget is
#   bound again, its backoff, and when it does nothing.
{ runCommandCC }:
runCommandCC "nanokvm-kvm-watchdog-test" { } ''
  $CC -O2 -Wall -Wextra -Werror -I${../pkgs/nanokvm-kvm} \
    -o watchdog-test ${./kvm-watchdog.c}
  ./watchdog-test
  $CC -O2 -Wall -Wextra -Werror -I${../pkgs/nanokvm-kvm} \
    -o usb-watchdog-test ${./kvm-usb-watchdog.c}
  ./usb-watchdog-test
  touch $out
''
