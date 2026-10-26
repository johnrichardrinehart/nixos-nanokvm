# Root login over dropbear: keys and, optionally, a password. Shared by the
# board and the device VM test, which logs in with it.
#
# Keys come from three places, merged when dropbear starts (restart it with
# `sv restart dropbear` after editing):
#   - nanokvm.authorizedKeys, built into the image;
#   - /root/.ssh/authorized_keys, on /state, written on the device;
#   - `authorized_keys` on the card's FAT partition (keysPartition), for
#     adding keys to a downloaded image from any computer.
# The root password starts as rootPassword; `passwd` changes it, and the
# new /etc/shadow persists in /state's /etc overlay.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nanokvm;
  keys = "/run/dropbear/authorized_keys";
  shadow =
    pkgs.buildPackages.runCommand "shadow" { nativeBuildInputs = [ pkgs.buildPackages.openssl ]; }
      ''
        # A fixed salt keeps the image reproducible; the password is public.
        echo "root:$(openssl passwd -6 -salt nanokvm ${lib.escapeShellArg cfg.rootPassword}):1::::::" > $out
      '';
in
{
  options.nanokvm = {
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys built into the image that may log in as root.";
    };

    rootPassword = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "root";
      description = ''
        Initial root password for SSH (change it with `passwd`; the change
        persists). Null disables password logins: keys only.
      '';
    };

    keysPartition = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "FAT partition whose `authorized_keys` file adds root keys.";
    };
  };

  config = {
    users.root = {
      uid = 0;
      gid = 0;
      home = "/root";
      shell = "/bin/sh";
    };
    groups.root.id = 0;

    packages = [ pkgs.dropbear ];

    # Host key on /state, so deploys keep it. dropbear rejects every key
    # unless each directory from the keys file up to / is root-owned and
    # not group- or world-writable (see modules/mixos-fixes.nix).
    services.dropbear.run = pkgs.writeScript "dropbear-run" ''
      #!/bin/sh
      mkdir -p /state/dropbear
      key=/state/dropbear/ed25519_host_key
      [ -f "$key" ] || dropbearkey -t ed25519 -f "$key"
      ${lib.optionalString (cfg.rootPassword != null) ''
        # passwd rewrites /etc/passwd and /etc/shadow, following symlinks
        # into the read-only store, so both are real files in /state's /etc
        # overlay: passwd refreshed from this image at every boot, shadow
        # seeded once.
        install -m 0644 ${config.etc."passwd".source} /etc/passwd
        [ -f /etc/shadow ] || install -m 0600 ${shadow} /etc/shadow
      ''}
      mkdir -p -m 0700 ${dirOf keys}
      {
        cat ${pkgs.writeText "authorized_keys" (lib.concatLines cfg.authorizedKeys)}
        cat /root/.ssh/authorized_keys 2>/dev/null
        ${lib.optionalString (cfg.keysPartition != null) ''
          MTOOLS_SKIP_CHECK=1 ${pkgs.mtools}/bin/mtype -i ${cfg.keysPartition} ::authorized_keys 2>/dev/null
        ''}
      } | tr -d '\r' > ${keys}
      chmod 0600 ${keys}
      exec dropbear -F -E ${
        lib.optionalString (cfg.rootPassword == null) "-s"
      } -r "$key" -D ${dirOf keys} -p 22
    '';
  };
}
