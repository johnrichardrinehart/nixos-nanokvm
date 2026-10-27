# Bare-metal firmware for the SG2002's 700 MHz C906L: JPEG compression of
# frame bands for nanokvm-kvm (protocol.h). Built with the
# riscv64-none-elf toolchain, medany at 0x8f800000, with its own libc
# subset (no newlib: it is built medlow and cannot be linked up there).
{
  lib,
  stdenvNoCC,
  buildPackages,
  libjpeg_original,
}:
let
  cross = buildPackages.pkgsCross.riscv64-embedded.stdenv.cc;
  cc = "${cross}/bin/${cross.targetPrefix}gcc";
  # IJG libjpeg's encoder (arithmetic coding included: jmorecfg.h enables it).
  jpegSources = [
    "jaricom"
    "jcapimin"
    "jcapistd"
    "jcarith"
    "jccoefct"
    "jccolor"
    "jcdctmgr"
    "jchuff"
    "jcinit"
    "jcmainct"
    "jcmarker"
    "jcmaster"
    "jcomapi"
    "jcparam"
    "jcprepct"
    "jcsample"
    "jfdctflt"
    "jfdctfst"
    "jfdctint"
    "jmemmgr"
    "jmemnobs"
    "jutils"
  ];
in
stdenvNoCC.mkDerivation {
  pname = "nanokvm-c906l-firmware";
  version = "0.1";
  src = ./.;
  nativeBuildInputs = [ cross ];
  buildPhase = ''
    runHook preBuild
    mkdir jpeg
    tar -xzf ${libjpeg_original.src} -C jpeg --strip-components=1
    cp jconfig.h jpeg/jconfig.h
    # libc.c defines memcpy and friends: GCC must not turn its loops back
    # into calls to them.
    flags="-O2 -mcpu=thead-c906 -mabi=lp64d -mcmodel=medany \
      -ffreestanding -fno-pic -fno-common \
      -ffunction-sections -fdata-sections -Wall -I. -Ijpeg"
    objs=""
    for f in ${lib.concatStringsSep " " jpegSources}; do
      ${cc} $flags -w -c jpeg/$f.c -o jpeg-$f.o
      objs="$objs jpeg-$f.o"
    done
    for f in main jpeg; do ${cc} $flags -Werror -c $f.c -o $f.o; done
    ${cc} $flags -fno-builtin -fno-tree-loop-distribute-patterns -Werror -c libc.c -o libc.o
    ${cc} $flags -c start.S -o start.o
    ${cc} $flags -nostdlib -nostartfiles -Wl,--gc-sections -T link.ld \
      -o firmware.elf start.o main.o jpeg.o libc.o $objs
    # Everything must resolve inside the firmware: no libc, no libgcc.
    undefined=$(${cross}/bin/${cross.targetPrefix}nm -u firmware.elf)
    if [ -n "$undefined" ]; then echo "undefined symbols: $undefined" >&2; exit 1; fi
    ${cross}/bin/${cross.targetPrefix}objcopy -O binary firmware.elf firmware.bin
    size=$(stat -c %s firmware.bin)
    [ "$size" -lt 917504 ] || { echo "firmware is $size bytes: too large" >&2; exit 1; }
    runHook postBuild
  '';
  installPhase = ''
    install -Dm644 firmware.bin $out/firmware.bin
    install -Dm644 firmware.elf $out/firmware.elf
  '';
}
