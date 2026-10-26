# fw_printenv/fw_setenv and mkenvimage from U-Boot's source, without
# U-Boot's Python tooling (which pulls Python, cryptography and Rust).
{
  stdenv,
  buildPackages,
  bison,
  flex,
  src,
  version,
}:
stdenv.mkDerivation {
  pname = "uboot-env-tools";
  inherit src version;
  depsBuildBuild = [ buildPackages.stdenv.cc ];
  nativeBuildInputs = [
    bison
    flex
  ];
  # Kconfig runs on the build machine; the tools themselves are built for
  # the target (CROSS_BUILD_TOOLS).
  makeFlags = [
    "HOSTCC=${buildPackages.stdenv.cc}/bin/cc"
    "CROSS_COMPILE=${stdenv.cc.targetPrefix}"
    "CROSS_BUILD_TOOLS=y"
  ];
  enableParallelBuilding = true;
  configurePhase = ''
    runHook preConfigure
    make $makeFlags tools-only_defconfig
    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES $makeFlags envtools
    # Same flags as U-Boot's tools/Makefile: libc headers first.
    $CC -static -O2 -DUSE_HOSTCC -D__KERNEL_STRICT_NAMES \
      -include ./include/compiler.h -idirafter ./include -I ./tools \
      -o mkenvimage tools/mkenvimage.c tools/os_support.c lib/crc32.c
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 tools/env/fw_printenv $out/bin/fw_printenv
    ln -s fw_printenv $out/bin/fw_setenv
    install -Dm755 mkenvimage $out/bin/mkenvimage
    runHook postInstall
  '';
}
