{
  coreutils,
  gnused,
  openssh,
  zstd,
  writeShellApplication,
  # Output of the SD image builder: sd-image/nanokvm-sd.img.zst, sha256,
  # raw-sha256, size.
  sdImage,
  # Static executables run on the stock system, and its `uname -m`.
  deviceTools,
  deviceArch,
}:
writeShellApplication {
  name = "nanokvm-flash-from-stock";
  runtimeInputs = [
    coreutils
    gnused
    openssh
    zstd
  ];
  text = ''
    SD_IMAGE=${sdImage}/sd-image/nanokvm-sd.img.zst
    SD_SHA256="$(cat ${sdImage}/sha256)"
    SD_RAW_SHA256="$(cat ${sdImage}/raw-sha256)"
    SD_SIZE="$(cat ${sdImage}/size)"
    DEVICE_BUSYBOX=${deviceTools.busybox}
    DEVICE_ZSTD=${deviceTools.zstd}
    DEVICE_SCRIPT=${./nanokvm-flash-device.sh}
    DEVICE_ARCH=${deviceArch}
  ''
  + builtins.readFile ./nanokvm-flash-from-stock.sh;
}
