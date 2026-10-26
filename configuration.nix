# Site configuration. Tunables: nanokvm.* (modules/board.nix, ssh.nix,
# kvm.nix, display.nix) and nanokvm.ab.* (modules/ab.nix).
{
  nanokvm.hostName = "nanokvm";

  # Root logs in over SSH with these keys, keys added on the device or on
  # the card (modules/ssh.nix), or the password below. Deploys need a key.
  nanokvm.authorizedKeys = [
    # "ssh-ed25519 AAAA... you@host"
  ];

  # Initial root password; change it on the device with `passwd`. Set to
  # null for key-only logins.
  nanokvm.rootPassword = "root";
}
