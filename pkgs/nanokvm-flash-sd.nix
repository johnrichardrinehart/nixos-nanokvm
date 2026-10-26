{
  lib,
  coreutils,
  gnused,
  mtools,
  zstd,
  writeShellApplication,
  # Output of the SD image builder (sd-image/nanokvm-sd.img.zst,
  # raw-sha256), or null for a tool that only writes --image files.
  sdImage ? null,
  # Byte offset of the FAT firmware partition (lib/layout.nix).
  firmwareOffset,
}:
writeShellApplication {
  name = "nanokvm-flash-sd";
  runtimeInputs = [
    coreutils
    gnused
    mtools
    zstd
  ];
  text = ''
    ${
      if sdImage == null then
        ''
          SD_IMAGE=""
          SD_RAW_SHA256=""
        ''
      else
        ''
          SD_IMAGE=${sdImage}/sd-image/nanokvm-sd.img.zst
          SD_RAW_SHA256="$(cat ${sdImage}/raw-sha256)"
        ''
    }
    FIRMWARE_OFFSET=${toString firmwareOffset}
  ''
  + builtins.readFile ./nanokvm-flash-sd.sh;
  meta.description = "Write the NanoKVM SD image to a card${
    lib.optionalString (sdImage == null) " (--image only)"
  }";
}
