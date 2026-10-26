# On-card layout shared by U-Boot, the SD image builder and the device tool.
#
#   sector 0          MBR
#   p1  1s..32768s    FAT16 firmware (fip.bin), active, type 0x0c. Never
#                     touched by deploys: the BootROM only reads fip.bin here.
#   20 MiB, 20 MiB+64 KiB
#                     A/B state: two copies of a U-Boot environment block
#                     (outside every partition; see lib/boot-script.nix)
#   p2  24 MiB        slot A, FAT (kernel, initrd, DTB, extlinux.conf)
#   p3                slot B, FAT
#   p4                /state, btrfs, grown to the end of the card on first boot
#
# MBR rather than GPT: the SG2002 ROM only finds fip.bin through MBR entries
# (upstream docs/sg2002-sd-boot-layout.md).
{
  slotSizeMiB,
  disk ? "/dev/mmcblk0",
}:
let
  sector = 512;
  mib = 1024 * 1024;
  toSectors = bytes: bytes / sector;
  # mmcblk0 -> mmcblk0p2, vdb -> vdb2
  partSuffix = if builtins.match ".*[0-9]" disk != null then "p" else "";
in
rec {
  inherit disk;
  diskName = baseNameOf disk;
  # U-Boot names the SD card mmc 0.
  ubootMmc = 0;

  firmware = {
    index = 1;
    start = 1;
    size = 32768;
    label = "FIRMWARE";
  };

  # Copy 1 is read first and written first.
  env = {
    offsets = [
      (20 * mib)
      (20 * mib + 64 * 1024)
    ];
    size = 64 * 1024;
  };

  slots = {
    a = {
      index = 2;
      start = toSectors (24 * mib);
      size = toSectors (slotSizeMiB * mib);
    };
    b = {
      index = 3;
      start = slots.a.start + slots.a.size;
      size = toSectors (slotSizeMiB * mib);
    };
  };

  data = {
    index = 4;
    start = slots.b.start + slots.b.size;
    # Large enough for mkfs.btrfs's default profile; grown to the end of
    # the card on first boot.
    initialSize = toSectors (256 * mib);
  };

  imageSectors = data.start + data.initialSize;

  # MBR as written to a fresh card. p1 stays the active partition: the ROM
  # loads fip.bin from it.
  sfdiskScript = ''
    label: dos
    unit: sectors
    sector-size: 512

    start=${toString firmware.start}, size=${toString firmware.size}, type=c, bootable
    start=${toString slots.a.start}, size=${toString slots.a.size}, type=83
    start=${toString slots.b.start}, size=${toString slots.b.size}, type=83
    start=${toString data.start}, size=${toString data.initialSize}, type=83
  '';

  partName = index: "${diskName}${partSuffix}${toString index}";

  # U-Boot commands naming fastboot targets for each slot (`slota`, `slotb`)
  # as raw block ranges, so flashing a slot image cannot reach the
  # firmware, environment or /state. `mmc0` (the whole card) is built in.
  fastbootSetup = builtins.concatStringsSep "; " (
    map (
      name:
      ''setenv fastboot_raw_partition_slot${name} "${toString slots.${name}.start} ${toString slots.${name}.size}"''
    ) (builtins.attrNames slots)
  );

  partDevice = index: "/dev/${partName index}";
}
