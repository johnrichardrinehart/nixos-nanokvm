# nanokvm-deploy: write this flake's slot image to a NanoKVM's inactive slot,
# boot it on trial and commit it once it is reachable again.
#
# SLOT_IMAGE, SLOT_SHA256, SLOT_RAW_SHA256, SLOT_SIZE and MAX_TRIES come from
# the Nix wrapper. NANOKVM_DEPLOY_SSH replaces the ssh binary (tests).

usage() {
  cat >&2 <<EOF
usage: nanokvm-deploy [options] [user@]host

Writes the image to the inactive slot, reboots into it on trial and commits
it once SSH works. A trial that does not come up is retried, then U-Boot
returns to the previous slot.

options:
  --tries N        trial boots before rolling back (1..$MAX_TRIES, default $MAX_TRIES)
  --timeout SEC    how long to wait for the device after rebooting (default 900)
  --wipe-data      also reformat /data on the next boot
  --no-reboot      write and arm the slot, but do not reboot
  --force          deploy even if the device already runs this image
  -o OPTION        extra ssh option (repeatable)

image:  $SLOT_SHA256
EOF
  exit 2
}

say() { printf '==> %s\n' "$*" >&2; }
die() { printf 'nanokvm-deploy: %s\n' "$*" >&2; exit 1; }

tries="$MAX_TRIES"
timeout=900
wipe=0
reboot=1
force=0
host=""
ssh_opts=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=10
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)
while [ $# -gt 0 ]; do
  case "$1" in
    --tries) tries="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    --wipe-data) wipe=1; shift ;;
    --no-reboot) reboot=0; shift ;;
    --force) force=1; shift ;;
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
case "$tries" in
  [1-9]) [ "$tries" -le "$MAX_TRIES" ] || die "--tries must be 1..$MAX_TRIES" ;;
  *) die "--tries must be 1..$MAX_TRIES" ;;
esac

ssh_bin="${NANOKVM_DEPLOY_SSH:-ssh}"
remote() { "$ssh_bin" "${ssh_opts[@]}" "$host" "$@"; }
field() { sed -n "s/^$1=//p" <<<"$2"; }

status="$(remote nanokvm-ab status)" \
  || die "cannot run 'nanokvm-ab status' on $host; is it running this flake's image?"
booted="$(field booted "$status")"
case "$booted" in
  a | b) ;;
  *) die "$host did not report a booted slot" ;;
esac
if [ "$(field trial "$status")" = 1 ] && [ "$(field committed "$status")" = 0 ]; then
  die "slot $booted on $host is an unconfirmed trial. Commit it ('ssh $host nanokvm-ab commit') or roll it back ('ssh $host nanokvm-ab rollback') first."
fi
if [ "$(field image "$status")" = "$SLOT_SHA256" ] && [ "$force" = 0 ] && [ "$wipe" = 0 ]; then
  say "$host already runs image $SLOT_SHA256 (use --force to redeploy)"
  exit 0
fi
boot_id="$(field boot_id "$status")"
if [ "$booted" = a ]; then target=b; else target=a; fi

say "writing slot $target on $host ($(du -Lh "$SLOT_IMAGE" | cut -f1) compressed)"
write_args=(write --sha256 "$SLOT_SHA256" --raw-sha256 "$SLOT_RAW_SHA256" --size "$SLOT_SIZE")
if command -v pv >/dev/null && [ -t 2 ]; then
  pv "$SLOT_IMAGE" | remote nanokvm-ab "${write_args[@]}"
else
  remote nanokvm-ab "${write_args[@]}" <"$SLOT_IMAGE"
fi
remote nanokvm-ab arm --tries "$tries" >/dev/null
if [ "$wipe" = 1 ]; then
  remote nanokvm-ab request-wipe-data >/dev/null
fi
if [ "$reboot" = 0 ]; then
  say "slot $target is armed for $tries trial boot(s); reboot $host to try it, then run 'nanokvm-ab commit' there"
  exit 0
fi

say "rebooting $host into slot $target (trial, $tries tries)"
remote reboot || true

deadline=$((SECONDS + timeout))
while :; do
  sleep 5
  if status="$(remote nanokvm-ab status 2>/dev/null)" \
    && [ "$(field boot_id "$status")" != "$boot_id" ]; then
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    die "$host did not come back within ${timeout}s. It falls back to slot $booted by itself after $tries failed trial boots."
  fi
done

booted="$(field booted "$status")"
if [ "$booted" != "$target" ] || [ "$(field trial "$status")" != 1 ]; then
  say "$host came back on slot $booted, not the trial slot $target (failed=$(field failed "$status"))"
  exit 3
fi
image="$(field image "$status")"
if [ "$image" != "$SLOT_SHA256" ]; then
  remote nanokvm-ab rollback || true
  die "slot $target reports image $image instead of $SLOT_SHA256; rolling back"
fi

say "slot $target is up; committing"
if ! remote nanokvm-ab commit >/dev/null; then
  die "commit failed (health check?). The trial reboots by itself and returns to slot $booted when its tries run out."
fi
say "deployed image $SLOT_SHA256 to $host (slot $target)"
