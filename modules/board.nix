# Sipeed NanoKVM Lite/Full (SG2002, "cube" carrier) on mixos.
#
# `boardPkgs` is the riscv64 glibc package set with nixos-nanokvm's overlay
# (kernel, DTB, FIP, U-Boot); userspace comes from its pkgsStatic.
{
  config,
  lib,
  pkgs,
  boardPkgs,
  ...
}:
let
  cfg = config.nanokvm;
  ab = config.nanokvm.ab;
  layout = import ../lib/layout.nix { inherit (ab) slotSizeMiB disk; };
  hex = n: "0x${lib.toLower (lib.toHexString n)}";

  bootScript = import ../lib/boot-script.nix { inherit lib; } {
    inherit (ab) maxTries maxUnconfirmedBoots;
    inherit (layout) env;
    inherit armWatchdog;
    fallback = recovery;
  };

  # The SG2002's DesignWare watchdog (WDT0), armed by register writes:
  # U-Boot's DESIGNWARE_WATCHDOG driver hangs U-Boot during startup on
  # this board. TORR 0xff selects the largest timeout, 2^31 cycles of the
  # 25 MHz clock (~86 s); CRR 0x76 restarts the count. Once enabled it
  # cannot be stopped, so the script arms it only before loading a slot.
  # Linux's dw_wdt driver finds it running and feeds it until userspace
  # opens it (watchdog.open_timeout).
  armWatchdog = "mw.l 0x03010004 0xff; mw.l 0x0301000c 0x76; mw.l 0x03010000 1";

  # USB fastboot on the HID USB-C port: whole card as `mmc0`, slots as
  # `slota`/`slotb` (lib/layout.nix).
  recovery = "${layout.fastbootSetup}; fastboot usb 0";

  ubootConfig = ''
    # The boot script keeps the A/B state itself (lib/boot-script.nix):
    # an on-card environment (ENV_IS_IN_MMC) hangs U-Boot during startup.
    CONFIG_ENV_IS_NOWHERE=y
    CONFIG_CMD_MMC=y
    CONFIG_CMD_EXPORTENV=y
    CONFIG_CMD_IMPORTENV=y
    # Watchdog: armed by the boot script, no U-Boot driver (see above).
    CONFIG_CMD_MEMORY=y
    # Let fastboot (recovery, see lib/boot-script.nix) write the card.
    CONFIG_FASTBOOT_FLASH=y
    CONFIG_FASTBOOT_FLASH_MMC=y
    CONFIG_FASTBOOT_FLASH_MMC_DEV=${toString layout.ubootMmc}
    CONFIG_FASTBOOT_MMC_USER_SUPPORT=y
    CONFIG_FASTBOOT_MMC_USER_NAME="mmc0"
  '';
  requiredUbootLines = lib.filter (line: line != "" && !lib.hasPrefix "#" line) (
    lib.splitString "\n" ubootConfig
  );

  uboot =
    (boardPkgs.sg2002-uboot-mainline.override {
      bootCommand = lib.escape [ "\\" "\"" ] bootScript;
    }).overrideAttrs
      (old: {
        extraConfig = old.extraConfig + ubootConfig;
        # Fail the build if Kconfig renames or drops any of these settings.
        postConfigure = old.postConfigure + ''
          for line in ${lib.escapeShellArgs requiredUbootLines}; do
            if ! grep -Fxq "$line" .config; then
              echo "nanokvm: U-Boot config lost '$line'" >&2
              exit 1
            fi
          done
          # No on-card environment, and no redundancy flags byte in
          # `env export -c` blocks (mkenvimage/fw_printenv use none).
          if grep -Eq '^CONFIG_(ENV_REDUNDANT|ENV_IS_IN_[A-Z0-9_]+)=y' .config; then
            echo "nanokvm: U-Boot must not keep an environment of its own:" >&2
            grep -E '^CONFIG_(ENV_REDUNDANT|ENV_IS_IN_[A-Z0-9_]+)=y' .config >&2
            exit 1
          fi
          if grep -Eq '^CONFIG_(WDT|DESIGNWARE_WATCHDOG)=y' .config; then
            echo "nanokvm: U-Boot's watchdog driver hangs this board; the boot script arms it" >&2
            exit 1
          fi
        '';
      });

  # nixos-nanokvm's SG2002 kernel (its patch set) with a minimal config:
  # allnoconfig plus lib/kernel-config.nix, everything built in. Every
  # requested option must survive Kconfig (ignoreConfigErrors = false).
  kernel =
    (boardPkgs.sg2002-kernel-mainline.override {
      linux_7_2 = lib.makeOverridable (
        args:
        boardPkgs.linux_7_2.override (
          args
          // {
            defconfig = "allnoconfig";
            structuredExtraConfig = import ../lib/kernel-config.nix {
              inherit lib;
              codaFirmware = if cfg.h264Encoder.enable then boardPkgs.sg2002-coda980-firmware else null;
            };
            ignoreConfigErrors = false;
          }
        )
      ) { };
    }).overrideAttrs
      (
        old:
        let
          # nixpkgs runs `rm` on the per-module certificates without
          # `xargs -r`; with every driver built in there are none, and a
          # bare `rm` fails the build. Drop this once nixpkgs adds -r.
          broken = "sed 's/$/\\.cer/' modules.order | xargs -d'\\n' rm";
        in
        {
          postInstall =
            lib.throwIfNot (lib.hasInfix broken old.postInstall)
              "modules/board.nix: nixpkgs no longer runs '${broken}'; drop the kernel postInstall workaround"
              (
                builtins.replaceStrings
                  [ broken ]
                  [
                    "sed 's/$/\\.cer/' modules.order | xargs -r -d'\\n' rm"
                  ]
                  old.postInstall
              );
        }
      );

  # OpenSBI must fit the firmware region below the device tree the FSBL
  # places right after it; Linux keeps the same region reserved
  # (riscv.fwsz). Its linker script puts the writable data at the next
  # power of two after the read-only part (one PMP entry each), so the
  # generic build of 1.9, whose read-only part is just over 256 KiB, is
  # 540 KB and hangs the board before U-Boot. Building only the drivers
  # this device tree uses (pkgs/opensbi-sg2002.defconfig) keeps it under
  # 256 KiB; the size check guards the rest.
  firmwareRegion = 512 * 1024;
  opensbi =
    let
      fw = (boardPkgs.sg2002-opensbi-mainline-for uboot).overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          cp ${../pkgs/opensbi-sg2002.defconfig} platform/generic/configs/sg2002_defconfig
        '';
        makeFlags = old.makeFlags ++ [ "PLATFORM_DEFCONFIG=sg2002_defconfig" ];
      });
    in
    pkgs.buildPackages.runCommand "${fw.name}-size-checked" { } ''
      bin=${fw}/share/opensbi/lp64/generic/firmware/fw_dynamic.bin
      size=$(stat -c %s "$bin")
      if [ "$size" -gt ${toString firmwareRegion} ]; then
        echo "nanokvm: OpenSBI ${fw.version} fw_dynamic.bin is $size bytes, more than the ${toString firmwareRegion}-byte firmware region" >&2
        exit 1
      fi
      ln -s ${fw} $out
    '';

  fip = boardPkgs.sg2002-fip-mainline-uboot.override {
    sg2002-uboot-mainline = uboot;
    sg2002-opensbi-mainline = opensbi;
  };

  udhcpcScript = pkgs.writeScript "udhcpc-event" ''
    #!/bin/sh
    case "$1" in
      deconfig)
        ip -4 addr flush dev "$interface"
        ;;
      bound | renew)
        ip -4 addr flush dev "$interface"
        ip -4 addr add "$ip/''${mask:-24}" dev "$interface"
        ip -4 route flush dev "$interface"
        for gw in $router; do ip -4 route add default via "$gw" dev "$interface"; done
        : > /etc/resolv.conf
        for ns in $dns; do echo "nameserver $ns" >> /etc/resolv.conf; done
        ;;
    esac
  '';
in
{
  options.nanokvm = {
    hostName = lib.mkOption {
      type = lib.types.str;
      default = "nanokvm";
    };

    h264Encoder.enable = lib.mkEnableOption ''
      the Coda980 H.264 encoder. Builds Sipeed's proprietary encoder
      firmware (extracted from their factory image) into the kernel
    '';
  };

  config = {
    nixpkgs.pkgs = boardPkgs.pkgsStatic;
    boot.kernelPackages = boardPkgs.linuxPackagesFor kernel;
    # Below the SG2002 watchdog's ~86 s hardware maximum.
    boot.watchdog.timeout = 60;

    system.build.kernel = kernel;

    nanokvm.ab = {
      envTools = pkgs.callPackage ../pkgs/uboot-env-tools.nix {
        inherit (uboot) src version;
      };
      fdt = boardPkgs.sg2002-dtb-mainline-cube;
      inherit fip;
      kernelParams = [
        "console=ttyS0,115200"
        "earlycon=sbi"
        # Keep the OpenSBI firmware region reserved.
        "riscv.fwsz=${hex firmwareRegion}"
        # The boot script arms the watchdog; the kernel feeds it until
        # userspace opens it, and nothing may stop it on the way to a reset.
        "watchdog.stop_on_reboot=0"
        "watchdog.open_timeout=120"
        "loglevel=4"
      ];
    };

    etc.hostname.source = pkgs.writeText "hostname" "${cfg.hostName}\n";

    services.dhcp.run = pkgs.writeScript "dhcp-run" ''
      #!/bin/sh
      ip link set eth0 up
      exec udhcpc -f -i eth0 -s ${udhcpcScript}
    '';

    system.build = {
      inherit fip uboot;
    };
  };
}
