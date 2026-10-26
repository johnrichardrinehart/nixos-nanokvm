# nanokvm-flash-device: the device half of nanokvm-flash-from-stock.
#
# Runs on Sipeed's stock firmware under the static busybox staged next to
# it in a tmpfs, never from the card it overwrites. Usage:
#
#   busybox sh flash.sh quiesce DISK
#   busybox sh flash.sh write DISK IMAGE.zst RAW_SHA256 SIZE
#
# `write` reboots once the card reads back as the image; on any failure it
# exits non-zero and leaves the (frozen, read-only) stock system running.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
bb="$here/busybox"
log() { echo "nanokvm-flash: $*"; }
die() {
  log "FAILED: $*"
  exit 1
}

# major:minor of the disk and each of its partitions.
disk_devs() {
  name="$($bb basename "$1")"
  for d in /sys/class/block/"$name" /sys/class/block/"$name"*; do
    [ -e "$d/dev" ] && $bb cat "$d/dev"
  done | $bb sort -u
}

# Mount points on the disk that are still writable (per mount or superblock).
writable_mounts() {
  devs=" $(disk_devs "$1" | $bb tr '\n' ' ')"
  $bb awk -v devs="$devs" '
    index(devs, " " $3 " ") {
      super = $NF
      if ($6 ~ /^rw(,|$)/ || super ~ /^rw(,|$)/) print $5
    }' /proc/self/mountinfo
}

cmd_quiesce() {
  disk="$1"
  # Stock services that write to the card or hold it open (the USB drive
  # exports the data partition). Missing scripts are skipped.
  for s in S98tailscaled S96picoclaw S95nanokvm S80dnsmasq S50ssdpd \
    S50avahi-daemon S15kvmhwd S03usbhid S03usbdev; do
    if [ -x "/etc/init.d/$s" ]; then
      log "stopping $s"
      "/etc/init.d/$s" stop >/dev/null 2>&1 || true
    fi
  done
  $bb sync
  for m in $(writable_mounts "$disk"); do
    $bb mount -o remount,ro "$m" 2>/dev/null || $bb umount "$m" 2>/dev/null || true
  done
  if [ -n "$(writable_mounts "$disk")" ]; then
    # Emergency remount: every filesystem read-only, open files or not.
    log "forcing read-only remount (sysrq u)"
    echo 1 >/proc/sys/kernel/sysrq 2>/dev/null || true
    echo u >/proc/sysrq-trigger 2>/dev/null || true
    $bb sleep 3
  fi
  left="$(writable_mounts "$disk")"
  [ -z "$left" ] || die "still mounted read-write: $left"
  log "quiesced: nothing on $disk is writable"
}

cmd_write() {
  disk="$1"
  image="$2"
  want="$3"
  size="$4"
  mib=$((size / 1048576))
  [ $((mib * 1048576)) -eq "$size" ] || die "image size $size is not a whole number of MiB"
  [ -z "$(writable_mounts "$disk")" ] || die "$disk has writable mounts; run quiesce first"

  log "writing $mib MiB to $disk"
  "$here/zstd" -dc "$image" | $bb dd of="$disk" bs=1M conv=fsync 2>"$here/dd.err" \
    || die "write failed: $($bb cat "$here/dd.err")"
  $bb sync
  # Read back from the card, not the page cache.
  echo 3 >/proc/sys/vm/drop_caches
  got="$($bb dd if="$disk" bs=1M count="$mib" 2>/dev/null | $bb sha256sum | $bb cut -d' ' -f1)"
  [ "$got" = "$want" ] || die "read-back sha256 $got does not match the image ($want)"
  log "verified $mib MiB"
  log "rebooting"
  $bb sync
  # Let the host's `tail -f` (one-second polls) forward the lines above.
  $bb sleep 3
  $bb reboot -f
}

[ $# -ge 2 ] || die "usage: flash.sh quiesce DISK | write DISK IMAGE RAW_SHA256 SIZE"
command="$1"
shift
case "$command" in
  quiesce) cmd_quiesce "$1" ;;
  write)
    [ $# -eq 4 ] || die "usage: flash.sh write DISK IMAGE RAW_SHA256 SIZE"
    cmd_write "$@"
    ;;
  *) die "unknown command '$command'" ;;
esac
