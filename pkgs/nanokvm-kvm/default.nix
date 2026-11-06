# Web KVM server for the NanoKVM: HDMI video over WebSocket (changed tiles,
# MJPEG, or H.264 through sg2002-h264-bridge), USB HID keyboard and mouse,
# ATX buttons. Static; the web UI is served from $out/share.
{
  lib,
  stdenv,
  lz4,
  libjpeg,
  librsvg,
  # The web page's title (the browser's title bar and tab).
  title ? "NanoKVM",
  # The web page's icon: an SVG file, or null for none. PNG copies serve
  # browsers that do not use an SVG icon (Safari: apple-touch-icon).
  favicon ? null,
}:
stdenv.mkDerivation {
  pname = "nanokvm-kvm";
  version = "0.1";
  src = ./.;
  postPatch = ''
    substituteInPlace www/index.html \
      --replace-fail '<title>NanoKVM</title>' ${lib.escapeShellArg "<title>${lib.escapeXML title}</title>"}
  ''
  + lib.optionalString (favicon != null) ''
    cp ${favicon} www/favicon.svg
    rsvg-convert -w 32 -h 32 www/favicon.svg -o www/favicon-32.png
    rsvg-convert -w 180 -h 180 -b white www/favicon.svg -o www/apple-touch-icon.png
    substituteInPlace www/index.html \
      --replace-fail '<link rel="stylesheet"' '<link rel="icon" href="favicon-32.png" type="image/png" sizes="32x32"><link rel="apple-touch-icon" href="apple-touch-icon.png"><link rel="icon" href="favicon.svg" type="image/svg+xml"><link rel="stylesheet"'
  '';
  nativeBuildInputs = lib.optional (favicon != null) librsvg;
  buildInputs = [
    lz4
    libjpeg
  ];
  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -Werror -pthread \
      -DWEB_DIR='"'"$out"'/share/nanokvm-kvm/www"' \
      -o nanokvm-kvm kvm.c -llz4 -ljpeg
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 nanokvm-kvm $out/bin/nanokvm-kvm
    install -Dm644 -t $out/share/nanokvm-kvm/www www/*
    runHook postInstall
  '';
  meta.mainProgram = "nanokvm-kvm";
}
