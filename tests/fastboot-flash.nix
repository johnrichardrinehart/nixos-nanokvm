# Recovery over fastboot, against U-Boot's sandbox with a file-backed SD
# card. The real `fastboot` client talks UDP on loopback (the board uses
# USB; both share U-Boot's command and flash code), after the same target
# setup the board's recovery command runs (lib/layout.nix fastbootSetup).
#
# Checks: a whole-card image larger than the download buffer (sent as
# sparse chunks) lands byte for byte on `mmc0`; `slota`/`slotb` write only
# their slot's blocks; an image larger than its slot is refused and writes
# nothing outside the slot. (U-Boot writes sparse chunks as they arrive, so
# the slot itself may be partly overwritten before the refusal.)
{
  lib,
  runCommand,
  sandbox,
  layout,
  android-tools,
  dtc,
  iproute2,
  util-linux,
}:
let
  sectors = n: toString n;
  slotA = layout.slots.a;
  slotB = layout.slots.b;
  cardBytes = toString ((layout.imageSectors + 2048 * 64) * 512);
  imageBytes = toString (layout.imageSectors * 512);
  uboot = lib.concatStringsSep "; " [
    "setenv ethrotate no"
    "setenv ethact host_lo"
    "setenv ipaddr 127.0.0.1"
    layout.fastbootSetup
    "fastboot udp"
  ];
in
runCommand "nanokvm-fastboot-flash"
  {
    nativeBuildInputs = [
      android-tools
      dtc
      iproute2
      util-linux
    ];
  }
  ''
    set -euo pipefail
    # The sandbox's SD card, backed by card.img, as mmc 0.
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
    truncate -s ${cardBytes} card.img

    # A whole-card image with the board's MBR and distinct data in every
    # region: zeros elsewhere, so the client sends it as sparse chunks.
    truncate -s ${imageBytes} whole.img
    sfdisk --no-reread --no-tell-kernel whole.img >/dev/null <<'EOF'
    ${layout.sfdiskScript}
    EOF
    mark() { head -c 4M /dev/urandom | dd of=whole.img bs=512 seek="$1" conv=notrunc status=none; }
    mark ${sectors layout.firmware.start}
    mark ${sectors slotA.start}
    mark $(( ${sectors slotA.start} + ${sectors slotA.size} - 8192 ))
    mark ${sectors slotB.start}
    mark ${sectors layout.data.start}
    head -c 40M /dev/urandom > slot.img
    # One byte at the start and one just past the end of slot A: where slot
    # B begins, if anything could write beyond the slot.
    head -c $(( ${sectors slotA.size} * 512 + 4096 )) /dev/zero > oversized.img
    echo x | dd of=oversized.img bs=1 seek=100 conv=notrunc status=none
    echo x | dd of=oversized.img bs=1 seek=$(( ${sectors slotA.size} * 512 + 100 )) conv=notrunc status=none

    region() { dd if="$1" bs=512 skip="$2" count="$3" status=none; }
    cat > uboot.cmd <<'EOF'
    ${uboot}
    EOF

    # Raw sockets on lo need CAP_NET_RAW: a user and network namespace.
    unshare -rn bash -euo pipefail -c '
      ip link set lo up
      ${sandbox}/u-boot -d sandbox.dtb -c "$(cat uboot.cmd)" > uboot.log 2>&1 &
      for i in $(seq 50); do grep -q "Listening for fastboot" uboot.log && break; sleep 0.2; done
      fb() { timeout 600 fastboot -s udp:127.0.0.1 "$@"; }

      fb getvar partition-size:slota 2>&1 | grep -Fx "partition-size:slota: 0x$(printf %016x $(( ${sectors slotA.size} * 512 )))" \
        || { echo "slota has the wrong size"; exit 1; }
      fb getvar max-download-size 2>&1 | grep -q "0x04000000"

      fb flash mmc0 whole.img
      fb flash slotb slot.img
      if fb flash slota oversized.img; then echo "an oversized slot image was accepted"; exit 1; fi
      kill %1
    ' || { echo "--- U-Boot"; tr -d '\r' < uboot.log | grep -v "wrong checksum" | tail -40; exit 1; }

    # The card is whole.img, except slot B (slot.img, then untouched by the
    # refused write) and slot A (whatever the refused write reached).
    cmp <(region card.img 0 ${sectors slotA.start}) <(region whole.img 0 ${sectors slotA.start})
    cmp <(region card.img ${sectors slotB.start} 81920) slot.img
    cmp <(region card.img $(( ${sectors slotB.start} + 81920 )) $(( ${sectors slotB.size} - 81920 ))) \
        <(region whole.img $(( ${sectors slotB.start} + 81920 )) $(( ${sectors slotB.size} - 81920 )))
    cmp <(region card.img ${sectors layout.data.start} ${sectors layout.data.initialSize}) \
        <(region whole.img ${sectors layout.data.start} ${sectors layout.data.initialSize})
    cmp <(tail -c +$(( ${imageBytes} + 1 )) card.img) <(head -c $(( ${cardBytes} - ${imageBytes} )) /dev/zero)
    touch $out
  ''
