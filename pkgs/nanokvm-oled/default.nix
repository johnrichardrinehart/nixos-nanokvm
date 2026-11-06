# The status screen of the NanoKVM's OLED (Rust): the screen library
# (src/lib.rs), whose text is checked at compile time to fit its place,
# and the program (src/main.rs). Fonts are Spleen's console fonts
# (BSD-2-Clause), embedded at build time.
{
  lib,
  rustPlatform,
  spleen,
  # Shown on the splash screen (the flake passes its git revision).
  version ? "dev",
}:
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
    NANOKVM_VERSION = version;
  };
  meta.mainProgram = "nanokvm-oled";
}
