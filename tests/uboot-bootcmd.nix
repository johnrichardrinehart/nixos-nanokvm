# Runs the A/B boot script in U-Boot's sandbox (same hush parser and `test`
# command as the board) across simulated boot sequences. `sysboot`,
# `saveenv` and `fastboot` are replaced by stubs that print what the board
# would have done; `broken2`/`broken3` make loading that partition fail.
# Each boot ends in STATE with the persistent variables; `ab_boots` is
# reset only where a scenario stands in for Linux passing its health check.
{
  lib,
  runCommand,
  sandbox,
  abBootScript,
  layout,
  maxTries,
  maxUnconfirmedBoots,
}:
let
  script = abBootScript {
    inherit maxTries maxUnconfirmedBoots;
    # Loading and saving run against a real card in tests/uboot-env.nix.
    env = layout.env;
    loadenv = "";
    sysboot =
      _part:
      lib.concatStringsSep "; " [
        ''if test -z "''${booted}"; then setenv loadfail 0''
        ''if test "''${ab_part}" = 2; then if test "''${broken2}" = 1; then setenv loadfail 1; fi; fi''
        ''if test "''${ab_part}" = 3; then if test "''${broken3}" = 1; then setenv loadfail 1; fi; fi''
        ''if test "''${loadfail}" = 1; then echo LOADFAIL part=''${ab_part}; else echo BOOT slot=''${ab_slot} part=''${ab_part} trial=''${ab_trial}; setenv booted 1; fi; fi''
      ];
    saveenv = "echo SAVEENV";
    fallback = ''if test -z "''${booted}"; then echo FASTBOOT; fi'';
  };

  boot = "setenv booted; run abboot; echo STATE active=\${ab_active} try=\${ab_try} tries=\${ab_tries} failed=\${ab_failed} boots=\${ab_boots}";

  max = toString maxUnconfirmedBoots;

  # name -> { setup = U-Boot commands; boots = n; expect = lines }
  scenarios = {
    fresh-card = {
      setup = "";
      boots = 1;
      expect = [
        "SAVEENV"
        "BOOT slot=a part=2 trial=0"
        "STATE active=a try=none tries=0 failed=none boots=1"
      ];
    };

    committed-b = {
      setup = "setenv ab_active b; setenv ab_boots 0";
      boots = 1;
      expect = [
        "SAVEENV"
        "BOOT slot=b part=3 trial=0"
        "STATE active=b try=none tries=0 failed=none boots=1"
      ];
    };

    # Every try is spent, then U-Boot records the failure and returns to a.
    # None of these boots is confirmed, yet none reaches recovery.
    trial-exhausted = {
      setup = "setenv ab_active a; setenv ab_try b; setenv ab_tries ${toString maxTries}; setenv ab_boots 0";
      boots = maxTries + 2;
      expect =
        lib.concatMap (n: [
          "SAVEENV"
          "BOOT slot=b part=3 trial=1"
          "STATE active=a try=b tries=${toString (maxTries - n)} failed=none boots=${toString n}"
        ]) (lib.range 1 maxTries)
        ++ [
          "SAVEENV"
          "BOOT slot=a part=2 trial=0"
          "STATE active=a try=none tries=0 failed=b boots=${toString (maxTries + 1)}"
          "SAVEENV"
          "BOOT slot=a part=2 trial=0"
          "STATE active=a try=none tries=0 failed=b boots=${toString (maxTries + 2)}"
        ];
    };

    # Linux passes its health check and commits after the first try: the
    # count restarts and there are no further trial boots.
    trial-committed = {
      setup = "setenv ab_active a; setenv ab_try b; setenv ab_tries ${toString maxTries}; setenv ab_boots 0";
      boots = 1;
      after = "setenv ab_active b; setenv ab_try none; setenv ab_tries 0; setenv ab_boots 0; ${boot}";
      expect = [
        "SAVEENV"
        "BOOT slot=b part=3 trial=1"
        "STATE active=a try=b tries=${toString (maxTries - 1)} failed=none boots=1"
        "SAVEENV"
        "BOOT slot=b part=3 trial=0"
        "STATE active=b try=none tries=0 failed=none boots=1"
      ];
    };

    # The trial slot cannot be loaded: fall back to the other slot as a
    # normal boot. Linux there records the failed trial.
    trial-unloadable = {
      setup = "setenv ab_active a; setenv ab_try b; setenv ab_tries ${toString maxTries}; setenv broken3 1";
      boots = 1;
      expect = [
        "SAVEENV"
        "LOADFAIL part=3"
        "BOOT slot=a part=2 trial=0"
        "STATE active=a try=b tries=${toString (maxTries - 1)} failed=none boots=1"
      ];
    };

    committed-unloadable = {
      setup = "setenv ab_active a; setenv broken2 1";
      boots = 1;
      expect = [
        "SAVEENV"
        "LOADFAIL part=2"
        "BOOT slot=b part=3 trial=0"
        "STATE active=a try=none tries=0 failed=none boots=1"
      ];
    };

    nothing-loads = {
      setup = "setenv broken2 1; setenv broken3 1";
      boots = 1;
      expect = [
        "SAVEENV"
        "LOADFAIL part=2"
        "LOADFAIL part=3"
        "FASTBOOT"
        "STATE active=a try=none tries=0 failed=none boots=1"
      ];
    };

    # Out-of-range tries (never written by nanokvm-ab) count as exhausted.
    garbage-tries = {
      setup = "setenv ab_active a; setenv ab_try b; setenv ab_tries x";
      boots = 1;
      expect = [
        "SAVEENV"
        "BOOT slot=a part=2 trial=0"
        "STATE active=a try=none tries=0 failed=b boots=1"
      ];
    };

    # The committed slot loads but Linux never comes up healthy: after the
    # limit U-Boot resets the count and enters recovery before booting.
    # Leaving fastboot boots normally, and the count starts over.
    hang-enters-recovery = {
      setup = "setenv ab_active a";
      boots = maxUnconfirmedBoots + 2;
      expect =
        lib.concatMap (n: [
          "SAVEENV"
          "BOOT slot=a part=2 trial=0"
          "STATE active=a try=none tries=0 failed=none boots=${toString n}"
        ]) (lib.range 1 maxUnconfirmedBoots)
        ++ [
          "SAVEENV"
          "FASTBOOT"
          "BOOT slot=a part=2 trial=0"
          "STATE active=a try=none tries=0 failed=none boots=0"
          "SAVEENV"
          "BOOT slot=a part=2 trial=0"
          "STATE active=a try=none tries=0 failed=none boots=1"
        ];
    };

    # A count nanokvm-ab never writes counts as exhausted.
    garbage-boots = {
      setup = "setenv ab_active a; setenv ab_boots ${max}x";
      boots = 1;
      expect = [
        "SAVEENV"
        "FASTBOOT"
        "BOOT slot=a part=2 trial=0"
        "STATE active=a try=none tries=0 failed=none boots=0"
      ];
    };
  };

  runScenario = name: s: ''
    echo "--- ${name}"
    cat > expected <<'EOF'
    ${lib.concatStringsSep "\n" s.expect}
    EOF
    commands=${
      lib.escapeShellArg (
        lib.concatStringsSep "; " (
          [ "setenv abboot '${script}'" ]
          ++ lib.optional (s.setup != "") s.setup
          ++ lib.replicate s.boots boot
          ++ lib.optional (s ? after) s.after
        )
      )
    }
    ${sandbox}/u-boot -d ${sandbox}/u-boot.dtb -c "$commands" > output 2>&1 || {
      cat output
      exit 1
    }
    # The sandbox console uses CRLF and appends ANSI colour codes.
    tr -d '\r' < output | sed 's/\x1b\[[0-9;]*m//g' \
      | grep -E '^(BOOT |LOADFAIL |STATE |SAVEENV$|FASTBOOT$)' > actual || true
    if ! diff -u expected actual; then
      echo "full sandbox output:"
      cat output
      exit 1
    fi
  '';
in
runCommand "nanokvm-ab-uboot-bootcmd" { } ''
  ${lib.concatStrings (lib.mapAttrsToList runScenario scenarios)}
  touch $out
''
