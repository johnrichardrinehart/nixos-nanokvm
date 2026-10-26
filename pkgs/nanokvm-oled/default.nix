# Static status-screen program for the NanoKVM OLED. Fonts are Spleen's
# console fonts (BSD-2-Clause), embedded at build time.
{
  stdenv,
  buildPackages,
  spleen,
  # Shown on the splash screen (the flake passes its git revision).
  version ? "dev",
}:
stdenv.mkDerivation {
  pname = "nanokvm-oled";
  inherit version;
  src = ./.;
  nativeBuildInputs = [ buildPackages.xxd ];
  buildPhase = ''
    runHook preBuild
    cp ${spleen}/share/consolefonts/spleen-5x8.psfu small.psf
    cp ${spleen}/share/consolefonts/spleen-8x16.psfu big.psf
    { xxd -i -n font_small small.psf; xxd -i -n font_big big.psf; } > fonts.h
    $CC -O2 -Wall -Wextra -Werror -DNANOKVM_VERSION='"${version}"' -o nanokvm-oled oled.c
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 nanokvm-oled $out/bin/nanokvm-oled
    runHook postInstall
  '';
  meta.mainProgram = "nanokvm-oled";
}
