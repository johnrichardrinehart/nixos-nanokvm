# U-Boot's sandbox (a Linux executable) from the board's U-Boot source,
# configured like the board where the tests depend on it: the default (old)
# hush parser, and fastboot flashing to MMC device 0 with the whole-card
# `mmc0` target. Fastboot runs over UDP here; the board uses USB, which
# shares the command and flash code.
{
  lib,
  buildUBoot,
  ubootSrc,
  ubootVersion,
}:
(buildUBoot {
  src = ubootSrc;
  version = ubootVersion;
  defconfig = "sandbox_defconfig";
  extraMeta.platforms = lib.platforms.linux;
  filesToInstall = [
    "u-boot"
    "u-boot.dtb"
  ];
  extraMakeFlags = [ "NO_SDL=1" ];
  extraConfig = ''
    CONFIG_HUSH_OLD_PARSER=y
    # CONFIG_HUSH_MODERN_PARSER is not set
    # CONFIG_HUSH_SELECTABLE is not set
    # Capsule signing needs efitools; nothing here uses EFI.
    # CONFIG_EFI_CAPSULE_AUTHENTICATE is not set
    CONFIG_FASTBOOT=y
    CONFIG_UDP_FUNCTION_FASTBOOT=y
    CONFIG_FASTBOOT_BUF_ADDR=0x4000000
    CONFIG_FASTBOOT_BUF_SIZE=0x4000000
    CONFIG_FASTBOOT_FLASH=y
    CONFIG_FASTBOOT_FLASH_MMC=y
    CONFIG_FASTBOOT_FLASH_MMC_DEV=0
    CONFIG_FASTBOOT_MMC_USER_SUPPORT=y
    CONFIG_FASTBOOT_MMC_USER_NAME="mmc0"
    # Packets on lo carry unfinished (offloaded) checksums.
    # CONFIG_UDP_CHECKSUM is not set
    # As on the board: no U-Boot environment of its own, so `env export -c`
    # blocks have no redundancy flags byte (lib/boot-script.nix).
    CONFIG_ENV_IS_NOWHERE=y
    # CONFIG_ENV_IS_IN_FAT is not set
    # CONFIG_ENV_IS_IN_EXT4 is not set
    # CONFIG_ENV_IS_IN_SPI_FLASH is not set
    # CONFIG_ENV_REDUNDANT is not set
  '';
  postConfigure = ''
    make olddefconfig
    for line in CONFIG_HUSH_OLD_PARSER=y CONFIG_FASTBOOT_FLASH_MMC=y CONFIG_FASTBOOT_MMC_USER_SUPPORT=y CONFIG_UDP_FUNCTION_FASTBOOT=y CONFIG_ENV_IS_NOWHERE=y; do
      grep -Fxq "$line" .config || { echo "sandbox config lost $line" >&2; exit 1; }
    done
    if grep -Eq '^CONFIG_(ENV_REDUNDANT|ENV_IS_IN_[A-Z0-9_]+)=y' .config; then
      echo "sandbox keeps an environment, unlike the board:" >&2
      grep -E '^CONFIG_(ENV_REDUNDANT|ENV_IS_IN_[A-Z0-9_]+)=y' .config >&2
      exit 1
    fi
  '';
}).overrideAttrs
  (old: {
    # Sandbox RAM addresses must be mapped to host pointers; the board's
    # are used directly. Without this the first download segfaults.
    postPatch = (old.postPatch or "") + ''
      substituteInPlace drivers/fastboot/fb_common.c \
        --replace-fail '#include <net.h>' $'#include <net.h>\n#include <mapmem.h>' \
        --replace-fail '(void *)CONFIG_FASTBOOT_BUF_ADDR;' 'map_sysmem(CONFIG_FASTBOOT_BUF_ADDR, CONFIG_FASTBOOT_BUF_SIZE);'
    '';
  })
