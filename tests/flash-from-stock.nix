# nanokvm-flash-from-stock against a stand-in for Sipeed's stock firmware:
# a VM with /etc/kvm/hw, an SD card (/dev/vdb) in the stock layout whose
# root partition is mounted read-write, and root SSH. The script runs the
# real host and device halves with static tools built for the VM.
#
# Checks: another carrier is refused before anything is written; a beta
# unit has its stock system saved (MBR, p1, p2) and verifiable, the image
# written and verified on the card, and the device rebooted.
{ pkgs, lib, ... }:
let
  staticBins = pkgs.callPackage ../pkgs/static-bins.nix { };
  deviceTools = {
    busybox = "${staticBins "busybox" pkgs.pkgsStatic.busybox [ "busybox" ]}/bin/busybox";
    zstd = "${staticBins "zstd" pkgs.pkgsStatic.zstd [ "zstd" ]}/bin/zstd";
  };

  # Stands in for the SD image: 64 MiB of deterministic, distinct data.
  sdImage =
    pkgs.runCommand "fake-nanokvm-sd-image"
      {
        nativeBuildInputs = [ pkgs.zstd ];
      }
      ''
        { seq 1 20000000 || true; } | head -c 64M > img
        mkdir -p $out/sd-image
        zstd -q img -o $out/sd-image/nanokvm-sd.img.zst
        sha256sum $out/sd-image/nanokvm-sd.img.zst | cut -d' ' -f1 > $out/sha256
        sha256sum img | cut -d' ' -f1 > $out/raw-sha256
        stat -c %s img > $out/size
      '';

  flash = pkgs.callPackage ../pkgs/nanokvm-flash-from-stock.nix {
    inherit sdImage deviceTools;
    deviceArch = pkgs.stdenv.hostPlatform.uname.processor;
  };

  # nixpkgs' fixed test key pair: known at evaluation time.
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
in
{
  name = "nanokvm-flash-from-stock";

  nodes = {
    stock = {
      virtualisation.emptyDiskImages = [ 512 ];
      environment.etc."kvm/hw" = {
        text = "beta\n";
        mode = "0644";
      };
      services.openssh = {
        enable = true;
        settings.PermitRootLogin = "prohibit-password";
      };
      users.users.root.openssh.authorizedKeys.keys = [ keys.snakeOilEd25519PublicKey ];
      environment.systemPackages = [ pkgs.e2fsprogs ];
    };
    client = {
      environment.systemPackages = [
        flash
        pkgs.zstd
      ];
      environment.variables.NANOKVM_FLASH_DISK = "/dev/vdb";
    };
  };

  testScript = ''
    raw_sha = open("${sdImage}/raw-sha256").read().strip()

    start_all()
    stock.wait_for_unit("sshd.service")
    client.wait_for_unit("multi-user.target")
    client.succeed(
        "install -D -m 600 ${keys.snakeOilEd25519PrivateKey} /root/.ssh/id_ed25519",
    )

    # The stock layout: p1 boot, p2 root (mounted rw), p3 the USB drive.
    stock.succeed(
        "printf 'label: dos\n2048,32768,c\n34816,131072,83\n165888,,7\n' | sfdisk /dev/vdb",
        "udevadm settle",
        "head -c 16M /dev/urandom > /dev/vdb1",
        "mkfs.ext4 -q /dev/vdb2",
        "mkdir -p /stock && mount /dev/vdb2 /stock",
        "head -c 20M /dev/urandom > /stock/data && sync",
    )
    # The backup ends at p2's end, rounded up to a MiB.
    p2_end_mib = (34816 + 131072 + 2047) // 2048
    stock_sha = stock.succeed(
        f"sync; echo 3 > /proc/sys/vm/drop_caches; dd if=/dev/vdb bs=1M count={p2_end_mib} status=none | sha256sum | cut -d' ' -f1"
    ).strip()

    with subtest("another carrier is refused before anything changes"):
        stock.succeed("echo alpha > /etc/kvm/hw")
        out = client.fail("nanokvm-flash-from-stock --yes --no-wait --backup /root/alpha.img.zst stock 2>&1")
        assert "beta carrier" in out, out
        client.fail("test -e /root/alpha.img.zst")
        stock.succeed("grep -q ' /stock ext4 rw' /proc/mounts")
        stock.succeed("echo beta > /etc/kvm/hw")

    with subtest("flashing saves the stock system, writes and verifies the image, reboots"):
        out = client.succeed("nanokvm-flash-from-stock --yes --no-wait --backup /root/stock.img.zst stock 2>&1")
        print(out)
        assert "nanokvm-flash: verified" in out, out
        stock.wait_for_shutdown()

        backup = client.succeed("zstd -dc /root/stock.img.zst | sha256sum | cut -d' ' -f1").strip()
        assert backup == stock_sha, f"backup {backup} != stock {stock_sha}"
        client.succeed(f"grep -qx 'raw-sha256={stock_sha}' /root/stock.img.zst.txt")

        stock.start()
        stock.wait_for_unit("multi-user.target")
        written = stock.succeed("dd if=/dev/vdb bs=1M count=64 status=none | sha256sum | cut -d' ' -f1").strip()
        assert written == raw_sha, f"card {written} != image {raw_sha}"
  '';
}
