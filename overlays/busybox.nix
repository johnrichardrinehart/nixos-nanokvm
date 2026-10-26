# busybox passwd/chpasswd hash with DES by default, which dropbear's
# password check (musl crypt) does not accept: SHA-512 instead.
final: prev: {
  busybox = prev.busybox.override {
    extraConfig = ''
      CONFIG_FEATURE_DEFAULT_PASSWD_ALGO "sha512"
    '';
  };
}
