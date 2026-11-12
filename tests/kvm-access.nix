# nanokvm-kvm's access rule (pkgs/nanokvm-kvm/access.h), built and run on
# the build machine: a client of the view port sends no input.
{ runCommandCC }:
runCommandCC "nanokvm-kvm-access-test" { } ''
  $CC -O2 -Wall -Wextra -Werror -I${../pkgs/nanokvm-kvm} \
    -o access-test ${./kvm-access.c}
  ./access-test
  touch $out
''
