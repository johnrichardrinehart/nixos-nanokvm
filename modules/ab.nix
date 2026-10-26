# A/B slots for a mixos system on an MBR disk (see lib/layout.nix).
#
# A slot is a FAT image holding the kernel, the mixos initrd (which carries
# the whole system), the device tree and extlinux.conf. Linux never mounts
# it; U-Boot picks the slot. Persistent data lives on partition 4, mounted
# by mixos as /state.
{
  config,
  lib,
  pkgs,
  diskoLib,
  ...
}:
let
  cfg = config.nanokvm.ab;
  layout = import ../lib/layout.nix { inherit (cfg) slotSizeMiB disk; };
  dataDev = layout.partDevice layout.data.index;

  staticBins = pkgs.callPackage ../pkgs/static-bins.nix { };
  # Not named after the packages: `with pkgs.buildPackages; [ zstd ]` in the
  # image builders must not pick up these riscv64 binaries.
  zstdBins = staticBins "zstd" pkgs.zstd [ "zstd" ];
  btrfsBins = staticBins "btrfs-progs" pkgs.btrfs-progs [
    "btrfs"
    "mkfs.btrfs"
  ];
  utilLinux = staticBins "util-linux" pkgs.util-linux [
    "blkid"
    "wipefs"
    "sfdisk"
    "partx"
  ];

  # The card as disko sees it; built from the same layout as the SD image.
  sector = n: "${toString n}s";
  rawPartition = name: part: {
    inherit name;
    part-type = "primary";
    start = sector part.start;
    end = sector (part.start + part.size - 1);
  };
  diskoDevices =
    (lib.evalModules {
      modules = [
        {
          options.devices = lib.mkOption { type = diskoLib.toplevel; };
          # MBR (disko's legacy `table` type): the SG2002 BootROM finds
          # fip.bin only through MBR entries.
          config.devices.disk.card = {
            type = "disk";
            device = layout.disk;
            content = {
              type = "table";
              format = "msdos";
              partitions = [
                (rawPartition "firmware" layout.firmware // { bootable = true; })
                (rawPartition "slot-a" layout.slots.a)
                (rawPartition "slot-b" layout.slots.b)
                {
                  name = "data";
                  part-type = "primary";
                  start = sector layout.data.start;
                  end = "100%";
                  content.type = "btrfs";
                }
              ];
            };
          };
        }
      ];
    }).config.devices;
  dataContent =
    (lib.elemAt diskoDevices.disk.card.content.partitions (layout.data.index - 1)).content;

  # disko's create step for /data: formats only when no filesystem is found.
  formatData = pkgs.writeScript "nanokvm-format-data" ''
    #!${pkgs.bashNonInteractive}/bin/bash
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        utilLinux
        btrfsBins
      ]
    }:/bin
    ${dataContent._create}
  '';

  healthCheck = pkgs.writeScript "nanokvm-ab-health-check" ''
    #!/bin/sh
    ${cfg.healthCheck}
  '';

  tool = pkgs.writeScriptBin "nanokvm-ab" (
    ''
      #!/bin/sh
      export PATH=${
        lib.makeBinPath [
          cfg.envTools
          zstdBins
        ]
      }:/bin
      AB_DISK=${layout.disk}
      AB_SLOT_A_INDEX=${toString layout.slots.a.index}
      AB_SLOT_B_INDEX=${toString layout.slots.b.index}
      AB_ENV_OFFSETS="${lib.concatMapStringsSep " " toString layout.env.offsets}"
      AB_ENV_SIZE=${toString layout.env.size}
      AB_MAX_TRIES=${toString cfg.maxTries}
      AB_CONFIRM=${cfg.confirm}
      AB_TRIAL_TIMEOUT=${toString cfg.trialTimeoutSec}
      AB_HEALTH_CHECK=${healthCheck}
    ''
    + builtins.readFile ../pkgs/nanokvm-ab.sh
  );
  # Runs before /state is mounted, on every boot. disko has no grow and no
  # partition-scoped wipe, so those two steps are explicit; formatting is
  # disko's.
  stateInit = pkgs.writeScript "nanokvm-state-init" ''
    #!/bin/sh
    set -eu
    disk_sectors=$(cat /sys/class/block/${layout.diskName}/size)
    start=$(cat /sys/class/block/${layout.partName layout.data.index}/start)
    size=$(cat /sys/class/block/${layout.partName layout.data.index}/size)
    if [ $((start + size + 2048)) -lt "$disk_sectors" ]; then
      echo ", +" | ${utilLinux}/bin/sfdisk --no-reread --no-tell-kernel -N ${toString layout.data.index} ${layout.disk}
      ${utilLinux}/bin/partx --update --nr ${toString layout.data.index} ${layout.disk}
    fi
    if tr ' ' '\n' </proc/cmdline | grep -qx 'nanokvm.wipe=1'; then
      echo "nanokvm: wiping ${dataDev} as requested"
      ${utilLinux}/bin/wipefs -a -q ${dataDev}
    fi
    exec ${formatData}
  '';

  extlinuxConf = pkgs.writeText "extlinux.conf" ''
    DEFAULT nanokvm
    TIMEOUT 10
    LABEL nanokvm
      LINUX /Image
      INITRD /initrd
      FDT /sg2002.dtb
      APPEND ${lib.concatStringsSep " " cfg.kernelParams}
  '';

  bootFiles = pkgs.runCommand "nanokvm-boot-files" { } ''
    mkdir -p $out/extlinux
    cp ${config.system.build.toplevel}/kernel $out/Image
    cp ${config.system.build.toplevel}/initrd $out/initrd
    cp ${cfg.fdt} $out/sg2002.dtb
    cp ${extlinuxConf} $out/extlinux/extlinux.conf
  '';
  # FAT image sized to its contents plus headroom; U-Boot reads it.
  slotImage =
    pkgs.buildPackages.runCommand "nanokvm-slot.img"
      {
        nativeBuildInputs = with pkgs.buildPackages; [
          dosfstools
          mtools
        ];
      }
      ''
        kib=$(( $(du -sLk ${bootFiles} | cut -f1) + 16384 ))
        [ "$kib" -ge 40960 ] || kib=40960
        if [ "$kib" -gt ${toString (cfg.slotSizeMiB * 1024)} ]; then
          echo "boot files ($kib KiB) do not fit a ${toString cfg.slotSizeMiB} MiB slot" >&2
          exit 1
        fi
        mkfs.vfat -C -F 32 -n NANOKVM $out $kib
        mcopy -i $out -s -p ${bootFiles}/* ::
      '';

  # What deploys transfer: compressed slot image plus its hashes.
  slot =
    pkgs.buildPackages.runCommand "nanokvm-slot" { nativeBuildInputs = [ pkgs.buildPackages.zstd ]; }
      ''
        mkdir -p $out
        zstd -q -19 ${slotImage} -o $out/slot.img.zst
        sha256sum $out/slot.img.zst | cut -d' ' -f1 > $out/sha256
        sha256sum ${slotImage} | cut -d' ' -f1 > $out/raw-sha256
        stat -L -c %s ${slotImage} > $out/size
      '';

  sdImage =
    pkgs.buildPackages.runCommand "nanokvm-sd-image"
      {
        nativeBuildInputs = with pkgs.buildPackages; [
          dosfstools
          mtools
          util-linux
          zstd
        ];
      }
      ''
        img=nanokvm-sd.img
        truncate -s ${toString (layout.imageSectors * 512)} "$img"
        sfdisk --no-reread --no-tell-kernel "$img" < ${pkgs.buildPackages.writeText "nanokvm-layout.sfdisk" layout.sfdiskScript}

        # FAT16, as on Sipeed's BootROM-known-good images.
        truncate -s ${toString (layout.firmware.size * 512)} firmware.img
        mkfs.vfat -F 16 -n ${layout.firmware.label} firmware.img
        mcopy -i firmware.img ${cfg.fip}/fip.bin ::fip.bin
        dd if=firmware.img of="$img" bs=512 seek=${toString layout.firmware.start} conv=notrunc status=none

        dd if=${slotImage} of="$img" bs=512 seek=${toString layout.slots.a.start} conv=notrunc status=none

        mkdir -p "$out/sd-image"
        zstd -T"$NIX_BUILD_CORES" -q "$img" -o "$out/sd-image/nanokvm-sd.img.zst"
        sha256sum "$out/sd-image/nanokvm-sd.img.zst" | cut -d' ' -f1 > $out/sha256
        sha256sum "$img" | cut -d' ' -f1 > $out/raw-sha256
        stat -c %s "$img" > $out/size
      '';
in
{
  options.nanokvm.ab = {
    disk = lib.mkOption {
      type = lib.types.str;
      default = "/dev/mmcblk0";
      description = "Whole-disk device holding the A/B layout.";
    };

    slotSizeMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 256;
      description = "Size of each boot slot. Fixed when the card is first written.";
    };

    maxTries = lib.mkOption {
      type = lib.types.ints.between 1 9;
      default = 3;
      description = ''
        Trial boots of a newly deployed slot before U-Boot returns to the
        committed slot. Compiled into U-Boot: changing it requires reflashing.
      '';
    };

    maxUnconfirmedBoots = lib.mkOption {
      type = lib.types.ints.between 3 9;
      default = 6;
      description = ''
        Consecutive boots without a passing health check after which U-Boot
        enters USB fastboot recovery instead of booting again (a committed
        slot that panics or hangs would otherwise reboot forever). Must exceed
        maxTries + 1. Compiled into U-Boot: changing it requires reflashing.
      '';
    };

    confirm = lib.mkOption {
      type = lib.types.enum [
        "deployer"
        "device"
      ];
      default = "deployer";
      description = ''
        Who commits a trial slot: the deploy script once it can log in, or
        the device itself once its health check passes.
      '';
    };

    trialTimeoutSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "A trial boot that is not committed within this time reboots (and spends a try).";
    };

    healthCheck = lib.mkOption {
      type = lib.types.lines;
      default = "pidof dropbear >/dev/null";
      description = "Shell commands that succeed once the system is usable.";
    };

    envTools = lib.mkOption {
      type = lib.types.package;
      description = "Package providing fw_printenv and mkenvimage.";
    };

    kernelParams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Kernel command line written to each slot's extlinux.conf.";
    };

    fdt = lib.mkOption {
      type = lib.types.path;
      description = "Device tree blob booted from each slot.";
    };

    fip = lib.mkOption {
      type = lib.types.package;
      description = "Package containing fip.bin for the firmware partition.";
    };
  };

  config = {
    nanokvm.ab.kernelParams = [
      # Expanded by U-Boot when it reads extlinux.conf.
      "nanokvm.slot=\${ab_slot}"
      "nanokvm.trial=\${ab_trial}"
      "nanokvm.wipe=\${ab_wipe}"
      # A panicking trial reboots and spends a try instead of hanging.
      "panic=10"
    ];

    # Root keys can be dropped onto the FAT firmware partition from any
    # computer (modules/ssh.nix).
    nanokvm.keysPartition = layout.partDevice layout.firmware.index;

    packages = [
      tool
      cfg.envTools
    ];

    state = {
      enable = true;
      source = dataDev;
      fsType = "btrfs";
      options = [
        "noatime"
        "compress=zstd:3"
      ];
      init = stateInit;
    };

    init = {
      nanokvm-grow-state = {
        action = "once";
        process = "${btrfsBins}/bin/btrfs filesystem resize max /state";
      };
      nanokvm-ab-verify = {
        action = "once";
        process = "${tool}/bin/nanokvm-ab boot-verify";
      };
      nanokvm-ab-trial-deadline = {
        action = "once";
        process = "${tool}/bin/nanokvm-ab trial-deadline";
      };
    };

    system.build = {
      nanokvmAb = tool;
      inherit slot slotImage sdImage;
    };
  };
}
