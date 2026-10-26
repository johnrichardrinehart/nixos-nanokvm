# The SG2002 first-stage bootloader (FSBL: TF-A-style BL2 with DDR init),
# built from Sipeed's source for the LicheeRV Nano / NanoKVM
# (`sg2002_licheervnano_sd`: DDR3-1866 x16, 256 MiB) with mainline
# bare-metal GCC, and packed into a fip.bin the way Sipeed's `fip` target
# does, minus OpenSBI/U-Boot: nixos-nanokvm's FIP builder takes the FSBL
# and DDR parameters from it and adds mainline OpenSBI and U-Boot.
#
# DDR init is C code selected by DDR_CFG. The DDR_PARAM block in the FIP is
# Sipeed's test/cv181x/ddr_param.bin: BL2 loads it and checks its CRC but
# configures the DDR from the compiled-in tables.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  buildPackages,
}:
let
  cross = buildPackages.pkgsCross.riscv64-embedded.stdenv.cc;
  board = "build/boards/sg200x/sg2002_licheervnano_sd";
in
stdenvNoCC.mkDerivation {
  pname = "sg2002-fsbl";
  version = "20260114";

  # Sipeed's release tag 20260114 (also tagged 20260407).
  src = fetchFromGitHub {
    owner = "sipeed";
    repo = "LicheeRV-Nano-Build";
    rev = "d4003f15b35d43ad4842f427050ab2bba0114fa5";
    sparseCheckout = [
      "fsbl"
      board
      "build/scripts"
      "build/boards/default"
    ];
    hash = "sha256-XF9AzkPjbiLPgY1FNgMyXRHsx1vG+oqbQx1Ddk/ohos=";
  };

  patches = [ ../../patches/fsbl-mainline-toolchain.patch ];

  nativeBuildInputs = [
    cross
    buildPackages.gnumake
    buildPackages.python3
  ];

  # Freestanding code: no libc, no hardening flags.
  hardeningDisable = [ "all" ];

  makeFlags = [
    "-C"
    "fsbl"
    "CHIP_ARCH=sg200x"
    "ARCH=riscv"
    "BOOT_CPU=riscv"
    "CROSS_COMPILE=${cross.targetPrefix}"
    "DDR_CFG=ddr3_1866_x16"
    "TPU_PERF_MODE=y"
    "O=build/out"
    "BUILD_STRING=gnix"
    "V=0"
  ];

  postPatch = ''
    patchShebangs fsbl/plat build/scripts
    mkdir -p fsbl/build
    python3 build/scripts/mmap_conv.py --type h ${board}/memmap.py fsbl/build/cvi_board_memmap.h
  '';

  buildPhase = ''
    runHook preBuild
    # Reproducible build message (otherwise `date -Is`).
    make -j$NIX_BUILD_CORES $makeFlags \
      BUILD_MESSAGE_TIMESTAMP='"'"$(date -u -d @$SOURCE_DATE_EPOCH -Is)"'"' bl2

    cd fsbl
    ./plat/sg200x/chip_conf.py build/out/chip_conf.bin
    ./plat/sg200x/fiptool.py -v genfip build/out/fip.bin \
      --CHIP_CONF=build/out/chip_conf.bin \
      --NOR_INFO=$(printf '%72s' | tr ' ' F) \
      --NAND_INFO=00000000 \
      --BL2=build/out/bl2.bin \
      --BLCP_IMG_RUNADDR=0x05200200 \
      --BLCP_PARAM_LOADADDR=0 \
      --BLCP=test/empty.bin \
      --DDR_PARAM=test/cv181x/ddr_param.bin
    cd ..
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm444 fsbl/build/out/bl2.bin $out/bl2.bin
    install -Dm444 fsbl/build/out/fip.bin $out/fip.bin
    runHook postInstall
  '';

  meta = {
    description = "SG2002 FSBL (BL2 + DDR init) for the LicheeRV Nano / NanoKVM, from source";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.all;
  };
}
