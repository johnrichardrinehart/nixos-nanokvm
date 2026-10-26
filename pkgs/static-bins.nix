# Copy chosen static executables out of a package and drop every store
# reference they carry (scripts, data paths, dev outputs). Static ELFs need
# none of them at run time.
{
  lib,
  runCommand,
  buildPackages,
}:
name: pkg: bins:
runCommand "${name}-bins-${pkg.version}"
  {
    nativeBuildInputs = [
      buildPackages.nukeReferences
      buildPackages.file
    ];
    allowedReferences = [ ];
  }
  ''
    mkdir -p $out/bin
    ${lib.concatMapStrings (b: ''
      src=${lib.getBin pkg}/bin/${b}
      file -L "$src" | grep -q "statically linked" || { echo "$src is not static" >&2; exit 1; }
      cp -L "$src" $out/bin/${b}
    '') bins}
    chmod u+w $out/bin/*
    nuke-refs $out/bin/*
  ''
