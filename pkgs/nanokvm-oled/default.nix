# The status screen of the NanoKVM's OLED (Rust): the screen library
# (src/lib.rs), whose text is checked at compile time to fit its place,
# and the program (src/main.rs). Fonts are Spleen's console fonts
# (BSD-2-Clause), embedded at build time.
{
  lib,
  rustPlatform,
  runCommand,
  emptyFile,
  librsvg,
  netpbm,
  spleen,
  # Shown on the splash screen (the flake passes its git revision).
  version ? "dev",
  # SVG images of the site, or null: a logo shown after the splash (fit
  # into 128x64) and the icon of the header bar (9x9).
  logo ? null,
  headerIcon ? null,
}:
let
  # A 1 bpp PBM of `svg`, fit into w x h: dark parts are the lit pixels.
  pbm =
    name: svg: w: h:
    if svg == null then
      emptyFile
    else
      runCommand "nanokvm-oled-${name}.pbm"
        {
          nativeBuildInputs = [
            librsvg
            netpbm
          ];
        }
        ''
          rsvg-convert --keep-aspect-ratio -b white -w ${toString w} -h ${toString h} ${svg} \
            | pngtopnm | ppmtopgm | pamthreshold -simple -threshold 0.5 | pamtopnm > $out
        '';
in
rustPlatform.buildRustPackage {
  pname = "nanokvm-oled";
  inherit version;
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;
  env = {
    NANOKVM_OLED_FONT_SMALL = "${spleen}/share/consolefonts/spleen-5x8.psfu";
    NANOKVM_OLED_FONT_BIG = "${spleen}/share/consolefonts/spleen-8x16.psfu";
    NANOKVM_OLED_LOGO = pbm "logo" logo 128 64;
    NANOKVM_OLED_HEADER_ICON = pbm "header-icon" headerIcon 9 9;
    NANOKVM_VERSION = version;
  };
  meta.mainProgram = "nanokvm-oled";
}
