# nanokvm-ab: A/B slot management on the device (busybox ash).
#
# Settings (AB_*) come from the Nix wrapper; NANOKVM_AB_* override them for
# tests.
DISK="${NANOKVM_AB_DISK:-$AB_DISK}"
CMDLINE="${NANOKVM_AB_CMDLINE:-/proc/cmdline}"
STATE_DIR="${NANOKVM_AB_STATE_DIR:-/run/nanokvm-ab}"
RECORDS="${NANOKVM_AB_RECORDS:-/state/nanokvm-ab}"

usage() {
  cat >&2 <<EOF
usage: nanokvm-ab <command> [args]

  status                        print slot and environment state (key=value)
  write --sha256 HEX --raw-sha256 HEX --size BYTES
                                write a zstd-compressed slot image from stdin
                                into the inactive slot
  arm [--tries N]               boot the inactive slot on trial (default $AB_MAX_TRIES)
  commit                        accept the running trial slot (or record a
                                trial that never booted)
  cancel                        drop a pending trial
  rollback                      drop the running trial, mark it failed, reboot
  request-wipe-data             reformat /data (the state partition) on the next boot
  boot-verify                   boot-time health check (init entry)
  trial-deadline                reboot an unconfirmed trial (init entry)
EOF
  exit 2
}

log() { echo "nanokvm-ab: $*" >&2; }
die() {
  log "$*"
  exit 1
}

part_dev() {
  case "$DISK" in
    *[0-9]) echo "${DISK}p$1" ;;
    *) echo "$DISK$1" ;;
  esac
}

slot_dev() {
  case "$1" in
    a) part_dev "$AB_SLOT_A_INDEX" ;;
    b) part_dev "$AB_SLOT_B_INDEX" ;;
    *) die "invalid slot '$1'" ;;
  esac
}

other_slot() {
  case "$1" in
    a) echo b ;;
    b) echo a ;;
    *) die "invalid slot '$1'" ;;
  esac
}

cmdline_get() {
  tr ' ' '\n' <"$CMDLINE" | sed -n "s/^$1=//p" | tail -n 1
}

booted_slot() {
  slot="$(cmdline_get nanokvm.slot)"
  case "$slot" in
    a | b) echo "$slot" ;;
    *) die "kernel command line has no nanokvm.slot; was this booted by the A/B U-Boot?" ;;
  esac
}

booted_trial() {
  [ "$(cmdline_get nanokvm.trial)" = 1 ]
}

# fw_printenv configuration for copy N (1 or 2) of the A/B state.
env_config() {
  mkdir -p "$STATE_DIR"
  # shellcheck disable=SC2086
  set -- "$1" $AB_ENV_OFFSETS
  eval "offset=\${$(($1 + 1))}"
  cfg="$STATE_DIR/fw_env.config"
  [ "$1" = 1 ] || cfg="$STATE_DIR/fw_env-$1.config"
  printf '%s 0x%x 0x%x\n' "$DISK" "$offset" "$AB_ENV_SIZE" >"$cfg"
  echo "$cfg"
}

# Loads copy N into shell variables; fails if its CRC is bad (or blank).
env_read_copy() {
  ab_active=a
  ab_try=none
  ab_tries=0
  ab_failed=none
  ab_wipe=0
  ab_boots=0
  cfg="$(env_config "$1")"
  out="$(fw_printenv -c "$cfg" 2>"$STATE_DIR/fw_printenv.err")" \
    || die "fw_printenv failed: $(cat "$STATE_DIR/fw_printenv.err")"
  if grep -q 'Bad CRC' "$STATE_DIR/fw_printenv.err"; then
    return 1
  fi
  for line in $out; do
    case "$line" in
      ab_active=a | ab_active=b) ab_active="${line#*=}" ;;
      ab_try=a | ab_try=b | ab_try=none) ab_try="${line#*=}" ;;
      ab_tries=[0-9]) ab_tries="${line#*=}" ;;
      ab_failed=a | ab_failed=b | ab_failed=none) ab_failed="${line#*=}" ;;
      ab_wipe=1) ab_wipe=1 ;;
      ab_boots=[0-9]) ab_boots="${line#*=}" ;;
    esac
  done
}

# Loads the A/B state as U-Boot does (lib/boot-script.nix): copy 1, else
# copy 2, else the defaults (a fresh card). Missing or invalid values fall
# back to the same defaults.
env_load() {
  ENV_STATE=ok
  env_read_copy 1 && return
  ENV_STATE=copy2
  env_read_copy 2 && return
  ENV_STATE=empty
  env_read_copy 1 || true
}

# Writes the A/B state to copy 1, then copy 2, and reads both back. A torn
# write leaves the other copy intact. The block holds only these names;
# U-Boot imports nothing else from it.
env_store() {
  tmp="$(mktemp -d)"
  {
    echo "ab_active=$ab_active"
    echo "ab_try=$ab_try"
    echo "ab_tries=$ab_tries"
    echo "ab_failed=$ab_failed"
    echo "ab_wipe=$ab_wipe"
    echo "ab_boots=$ab_boots"
  } >"$tmp/env.txt"
  mkenvimage -s "$AB_ENV_SIZE" -o "$tmp/env.bin" "$tmp/env.txt"
  for offset in $AB_ENV_OFFSETS; do
    dd if="$tmp/env.bin" of="$DISK" bs="$AB_ENV_SIZE" seek=$((offset / AB_ENV_SIZE)) \
      conv=notrunc,fsync 2>/dev/null || die "writing the A/B state at $offset failed"
  done
  rm -rf "$tmp"

  wanted="$ab_active $ab_try $ab_tries $ab_failed $ab_wipe $ab_boots"
  for copy in 1 2; do
    env_read_copy "$copy" || die "A/B state copy $copy failed its CRC after writing"
    readback="$ab_active $ab_try $ab_tries $ab_failed $ab_wipe $ab_boots"
    [ "$readback" = "$wanted" ] \
      || die "A/B state copy $copy reads back as ($readback), not ($wanted)"
  done
  ENV_STATE=ok
}

slot_record() {
  cat "$RECORDS/slot-$1.sha256" 2>/dev/null || echo unknown
}

cmd_status() {
  env_load
  booted="$(cmdline_get nanokvm.slot)"
  trial="$(cmdline_get nanokvm.trial)"
  committed=0
  healthy=0
  [ -e "$STATE_DIR/committed" ] && committed=1
  [ -e "$STATE_DIR/healthy" ] && healthy=1
  cat <<EOF
booted=${booted:-unknown}
trial=${trial:-0}
committed=$committed
healthy=$healthy
active=$ab_active
try=$ab_try
tries=$ab_tries
failed=$ab_failed
wipe=$ab_wipe
boots=$ab_boots
env=$ENV_STATE
image=$(slot_record "${booted:-none}")
boot_id=$(cat /proc/sys/kernel/random/boot_id)
EOF
}

cmd_write() {
  sha=""
  raw_sha=""
  size=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha256) sha="$2"; shift 2 ;;
      --raw-sha256) raw_sha="$2"; shift 2 ;;
      --size) size="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$sha" ] && [ -n "$raw_sha" ] && [ -n "$size" ] || usage

  booted="$(booted_slot)"
  env_load
  [ "$ab_active" = "$booted" ] \
    || die "booted slot $booted is not the committed slot ($ab_active); run 'nanokvm-ab commit' or reboot to roll back first"
  target="$(other_slot "$booted")"
  dev="$(slot_dev "$target")"
  [ -b "$dev" ] || die "$dev is not a block device"
  slot_bytes=$(($(cat "/sys/class/block/${dev##*/}/size") * 512))
  [ "$size" -le "$slot_bytes" ] || die "image ($size bytes) does not fit slot $target ($slot_bytes bytes)"

  # A slot that is being rewritten must never be booted.
  if [ "$ab_try" = "$target" ]; then
    ab_try=none
    ab_tries=0
    env_store
  fi
  rm -f "$RECORDS/slot-$target.sha256"
  dd if=/dev/zero of="$dev" bs=1M count=1 conv=fsync 2>/dev/null

  fifo="$STATE_DIR/stream.fifo"
  hashfile="$STATE_DIR/stream.sha256"
  rm -f "$fifo" "$hashfile"
  mkfifo "$fifo"
  sha256sum <"$fifo" >"$hashfile" &
  hash_pid=$!
  log "writing slot $target ($dev)"
  if ! { tee "$fifo" | zstd -dcq | dd of="$dev" bs=1M conv=fsync 2>/dev/null; }; then
    wait "$hash_pid"
    dd if=/dev/zero of="$dev" bs=1M count=1 conv=fsync 2>/dev/null
    die "writing $dev failed"
  fi
  wait "$hash_pid"
  received="$(cut -d' ' -f1 "$hashfile")"
  written="$(head -c "$size" "$dev" | sha256sum | cut -d' ' -f1)"
  rm -f "$fifo" "$hashfile"
  if [ "$received" != "$sha" ] || [ "$written" != "$raw_sha" ]; then
    dd if=/dev/zero of="$dev" bs=1M count=1 conv=fsync 2>/dev/null
    [ "$received" = "$sha" ] || die "transfer checksum mismatch: expected $sha, received $received"
    die "read-back checksum mismatch on $dev: expected $raw_sha, found $written"
  fi

  mkdir -p "$RECORDS"
  echo "$sha" >"$RECORDS/slot-$target.sha256"
  sync
  echo "slot=$target"
}

cmd_arm() {
  tries="$AB_MAX_TRIES"
  while [ $# -gt 0 ]; do
    case "$1" in
      --tries) tries="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$tries" in
    [1-9]) [ "$tries" -le "$AB_MAX_TRIES" ] || die "--tries must be 1..$AB_MAX_TRIES" ;;
    *) die "--tries must be 1..$AB_MAX_TRIES" ;;
  esac

  booted="$(booted_slot)"
  env_load
  [ "$ab_active" = "$booted" ] || die "booted slot $booted is not the committed slot ($ab_active)"
  target="$(other_slot "$booted")"
  [ "$(slot_record "$target")" != unknown ] || die "slot $target holds no verified image; write one first"
  ab_try="$target"
  ab_tries="$tries"
  ab_failed=none
  env_store
  echo "armed=$target"
  echo "tries=$tries"
}

commit() {
  booted="$(booted_slot)"
  env_load
  if booted_trial; then
    ab_try=none
    ab_tries=0
    ab_failed=none
  elif [ "$ab_try" != none ] && [ "$ab_try" != "$booted" ]; then
    # U-Boot could not load the trial slot and fell back to this one.
    log "trial of slot $ab_try did not boot; recording it as failed"
    ab_failed="$ab_try"
    ab_try=none
    ab_tries=0
  fi
  # Booting a slot outside a trial means the other one could not be loaded.
  ab_active="$booted"
  ab_wipe=0
  env_store
  mkdir -p "$STATE_DIR"
  touch "$STATE_DIR/committed"
  echo "active=$ab_active"
}

cmd_commit() {
  if booted_trial && [ ! -e "$STATE_DIR/committed" ]; then
    i=0
    while [ ! -e "$STATE_DIR/healthy" ]; do
      i=$((i + 1))
      [ "$i" -le 150 ] || die "the boot health check has not passed; not committing"
      sleep 2
    done
  fi
  commit
}

cmd_cancel() {
  env_load
  ab_try=none
  ab_tries=0
  env_store
  echo "try=none"
}

cmd_rollback() {
  booted="$(booted_slot)"
  if ! booted_trial || [ -e "$STATE_DIR/committed" ]; then
    die "slot $booted is not an unconfirmed trial"
  fi
  env_load
  ab_failed="$booted"
  ab_try=none
  ab_tries=0
  env_store
  reboot
}

cmd_request_wipe_data() {
  env_load
  ab_wipe=1
  env_store
  echo "wipe=1 (applied on the next boot)"
}

# Polls the health check until it passes or the trial timeout expires.
healthy_within() {
  deadline=$(($(date +%s) + AB_TRIAL_TIMEOUT))
  until "$AB_HEALTH_CHECK"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 2
  done
}

# Clears U-Boot's count of unconfirmed boots: this boot came up healthy.
boot_confirmed() {
  env_load
  ab_boots=0
  env_store
}

cmd_boot_verify() {
  mkdir -p "$STATE_DIR"
  if ! booted_trial; then
    if healthy_within; then
      boot_confirmed
    else
      log "health check failed on a committed slot"
    fi
    touch "$STATE_DIR/healthy"
    commit
    return
  fi
  if ! healthy_within; then
    log "trial slot $(booted_slot) failed its health check; rebooting"
    reboot
    return 1
  fi
  boot_confirmed
  touch "$STATE_DIR/healthy"
  if [ "$AB_CONFIRM" = device ]; then
    commit
  else
    log "trial slot $(booted_slot) is healthy; waiting for the deployer to run 'nanokvm-ab commit'"
  fi
}

cmd_trial_deadline() {
  booted_trial || exit 0
  sleep "$AB_TRIAL_TIMEOUT"
  if [ ! -e "$STATE_DIR/committed" ]; then
    log "trial slot $(booted_slot) was not committed within ${AB_TRIAL_TIMEOUT}s; rebooting"
    reboot
  fi
}

[ $# -ge 1 ] || usage
command="$1"
shift
case "$command" in
  status) cmd_status ;;
  write) cmd_write "$@" ;;
  arm) cmd_arm "$@" ;;
  commit) cmd_commit ;;
  cancel) cmd_cancel ;;
  rollback) cmd_rollback ;;
  request-wipe-data) cmd_request_wipe_data ;;
  boot-verify) cmd_boot_verify ;;
  trial-deadline) cmd_trial_deadline ;;
  *) usage ;;
esac
