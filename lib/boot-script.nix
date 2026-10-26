# U-Boot hush script that selects and boots an A/B slot.
#
# Persistent variables, kept in two copies of a U-Boot environment block
# (CRC32 + NUL-separated name=value pairs, the format of `env export -c`,
# mkenvimage and fw_printenv) outside every partition:
#   ab_active  a|b        last committed slot
#   ab_try     a|b|none   slot under trial
#   ab_tries   0..N       trial boots left; decremented before each attempt
#   ab_failed  a|b|none   last slot whose trial ran out of tries
#   ab_wipe    0|1        reformat /state on the next boot
#   ab_boots   0..M       boots since Linux last passed its health check;
#                         M unconfirmed boots enter recovery
#
# U-Boot itself keeps no environment (ENV_IS_NOWHERE): an on-card
# environment hangs U-Boot during startup on the SG2002. The script loads
# the block with `mmc read` + `env import -c`, which takes only the names
# above, so nothing on the card can replace bootcmd. It reads copy 1, and
# copy 2 if copy 1 fails its CRC; both missing means a fresh card. Writers
# (this script and nanokvm-ab) write copy 1, then copy 2, so a torn write
# leaves one intact copy.
#
# Per-boot variables, expanded into extlinux APPEND by U-Boot's pxe code:
#   ab_slot   slot being booted       -> nanokvm.slot=
#   ab_trial  1 when this is a trial  -> nanokvm.trial=
#
# Every boot counts itself and saves the state before loading a slot. A
# committed slot that loads but never comes up healthy (kernel panic, hang,
# watchdog reset) would otherwise reboot forever: after maxUnconfirmedBoots
# such boots U-Boot resets the count and runs the recovery command (USB
# fastboot) instead. Leaving fastboot (`fastboot continue`) boots normally.
#
# Counts are compared as strings, not with setexpr, so the script needs
# nothing beyond the default hush parser and `test`.
{ lib }:
{
  maxTries,
  maxUnconfirmedBoots,
  # Where the two copies live (lib/layout.nix env) and a scratch address
  # in RAM for one copy.
  env,
  scratch ? "\${ramdisk_addr_r}",
  # Overridable so the sandbox test can observe the decisions; null means
  # the real commands built from `env`.
  loadenv ? null,
  saveenv ? null,
  sysboot ? part: "sysboot mmc 0:${part} any 0x80c00000 /extlinux/extlinux.conf",
  fallback ? "fastboot usb 0",
}:
let
  persistentVars = [
    "ab_active"
    "ab_try"
    "ab_tries"
    "ab_failed"
    "ab_wipe"
    "ab_boots"
  ];
  vars = lib.concatStringsSep " " persistentVars;
  hex = n: "0x${lib.toLower (lib.toHexString n)}";
  blocks = hex (env.size / 512);
  size = hex env.size;
  copy = offset: hex (offset / 512);
  importCopy =
    offset: "mmc read ${scratch} ${copy offset} ${blocks} && env import -c ${scratch} ${size} ${vars}";
  loadCommand = lib.concatStringsSep "; " [
    "mmc dev 0"
    "if ${importCopy (lib.elemAt env.offsets 0)}; then echo nanokvm-ab: state from copy 1; elif ${importCopy (lib.elemAt env.offsets 1)}; then echo nanokvm-ab: state from copy 2; else echo nanokvm-ab: no saved state; fi"
  ];
  saveCommand = lib.concatStringsSep "; " (
    # Unlike import, export takes the block size as `-s`.
    [ "env export -c -s ${size} ${scratch} ${vars}" ]
    ++ map (offset: "mmc write ${scratch} ${copy offset} ${blocks}") env.offsets
  );
  default = name: value: ''if test -z "''${${name}}"; then setenv ${name} ${value}; fi'';
  tryBranch =
    n:
    ''test "''${ab_tries}" = ${toString n}; then setenv ab_tries ${toString (n - 1)}; setenv ab_slot ''${ab_try}; setenv ab_trial 1'';
  tries = lib.reverseList (lib.range 1 maxTries);
  trialChain =
    "if "
    + lib.concatMapStringsSep "; elif " tryBranch tries
    + "; else setenv ab_failed \${ab_try}; setenv ab_try none; setenv ab_tries 0; fi";
  # 0 -> 1 -> ... -> M; M itself or garbage enters recovery.
  countBranch = n: ''test "''${ab_boots}" = ${toString n}; then setenv ab_boots ${toString (n + 1)}'';
  countChain =
    "if "
    + lib.concatMapStringsSep "; elif " countBranch (lib.range 0 (maxUnconfirmedBoots - 1))
    + "; else setenv ab_boots 0; setenv ab_recover 1; fi";
  statements = lib.filter (s: s != "") [
    (if loadenv == null then loadCommand else loadenv)
    (default "ab_active" "a")
    (default "ab_try" "none")
    (default "ab_tries" "0")
    (default "ab_failed" "none")
    (default "ab_wipe" "0")
    (default "ab_boots" "0")
    "setenv ab_slot a"
    "setenv ab_trial 0"
    "setenv ab_recover 0"
    countChain
    ''if test "''${ab_active}" = b; then setenv ab_slot b; fi''
    ''if test "''${ab_try}" = a || test "''${ab_try}" = b; then ${trialChain}; fi''
    (if saveenv == null then saveCommand else saveenv)
    ''if test "''${ab_recover}" = 1; then echo "nanokvm-ab: ${toString maxUnconfirmedBoots} boots without a healthy system, entering recovery"; ${fallback}; fi''
    ''if test "''${ab_slot}" = b; then setenv ab_part 3; else setenv ab_part 2; fi''
    (sysboot "\${ab_part}")
    # sysboot only returns when the slot could not be loaded. Try the other
    # slot as a normal boot; Linux there sees the unfinished trial and
    # records it as failed.
    ''echo "nanokvm-ab: slot ''${ab_slot} did not boot, trying the other slot"''
    ''if test "''${ab_slot}" = b; then setenv ab_slot a; setenv ab_part 2; else setenv ab_slot b; setenv ab_part 3; fi''
    "setenv ab_trial 0"
    (sysboot "\${ab_part}")
    fallback
  ];
in
assert lib.assertMsg (maxTries >= 1 && maxTries <= 9) "nanokvm-ab: maxTries must be 1..9";
assert lib.assertMsg (maxUnconfirmedBoots > maxTries + 1 && maxUnconfirmedBoots <= 9)
  "nanokvm-ab: maxUnconfirmedBoots must be maxTries+2..9, so a failed trial and its fallback boot cannot enter recovery";
lib.concatStringsSep "; " statements
