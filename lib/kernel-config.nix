# Kernel for the NanoKVM Lite/Full, applied on top of allnoconfig: the
# board's KVM hardware and nothing else, all built in (no modules).
# tests/kernel-config.nix fails the build if an enabled device-tree node has
# no built-in driver and is not listed there as unused.
{
  lib,
  # Package with lib/firmware/sophgo/sg2002/coda980.bin, or null to leave
  # out the Coda980 H.264 encoder (its firmware is a Sipeed binary).
  codaFirmware ? null,
}:
with lib.kernel;
{
  # Platform
  ARCH_SOPHGO = yes;
  MMU = yes;
  FPU = yes; # musl's lp64d userspace uses the FPU
  # The C906 marks page attributes in non-standard PTE bits (MAE) and its
  # DMA is not cache-coherent (CMO: MMC, Ethernet, USB). Without these the
  # kernel hangs once it enables the MMU. allnoconfig turns them off.
  ERRATA_THEAD = yes;
  ERRATA_THEAD_MAE = yes;
  ERRATA_THEAD_CMO = yes;
  RISCV_ISA_ZICBOM = yes;
  RISCV_ISA_SVPBMT = yes;
  # The C906 vector unit is pre-ratification (XTheadVector), not RVV 1.0.
  RISCV_ISA_V = no;
  RISCV_ISA_C = yes;
  RISCV_SBI = yes; # console, timer and system reset go through OpenSBI
  SERIAL_EARLYCON_RISCV_SBI = yes;
  KERNEL_UNCOMPRESSED = yes; # the slot carries the plain Image
  SIFIVE_PLIC = yes;
  COMMON_CLK = yes;
  CLK_SOPHGO_CV1800 = yes;
  PINCTRL = yes;
  PINCTRL_SOPHGO_SG2002 = yes;
  RESET_CONTROLLER = yes;
  RESET_SIMPLE = yes;
  MFD_SYSCON = yes;
  HW_RANDOM = yes;
  HW_RANDOM_SG2002 = yes; # entropy for dropbear's host key on first boot
  NVMEM = yes;
  NVMEM_LAYOUTS = yes;
  NVMEM_SG2002_EFUSE = yes;
  RTC_CLASS = yes;
  SOPHGO_CV1800_RTCSYS = yes;
  RTC_DRV_CV1800 = yes;
  THERMAL = yes;
  THERMAL_OF = yes;
  CV1800_THERMAL = yes;
  CPU_FREQ = yes;
  CPUFREQ_DT = yes;
  CPU_FREQ_GOV_ONDEMAND = yes; # schedutil needs SMP; the SG2002 has one core
  CPU_FREQ_DEFAULT_GOV_ONDEMAND = yes;

  # Console
  TTY = yes;
  SERIAL_8250 = yes;
  SERIAL_8250_CONSOLE = yes;
  SERIAL_8250_DW = yes;
  SERIAL_OF_PLATFORM = yes;
  UNIX98_PTYS = yes;
  PRINTK = yes;

  # Watchdog: never stopped once running; the kernel feeds a running
  # watchdog until userspace takes over.
  WATCHDOG = yes;
  WATCHDOG_NOWAYOUT = yes;
  WATCHDOG_HANDLE_BOOT_ENABLED = yes;
  DW_WATCHDOG = yes;

  # ATX power/reset buttons and LEDs (GPIO character device); the NanoKVM
  # tools also mux pads through /dev/mem (MMIO only).
  GPIOLIB = yes;
  GPIO_CDEV = yes;
  GPIO_DWAPB = yes;
  DEVMEM = yes;
  STRICT_DEVMEM = yes;

  # HDMI capture: LT6911 bridge on I2C (also driven from userspace via
  # /dev/i2c-*), CSI capture, VPSS scaler.
  I2C = yes;
  I2C_CHARDEV = yes;
  I2C_DESIGNWARE_CORE = yes;
  I2C_DESIGNWARE_PLATFORM = yes;
  MEDIA_SUPPORT = yes;
  MEDIA_SUPPORT_FILTER = yes;
  MEDIA_CAMERA_SUPPORT = yes;
  MEDIA_PLATFORM_SUPPORT = yes;
  MEDIA_CONTROLLER = yes;
  VIDEO_DEV = yes;
  VIDEO_V4L2_SUBDEV_API = yes;
  V4L_PLATFORM_DRIVERS = yes;
  V4L_MEM2MEM_DRIVERS = yes;
  VIDEO_LT6911UXE = yes;
  VIDEO_SOPHGO_SG2002_CSI = yes;
  VIDEO_SOPHGO_SG2002_VPSS = yes;
  # The LT6911 sits in "Video decoders", hidden while sub-drivers are
  # auto-selected.
  MEDIA_SUBDRV_AUTOSELECT = no;
  CMA = yes;
  DMA_CMA = yes;
  CMA_SIZE_MBYTES = freeform "24";

  # USB device: HID keyboard/mouse, virtual media, USB networking, serial
  USB_SUPPORT = yes;
  USB_GADGET = yes;
  USB_DWC2 = yes;
  USB_DWC2_PERIPHERAL = yes;
  PHY_SOPHGO_CV1800_USB2 = yes;
  CONFIGFS_FS = yes;
  USB_CONFIGFS = yes;
  USB_CONFIGFS_F_HID = yes;
  USB_CONFIGFS_MASS_STORAGE = yes;
  USB_CONFIGFS_ECM = yes;
  USB_CONFIGFS_NCM = yes;
  USB_CONFIGFS_RNDIS = yes;
  USB_CONFIGFS_ACM = yes;

  # OLED status display (Full): SSD1306 on bit-banged I2C
  I2C_GPIO = yes;
  BACKLIGHT_CLASS_DEVICE = yes;
  FB = yes;
  FB_DEVICE = yes;
  FB_SSD1307 = yes;

  # Storage: SD card, MBR, slots never mounted, /state on btrfs
  BLOCK = yes;
  MMC = yes;
  MMC_BLOCK = yes;
  MMC_SDHCI = yes;
  MMC_SDHCI_PLTFM = yes;
  MMC_SDHCI_OF_DWCMSHC = yes;
  PARTITION_ADVANCED = yes;
  MSDOS_PARTITION = yes;
  BTRFS_FS = yes;

  # mixos: system in an erofs image on a loop device from the initrd
  BLK_DEV_INITRD = yes;
  RD_XZ = yes;
  BLK_DEV = yes;
  BLK_DEV_LOOP = yes;
  MISC_FILESYSTEMS = yes;
  EROFS_FS = yes;
  EROFS_FS_ZIP = yes;
  EROFS_FS_ZIP_LZMA = yes;
  EROFS_FS_ZIP_ZSTD = yes;
  OVERLAY_FS = yes;
  DEVTMPFS = yes;
  TMPFS = yes;
  SHMEM = yes;
  MEMFD_CREATE = yes;
  PROC_FS = yes;
  SYSFS = yes;
  MULTIUSER = yes;
  FUTEX = yes;
  EPOLL = yes;
  EVENTFD = yes;
  SIGNALFD = yes;
  TIMERFD = yes;
  POSIX_TIMERS = yes;
  INOTIFY_USER = yes;
  FILE_LOCKING = yes;
  BINFMT_ELF = yes;
  BINFMT_SCRIPT = yes;

  # Network: wired Ethernet, DHCP, SSH
  NET = yes;
  UNIX = yes;
  INET = yes;
  IPV6 = yes;
  IPV6_SIT = no; # defaults to a module; no IPv6-in-IPv4 tunnels here
  PACKET = yes; # udhcpc
  NETDEVICES = yes;
  ETHERNET = yes;
  NET_VENDOR_STMICRO = yes;
  STMMAC_ETH = yes;
  STMMAC_PLATFORM = yes;
  DWMAC_SOPHGO = yes;
  PHYLIB = yes;
  MDIO_BUS_MUX_MMIOREG = yes;

  # nixpkgs' kernel install assumes a modular kernel. No module is built:
  # every option here is built in, and tests/kernel-config.nix rejects =m.
  MODULES = yes;
}
// lib.optionalAttrs (codaFirmware != null) {
  # Coda980 H.264 encoder. Built in, it probes before the root is mounted,
  # so its firmware is compiled into the kernel image.
  VIDEO_CODA = yes;
  FW_LOADER = yes;
  EXTRA_FIRMWARE = freeform "sophgo/sg2002/coda980.bin";
  EXTRA_FIRMWARE_DIR = freeform "${codaFirmware}/lib/firmware";
}
