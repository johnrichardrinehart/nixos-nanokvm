{
  coreutils,
  gnused,
  openssh,
  pv,
  writeShellApplication,
  slot,
  maxTries,
}:
writeShellApplication {
  name = "nanokvm-deploy";
  runtimeInputs = [
    coreutils
    gnused
    openssh
    pv
  ];
  text = ''
    SLOT_IMAGE=${slot}/slot.img.zst
    SLOT_SHA256="$(cat ${slot}/sha256)"
    SLOT_RAW_SHA256="$(cat ${slot}/raw-sha256)"
    SLOT_SIZE="$(cat ${slot}/size)"
    MAX_TRIES=${toString maxTries}
  ''
  + builtins.readFile ./nanokvm-deploy.sh;
}
