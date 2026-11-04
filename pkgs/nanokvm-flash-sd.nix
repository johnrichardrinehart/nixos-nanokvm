{
  lib,
  stdenv,
  coreutils,
  gnused,
  mtools,
  runCommandCC,
  zstd,
  writeShellApplication,
  # Output of the SD image builder (sd-image/nanokvm-sd.img.zst,
  # raw-sha256), or null for a tool that only writes --image files.
  sdImage ? null,
  # Byte offset of the FAT firmware partition (lib/layout.nix).
  firmwareOffset,
}:
let
  # macOS: keeps Disk Arbitration from mounting the card during the write.
  holdDisk = runCommandCC "nanokvm-hold-disk" { } ''
    mkdir -p $out/bin
    $CC -O2 -Wall -Werror -o $out/bin/nanokvm-hold-disk ${./nanokvm-hold-disk.c} \
      -framework DiskArbitration -framework CoreFoundation
  '';
in
writeShellApplication {
  name = "nanokvm-flash-sd";
  runtimeInputs = [
    coreutils
    gnused
    mtools
    zstd
  ]
  ++ lib.optional stdenv.hostPlatform.isDarwin holdDisk;
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
