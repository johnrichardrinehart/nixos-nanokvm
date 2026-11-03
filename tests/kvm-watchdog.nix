# nanokvm-kvm's capture watchdog (pkgs/nanokvm-kvm/watchdog.h), built and
# run on the build machine: when a stalled capture is restarted, when the
# daemon exits, and that a static picture is no stall.
{ runCommandCC }:
runCommandCC "nanokvm-kvm-watchdog-test" { } ''
  $CC -O2 -Wall -Wextra -Werror -I${../pkgs/nanokvm-kvm} \
    -o watchdog-test ${./kvm-watchdog.c}
  ./watchdog-test
  touch $out
''
