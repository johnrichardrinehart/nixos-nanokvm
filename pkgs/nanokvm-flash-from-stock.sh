# nanokvm-flash-from-stock: replace Sipeed's stock firmware on a NanoKVM
# with this flake's SD image over SSH, without opening the case.
#
# SD_IMAGE, SD_SHA256, SD_RAW_SHA256, SD_SIZE, DEVICE_BUSYBOX, DEVICE_ZSTD,
# DEVICE_SCRIPT and DEVICE_ARCH come from the Nix wrapper.
# NANOKVM_FLASH_DISK replaces /dev/mmcblk0 (tests).

usage() {
  cat >&2 <<EOF
usage: nanokvm-flash-from-stock [options] [user@]host

Checks that host runs Sipeed's stock firmware on the cube's beta carrier,
saves the stock system (MBR, boot and root partitions) to a local file,
then writes this flake's SD image to the card from RAM, verifies it and
reboots into it. Erases the whole card, including the USB-drive partition.

options:
  --backup FILE    where to save the stock system
                   (default ./nanokvm-stock-<host>-<UTC time>.img.zst)
  --no-backup      do not save the stock system
  --yes            do not ask for confirmation
  --no-wait        do not wait for the new system to come up
  --timeout SEC    how long to wait for the new system (default 600)
  -o OPTION        extra ssh option (repeatable)

image:  $SD_SHA256
EOF
  exit 2
}

say() { printf '==> %s\n' "$*" >&2; }
die() {
  printf 'nanokvm-flash-from-stock: %s\n' "$*" >&2
  exit 1
}

backup=""
do_backup=1
assume_yes=0
wait_new=1
timeout=600
host=""
tmp="$(mktemp -d)"
# The control connection is gone once the device reboots; that is fine.
trap 'ssh -O exit -o ControlPath="$tmp/cm" "$host" 2>/dev/null || true; rm -rf "$tmp"' EXIT
# One connection (and one password prompt) for every step.
ssh_opts=(
  -o ControlMaster=auto
  -o ControlPath="$tmp/cm"
  -o ControlPersist=600
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=10
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=6
)
while [ $# -gt 0 ]; do
  case "$1" in
    --backup) backup="$2"; shift 2 ;;
    --no-backup) do_backup=0; shift ;;
    --yes) assume_yes=1; shift ;;
    --no-wait) wait_new=0; shift ;;
    --timeout) timeout="$2"; shift 2 ;;
    -o) ssh_opts+=(-o "$2"); shift 2 ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      [ -z "$host" ] || usage
      host="$1"
      shift
      ;;
  esac
done
[ -n "$host" ] || usage
disk="${NANOKVM_FLASH_DISK:-/dev/mmcblk0}"
case "$disk" in
  *[0-9]) psep=p ;;
  *) psep="" ;;
esac
# Staging area on the device: a tmpfs, so nothing staged lives on the card.
stage=/tmp/nanokvm-flash

# Remote commands are built here on purpose: paths and hashes are local.
# shellcheck disable=SC2029
remote() { ssh "${ssh_opts[@]}" "$host" "$@"; }
field() { sed -n "s/^$1=//p" <<<"$2"; }

say "connecting to $host"
facts="$(
  remote sh -s -- "$disk" "$psep" <<'EOF'
disk=$1
psep=$2
name=${disk##*/}
echo "arch=$(uname -m)"
echo "hw=$(cat /etc/kvm/hw 2>/dev/null)"
echo "ab=$(command -v nanokvm-ab >/dev/null 2>&1 && echo yes || echo no)"
echo "disk_sectors=$(cat /sys/class/block/$name/size 2>/dev/null)"
for i in 1 2 3 4; do
  p=/sys/class/block/$name$psep$i
  [ -e "$p/start" ] && echo "part$i=$(cat $p/start) $(cat $p/size)"
done
echo "mem_kb=$(sed -n 's/^MemAvailable: *\([0-9]*\).*/\1/p' /proc/meminfo)"
EOF
)" || die "cannot run commands on $host over ssh"

[ "$(field ab "$facts")" = no ] \
  || die "$host already runs this OS (nanokvm-ab exists); deploy with 'nix run .#deploy' instead"
arch="$(field arch "$facts")"
[ "$arch" = "$DEVICE_ARCH" ] || die "$host is $arch, not $DEVICE_ARCH"
hw="$(field hw "$facts")"
case "$hw" in
  beta) ;;
  "") die "$host has no /etc/kvm/hw; is it running Sipeed's stock NanoKVM firmware?" ;;
  *) die "$host reports carrier '$hw'; this image supports only the cube's beta carrier" ;;
esac
disk_sectors="$(field disk_sectors "$facts")"
[ -n "$disk_sectors" ] || die "$host has no $disk"
[ $((disk_sectors * 512)) -ge "$SD_SIZE" ] \
  || die "$disk on $host ($((disk_sectors / 2048)) MiB) is smaller than the image ($((SD_SIZE / 1048576)) MiB)"
mem_kb="$(field mem_kb "$facts")"
need_kb=$((($(stat -L -c %s "$SD_IMAGE") + $(stat -L -c %s "$DEVICE_BUSYBOX") + $(stat -L -c %s "$DEVICE_ZSTD")) / 1024 + 32768))
[ "${mem_kb:-0}" -ge "$need_kb" ] \
  || die "$host has ${mem_kb:-?} KiB of available memory; staging needs $need_kb KiB"

# The stock layout: p1 boot (FAT), p2 root (ext4), p3 the USB-drive data
# partition. The backup covers everything up to the end of p2.
part2="$(field part2 "$facts")"
[ -n "$part2" ] || die "$disk on $host has no second partition; not a stock layout"
backup_mib=$(((${part2% *} + ${part2#* } + 2047) / 2048))
if [ "$do_backup" = 1 ]; then
  [ -n "$backup" ] || backup="./nanokvm-stock-${host#*@}-$(date -u +%Y%m%dT%H%M%SZ).img.zst"
  [ ! -e "$backup" ] || die "$backup already exists"
fi

cat >&2 <<EOF

  host:     $host (stock firmware, carrier $hw, $arch)
  card:     $disk, $((disk_sectors / 2048)) MiB
$(sed -n 's/^part\([0-9]\)=\(.*\) \(.*\)$/  p\1:       start \2, \3 sectors/p' <<<"$facts")
  backup:   $([ "$do_backup" = 1 ] && echo "$backup (MBR, p1 and p2: $backup_mib MiB before compression)" || echo none)
  image:    $SD_IMAGE ($((SD_SIZE / 1048576)) MiB)

This stops the stock services, freezes the card read-only, and replaces
everything on it, including the USB-drive partition (p3), which is not
backed up.

EOF
if [ "$assume_yes" = 0 ]; then
  read -r -p "Erase $disk on $host? Type 'yes': " answer </dev/tty
  [ "$answer" = yes ] || die "aborted"
fi

say "staging tools and image in RAM ($stage)"
remote "mkdir -p $stage && { grep -q ' $stage tmpfs ' /proc/mounts || mount -t tmpfs -o size=$((need_kb + 16384))k nanokvm-flash $stage; }" \
  || die "cannot mount a tmpfs at $stage on $host"
upload() { remote "cat > $stage/$2 && chmod $3 $stage/$2" <"$1" || die "uploading $2 failed"; }
upload "$DEVICE_BUSYBOX" busybox 755
upload "$DEVICE_ZSTD" zstd 755
upload "$DEVICE_SCRIPT" flash.sh 644
upload "$SD_IMAGE" image.img.zst 644
staged="$(remote "$stage/busybox sha256sum $stage/image.img.zst")" || die "cannot hash the staged image"
[ "${staged%% *}" = "$SD_SHA256" ] || die "staged image is corrupt (sha256 ${staged%% *})"

say "stopping stock services and freezing $disk read-only"
remote "$stage/busybox sh $stage/flash.sh quiesce $disk" >&2 \
  || die "could not freeze $disk; nothing was written. Reboot $host to restore the stock system."

if [ "$do_backup" = 1 ]; then
  say "saving the stock system to $backup"
  remote "$stage/busybox dd if=$disk bs=1M count=$backup_mib 2>/dev/null | $stage/zstd -1 -c" >"$backup.part" \
    || die "backup failed; nothing was written. Reboot $host to restore the stock system."
  got_bytes="$(zstd -dc "$backup.part" | wc -c)" || die "backup is corrupt; nothing was written. Reboot $host to restore the stock system."
  got_sha="$(zstd -dc "$backup.part" | sha256sum | cut -d' ' -f1)"
  [ "$got_bytes" = $((backup_mib * 1048576)) ] \
    || die "backup holds $got_bytes bytes, expected $((backup_mib * 1048576)); nothing was written. Reboot $host to restore the stock system."
  mv "$backup.part" "$backup"
  {
    echo "host=$host"
    echo "disk=$disk"
    echo "bytes=$got_bytes"
    echo "raw-sha256=$got_sha"
    grep '^part[0-9]=' <<<"$facts"
  } >"$backup.txt"
  say "saved $backup ($(du -h "$backup" | cut -f1)); restore with fastboot: see README"
fi

say "writing the image (the device verifies it, then reboots)"
# One session: the stock shell and sshd are never needed again, and the
# write carries on (nohup) if this connection drops.
set +e
remote "$stage/busybox sh -c '
  b=$stage/busybox
  \$b nohup \$b sh $stage/flash.sh write $disk $stage/image.img.zst $SD_RAW_SHA256 $SD_SIZE >$stage/log 2>&1 &
  pid=\$!
  \$b tail -f $stage/log & tail=\$!
  wait \$pid; status=\$?
  \$b sleep 1; kill \$tail
  exit \$status
'" 2>&1 | tee "$tmp/write.log" >&2
set -e
grep -q '^nanokvm-flash: rebooting$' "$tmp/write.log" \
  || die "the device did not report a verified write. Its stock system is still running read-only; check the output above and retry or reboot it."

if [ "$wait_new" = 0 ]; then
  say "done; $host is rebooting into the new system"
  exit 0
fi
target="root@${host#*@}"
say "waiting up to ${timeout}s for $target"
deadline=$(($(date +%s) + timeout))
# The new system has new host keys; check it without touching known_hosts.
new_opts=(
  -o BatchMode=yes
  -o UserKnownHostsFile="$tmp/known_hosts"
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=5
)
sleep 15
until status="$(ssh "${new_opts[@]}" "$target" nanokvm-ab status 2>/dev/null)"; do
  [ "$(date +%s)" -lt "$deadline" ] || die "$target did not come up within ${timeout}s. If it is not on the network, it enters USB fastboot recovery after repeated failed boots: see README."
  sleep 5
done
printf '%s\n' "$status"
say "$target runs the new system. Its host key changed: ssh-keygen -R ${host#*@}"
