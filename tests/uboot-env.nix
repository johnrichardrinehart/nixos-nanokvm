# The A/B state on a real (file-backed) card: the boot script's own
# `mmc read` + `env import -c` and `env export -c` + `mmc write`, in U-Boot's
# sandbox with no U-Boot environment of its own (as on the board). One
# sandbox run is one boot. The other side is what nanokvm-ab uses:
# mkenvimage blocks in, fw_printenv out.
#
# Checks: a blank card boots slot A and saves the state to both copies;
# Linux's state is picked up; a torn copy 1 falls back to copy 2 and both
# are rewritten; only ab_* names are imported (a block cannot replace
# bootcmd); unconfirmed boots reach recovery across real power cycles.
{
  lib,
  runCommand,
  sandbox,
  layout,
  abBootScript,
  maxTries,
  maxUnconfirmedBoots,
  envTools,
  dtc,
}:
let
  hex = n: "0x${lib.toLower (lib.toHexString n)}";
  inherit (layout.env) size offsets;
  copy1 = lib.elemAt offsets 0;
  copy2 = lib.elemAt offsets 1;

  script = abBootScript {
    inherit maxTries maxUnconfirmedBoots;
    inherit (layout) env;
    scratch = "0x1000000";
    sysboot =
      _part:
      ''if test -z "''${booted}"; then echo BOOT slot=''${ab_slot} trial=''${ab_trial}; setenv booted 1; fi'';
    fallback = ''if test -z "''${booted}"; then echo FASTBOOT; fi'';
  };

  boot = lib.concatStringsSep "; " [
    "setenv abboot '${script}'"
    "setenv bootcmd echo ORIGINAL"
    "run abboot"
    "echo AFTER bootcmd=\${bootcmd} evil=\${evil}"
  ];
in
runCommand "nanokvm-uboot-env"
  {
    nativeBuildInputs = [
      dtc
      envTools
    ];
  }
  ''
    set -euo pipefail
    dtc -I dtb -O dts -o sandbox.dts ${sandbox}/u-boot.dtb 2>/dev/null
    cat >>sandbox.dts <<'EOF'
    / {
    	aliases { mmc0 = "/card"; };
    	card {
    		compatible = "sandbox,mmc";
    		filename = "card.img";
    	};
    };
    EOF
    dtc -I dts -O dtb -o sandbox.dtb sandbox.dts 2>/dev/null
    truncate -s 32M card.img
    echo "card.img ${hex copy1} ${hex size}" > copy1.config
    echo "card.img ${hex copy2} ${hex size}" > copy2.config
    cat > boot.cmd <<'EOF'
    ${boot}
    EOF

    # One power cycle; prints the script's own lines.
    boot() {
      ${sandbox}/u-boot -d sandbox.dtb -c "$(cat boot.cmd)" > out 2>&1 || { cat out; exit 1; }
      tr -d '\r' < out | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -E '^(nanokvm-ab:|BOOT |FASTBOOT|AFTER )' || true
    }
    # Writes name=value lines to copy N as nanokvm-ab does.
    put() {
      n=$1; shift
      printf '%s\n' "$@" > env.txt
      mkenvimage -s ${toString size} -o env.bin env.txt
      off=$copy1; [ "$n" = 1 ] || off=$copy2
      dd if=env.bin of=card.img bs=${toString size} seek=$((off / ${toString size})) conv=notrunc status=none
    }
    copy1=${toString copy1}
    copy2=${toString copy2}
    get() { fw_printenv -l . -c copy$1.config -n "$2" 2>/dev/null; }
    expect() {
      if [ "$1" != "$2" ]; then
        echo "FAIL: $3: got '$1', want '$2'"
        for n in 1 2; do echo "copy $n:"; fw_printenv -l . -c copy$n.config 2>&1 | head -20; done
        od -A x -t x1z -j $copy1 -N 64 card.img; tr -d "\r" < out | grep -iE "export|import|##|MMC (read|write)"
        exit 1
      fi
    }

    echo "--- blank card"
    b=$(boot)
    echo "$b"
    grep -qx "nanokvm-ab: no saved state" <<<"$b"
    grep -qx "BOOT slot=a trial=0" <<<"$b"
    for n in 1 2; do
      expect "$(get $n ab_boots)" 1 "copy $n ab_boots"
      expect "$(get $n ab_active)" a "copy $n ab_active"
    done

    echo "--- state written by Linux"
    for n in 1 2; do put $n ab_active=b ab_try=none ab_tries=0 ab_failed=a ab_wipe=0 ab_boots=0; done
    b=$(boot)
    echo "$b"
    grep -qx "nanokvm-ab: state from copy 1" <<<"$b"
    grep -qx "BOOT slot=b trial=0" <<<"$b"
    for n in 1 2; do
      expect "$(get $n ab_boots)" 1 "copy $n ab_boots"
      expect "$(get $n ab_failed)" a "copy $n ab_failed"
    done

    echo "--- torn copy 1"
    put 2 ab_active=b ab_try=none ab_tries=0 ab_failed=none ab_wipe=0 ab_boots=2
    printf 'X' | dd of=card.img bs=1 seek=$((copy1 + 10)) conv=notrunc status=none
    b=$(boot)
    echo "$b"
    grep -qx "nanokvm-ab: state from copy 2" <<<"$b"
    grep -qx "BOOT slot=b trial=0" <<<"$b"
    for n in 1 2; do expect "$(get $n ab_boots)" 3 "copy $n ab_boots"; done

    echo "--- only ab_* names are imported"
    for n in 1 2; do put $n ab_active=b ab_boots=0 'bootcmd=echo PWNED' evil=1; done
    b=$(boot)
    echo "$b"
    grep -qx "BOOT slot=b trial=0" <<<"$b"
    grep -qx "AFTER bootcmd=echo ORIGINAL evil=" <<<"$b"
    expect "$(get 1 bootcmd || true)" "" "bootcmd saved to copy 1"

    echo "--- unconfirmed boots reach recovery across power cycles"
    for n in 1 2; do put $n ab_active=a ab_boots=0; done
    for i in $(seq ${toString maxUnconfirmedBoots}); do
      b=$(boot)
      grep -qx "BOOT slot=a trial=0" <<<"$b"
      ! grep -q FASTBOOT <<<"$b"
    done
    b=$(boot)
    echo "$b"
    grep -qx FASTBOOT <<<"$b"
    expect "$(get 1 ab_boots)" 0 "count after recovery"

    touch $out
  ''
