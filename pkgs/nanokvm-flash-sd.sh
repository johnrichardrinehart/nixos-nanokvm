# nanokvm-flash-sd: write this flake's SD image (or a downloaded release
# image) to an SD card in this machine's card reader, then read it back
# against the image's SHA-256. Linux and macOS.
#
# SD_IMAGE, SD_RAW_SHA256 (both empty when built without an image) and
# FIRMWARE_OFFSET come from the Nix wrapper.

usage() {
  cat >&2 <<EOF
usage: nanokvm-flash-sd [options] DISK

Writes the NanoKVM SD image to DISK (a whole removable disk: /dev/sdX or
/dev/mmcblkN on Linux, /dev/diskN on macOS), reads it back and checks it.
Everything on DISK is erased. Runs dd through sudo unless DISK is writable.

options:
  --image FILE     write FILE (.img or .img.zst, e.g. a release download)
                   instead of this flake's image
  --backup FILE    first save the whole card to FILE (zstd-compressed)
  --authorized-keys FILE
                   also put FILE on the card as root's SSH keys
  --yes            do not ask for confirmation

image:  ${SD_IMAGE:-none built in (macOS): pass --image}
EOF
  exit 2
}

say() { printf '==> %s\n' "$*" >&2; }
die() {
  printf 'nanokvm-flash-sd: %s\n' "$*" >&2
  exit 1
}

image="$SD_IMAGE"
expected="$SD_RAW_SHA256"
backup=""
keys=""
assume_yes=0
disk=""
while [ $# -gt 0 ]; do
  case "$1" in
    --image) image="$2"; expected=""; shift 2 ;;
    --backup) backup="$2"; shift 2 ;;
    --authorized-keys) keys="$2"; shift 2 ;;
    --yes) assume_yes=1; shift ;;
    -h | --help) usage ;;
    -*) usage ;;
    *) [ -z "$disk" ] || usage; disk="$1"; shift ;;
  esac
done
[ -n "$disk" ] || usage
[ -n "$image" ] || die "this build carries no image of its own: pass --image FILE"
[ -r "$image" ] || die "cannot read $image"
[ -z "$keys" ] || [ -r "$keys" ] || die "cannot read $keys"

os="$(uname -s)"
# The device dd writes to, and a description for the confirmation.
case "$os" in
  Darwin)
    [[ "$disk" =~ ^/dev/r?disk[0-9]+$ ]] || die "$disk is not a whole disk (/dev/diskN)"
    name="${disk#/dev/}" && disk="/dev/${name#r}" # /dev/rdiskN -> /dev/diskN
    info="$(diskutil info "$disk")" || die "no such disk: $disk"
    grep -Eq 'Device Location: +External|Removable Media: +Removable' <<<"$info" ||
      die "$disk is an internal, fixed disk; refusing"
    ! grep -Eq 'Virtual: +Yes' <<<"$info" || die "$disk is a virtual disk; refusing"
    raw="/dev/r${disk#/dev/}"
    desc="$(sed -n 's/^ *Device \/ Media Name: *//p; s/^ *Disk Size: *\([^(]*\).*/\1/p' <<<"$info" | paste -sd' ' -)"
    ;;
  Linux)
    [ -b "$disk" ] || die "$disk is not a block device"
    name="$(basename "$(readlink -f "$disk")")"
    [ -e "/sys/block/$name" ] || die "$disk is a partition, not a whole disk"
    [ "$(cat "/sys/block/$name/removable")" = 1 ] || die "$disk is not removable; refusing"
    raw="$disk"
    desc="$(cat "/sys/block/$name/device/model" 2>/dev/null || true) $(($(cat "/sys/block/$name/size") / 2048)) MiB"
    ;;
  *) die "unsupported system: $os" ;;
esac

if [ "$assume_yes" = 0 ]; then
  printf 'Erase %s (%s) and write %s? [y/N] ' "$disk" "$desc" "$(basename "$image")" >&2
  read -r answer
  [ "$answer" = y ] || [ "$answer" = Y ] || die "aborted"
fi

as_root() {
  if [ -w "$raw" ]; then "$@"; else sudo "$@"; fi
}

unmount() {
  case "$os" in
    Darwin) diskutil unmountDisk force "$disk" >/dev/null ;;
    Linux)
      for part in "$disk"*; do
        if grep -q "^$part " /proc/mounts; then as_root umount "$part"; fi
      done
      ;;
  esac
}

unmount
if [ -n "$backup" ]; then
  say "saving $disk to $backup"
  as_root dd if="$raw" bs=4194304 status=none | zstd -T0 -3 -q -o "$backup" ||
    die "backup failed; nothing was written"
  unmount # macOS may remount after the read
fi

decompress() {
  case "$image" in
    *.zst) zstd -dc "$image" ;;
    *) cat "$image" ;;
  esac
}

say "writing $(basename "$image") to $disk"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Hash and count the stream while writing it, so a downloaded image is
# checked against exactly what went to the card.
decompress | tee >(sha256sum | cut -d' ' -f1 >"$tmp/sha") >(wc -c | tr -d ' ' >"$tmp/size") |
  as_root dd of="$raw" bs=4194304 status=none || die "write failed"
sync
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmp/sha" ] && [ -s "$tmp/size" ] && break; sleep 0.2; done
written="$(cat "$tmp/sha")"
size="$(cat "$tmp/size")"
[ -z "$expected" ] || [ "$written" = "$expected" ] ||
  die "the image is not the one this flake built ($written, expected $expected)"

say "reading back $size bytes"
unmount
blocks=$(((size + 4194303) / 4194304))
readback="$(as_root dd if="$raw" bs=4194304 count="$blocks" status=none | head -c "$size" | sha256sum | cut -d' ' -f1)"
[ "$readback" = "$written" ] || die "verification failed: the card reads back $readback, wrote $written"

if [ -n "$keys" ]; then
  # Into the FAT firmware partition, where the device reads root's keys.
  say "adding $keys to the card"
  unmount
  as_root env MTOOLS_SKIP_CHECK=1 mcopy -o -i "$disk@@$FIRMWARE_OFFSET" "$keys" ::authorized_keys ||
    die "could not write $keys to the card"
  sync
fi

[ "$os" = Darwin ] && diskutil eject "$disk" >/dev/null
say "done: $disk holds the image ($written); put the card in the NanoKVM"
