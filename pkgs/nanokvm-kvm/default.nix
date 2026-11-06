# Web KVM server for the NanoKVM: HDMI video over WebSocket (changed tiles,
# MJPEG, or H.264 through sg2002-h264-bridge), USB HID keyboard and mouse,
# ATX buttons. Static; the web UI is served from $out/share.
{
  lib,
  stdenv,
  lz4,
  libjpeg,
  # The web page's title (the browser's title bar and tab).
  title ? "NanoKVM",
  # The web page's icon: an SVG file, or null for none.
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
    substituteInPlace www/index.html \
      --replace-fail '<link rel="stylesheet"' '<link rel="icon" href="favicon.svg" type="image/svg+xml"><link rel="stylesheet"'
  '';
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
