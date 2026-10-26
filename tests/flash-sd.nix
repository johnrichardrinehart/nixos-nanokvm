# nanokvm-flash-sd against a removable USB card reader in a VM (QEMU
# usb-storage, removable=on, shows as /dev/sda) holding stand-in data.
#
# Checks: a fixed disk is refused; flashing saves the old card when asked,
# then writes and verifies the flake's image; --image writes a downloaded
# image instead.
{ pkgs, ... }:
let
  # Stands in for the SD image: 64 MiB of deterministic, distinct data
  # with a FAT16 firmware partition at sector 1, as on the real card.
  mkImage =
    name: seed:
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          pkgs.zstd
          pkgs.dosfstools
        ];
      }
      ''
        { seq ${toString seed} 20000000 || true; } | head -c 64M > img
        truncate -s 16M fat.img
        mkfs.vfat -F 16 -n FIRMWARE fat.img >/dev/null
        dd if=fat.img of=img bs=512 seek=1 conv=notrunc status=none
        mkdir -p $out/sd-image
        zstd -q img -o $out/sd-image/nanokvm-sd.img.zst
        sha256sum img | cut -d' ' -f1 > $out/raw-sha256
      '';
  sdImage = mkImage "fake-nanokvm-sd-image" 1;
  otherImage = mkImage "other-nanokvm-sd-image" 7;
  flash = pkgs.callPackage ../pkgs/nanokvm-flash-sd.nix {
    inherit sdImage;
    firmwareOffset = 512;
  };
in
{
  name = "nanokvm-flash-sd";

  nodes.host = {
    virtualisation.emptyDiskImages = [ 128 ]; # /dev/vdb, fixed
    # The start script is shell run in the VM's state directory, which is
    # where it creates the card image (as it does emptyDiskImages).
    virtualisation.qemu.options = [
      "-drive if=none,id=card,format=raw,file=$(test -e card.img || truncate -s 128M card.img; echo card.img)"
      "-device qemu-xhci"
      "-device usb-storage,drive=card,removable=on"
    ];
    environment.systemPackages = [
      flash
      pkgs.zstd
      pkgs.mtools
    ];
  };

  testScript = ''
    raw_sha = open("${sdImage}/raw-sha256").read().strip()
    other_sha = open("${otherImage}/raw-sha256").read().strip()

    host.start()
    host.wait_for_unit("multi-user.target")
    host.wait_until_succeeds("test \"$(cat /sys/block/sda/removable)\" = 1")
    host.succeed("head -c 128M /dev/urandom > /dev/sda && sync")
    old_sha = host.succeed("sha256sum < /dev/sda | cut -d' ' -f1").strip()

    def card(size_mib):
        return host.succeed(
            f"sync; echo 3 > /proc/sys/vm/drop_caches; dd if=/dev/sda bs=1M count={size_mib} status=none | sha256sum | cut -d' ' -f1"
        ).strip()

    with subtest("a fixed disk is refused"):
        out = host.fail("nanokvm-flash-sd --yes /dev/vdb 2>&1")
        assert "not removable" in out, out

    with subtest("the flake's image, with a backup of the old card"):
        out = host.succeed("nanokvm-flash-sd --yes --backup /root/old.img.zst /dev/sda 2>&1")
        print(out)
        assert card(64) == raw_sha
        backup = host.succeed("zstd -dc /root/old.img.zst | sha256sum | cut -d' ' -f1").strip()
        assert backup == old_sha, f"backup {backup} != card {old_sha}"

    with subtest("a downloaded image"):
        host.succeed("nanokvm-flash-sd --yes --image ${otherImage}/sd-image/nanokvm-sd.img.zst /dev/sda")
        assert card(64) == other_sha

    with subtest("--authorized-keys lands on the FAT partition"):
        host.succeed("echo 'ssh-ed25519 AAAAtest user@test' > /root/keys")
        host.succeed("nanokvm-flash-sd --yes --authorized-keys /root/keys /dev/sda")
        out = host.succeed("MTOOLS_SKIP_CHECK=1 mtype -i /dev/sda@@512 ::authorized_keys")
        assert out.strip() == "ssh-ed25519 AAAAtest user@test", out
  '';
}
