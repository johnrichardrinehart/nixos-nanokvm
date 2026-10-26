# Boots the A/B module on mixos (static userspace, the host's stock kernel)
# against a virtio disk laid out like the SD card: state init (grow, disko
# format, wipe), persistence, and nanokvm-ab write/arm/commit cycles. Boots
# are simulated by pointing the tool at a fake kernel command line; U-Boot's
# side is covered by the uboot-bootcmd check.
{ diskoLib }:
{ hostPkgs, lib, ... }:
let
  disk = "/dev/vda";
  # nixpkgs' fixed test key pair.
  sshKeys = import (hostPkgs.path + "/nixos/tests/ssh-keys.nix") hostPkgs;
  slotSizeMiB = 64;
  layout = import ../lib/layout.nix { inherit disk slotSizeMiB; };

  # Stand-in slot image: any bytes work, the tool never mounts slots.
  slot = hostPkgs.runCommand "nanokvm-test-slot" { nativeBuildInputs = [ hostPkgs.zstd ]; } ''
    mkdir $out
    head -c 3000000 /dev/urandom > slot.img
    zstd -q slot.img -o $out/slot.img.zst
    sha256sum $out/slot.img.zst | cut -d' ' -f1 > $out/sha256
    sha256sum slot.img | cut -d' ' -f1 > $out/raw-sha256
    stat -c %s slot.img > $out/size
  '';

  # Card image with 512 MiB unpartitioned at the end, so /state can grow.
  mkDisk =
    { dataMarker }:
    hostPkgs.runCommand "nanokvm-test-disk"
      {
        nativeBuildInputs = with hostPkgs; [
          btrfs-progs
          util-linux
        ];
      }
      ''
        truncate -s $(( ${toString (layout.imageSectors * 512)} + 512 * 1024 * 1024 )) disk.img
        sfdisk --no-reread --no-tell-kernel disk.img < ${hostPkgs.writeText "layout.sfdisk" layout.sfdiskScript}
        ${lib.optionalString dataMarker ''
          mkdir -p data
          echo keep > data/marker
          truncate -s ${toString (layout.data.initialSize * 512)} data.img
          mkfs.btrfs -q -r data data.img
          dd if=data.img of=disk.img bs=512 seek=${toString layout.data.start} conv=notrunc status=none
        ''}
        mv disk.img $out
      '';

  node =
    cmdline:
    { pkgs, ... }:
    {
      imports = [
        ../modules/ab.nix
        ../modules/ssh.nix
        ../modules/mixos-fixes.nix
      ];
      nanokvm.authorizedKeys = [ sshKeys.snakeOilEd25519PublicKey ];
      _module.args.diskoLib = diskoLib;
      # Static userspace with the board's busybox, as on the board (the
      # framework defaults to hostPkgs).
      nixpkgs.pkgs = lib.mkForce (hostPkgs.pkgsStatic.extend (import ../overlays/busybox.nix));
      boot.kernelPackages = hostPkgs.linuxPackages_7_2;
      boot.kernelModules = [ "btrfs" ];
      nanokvm.ab = {
        inherit disk slotSizeMiB;
        healthCheck = "true";
        envTools = pkgs.callPackage ../pkgs/uboot-env-tools.nix {
          inherit (hostPkgs.ubootTools) src version;
        };
      };
      testing.kernelCmdline = [
        "console=ttyAMA0"
        "nanokvm.slot=a"
        "nanokvm.trial=0"
      ]
      ++ cmdline;
      # mixos' harness picks a machine type only for x86.
      testing.qemu.args = lib.optionals hostPkgs.stdenv.hostPlatform.isAarch64 [
        "-machine"
        "virt"
        "-cpu"
        "max"
      ];
      testing.qemu.diskImage = 2 * 1024 * 1024 * 1024;
      # mixos VMs have no host share; ship the test image in /etc.
      etc."nanokvm-test-slot.img.zst".source = "${slot}/slot.img.zst";
      etc."nanokvm-test-ssh-key".source = sshKeys.snakeOilEd25519PrivateKey;
    };
in
{
  name = "nanokvm-device";

  mixos.nodes = {
    fresh = node [ ];
    wipe = node [ "nanokvm.wipe=1" ];
  };

  testScript = ''
    import subprocess

    for machine, image in [(fresh, "${mkDisk { dataMarker = false; }}"), (wipe, "${mkDisk { dataMarker = true; }}")]:
        subprocess.run(
            ["${hostPkgs.qemu-utils}/bin/qemu-img", "convert", "-f", "raw", "-O", "qcow2", image,
             str(machine.state_dir / f"mixos-{machine.name}-disk.qcow2")],
            check=True,
        )

    def state_on_data(machine):
        machine.succeed("mount | grep -q '^/dev/vda4 on /state type btrfs'")

    def reboot(machine):
        machine.execute("reboot", check_output=False)
        machine.connected = False
        machine.connect()

    with subtest("state init formats the empty data partition and grows it"):
        fresh.start(allow_reboot=True)
        state_on_data(fresh)
        fresh.succeed(
            "test $(( $(cat /sys/class/block/vda4/start) + $(cat /sys/class/block/vda4/size) + 2048 )) -ge $(cat /sys/class/block/vda/size)"
        )
        fresh.wait_until_succeeds("test $(df -m /state | tail -n1 | awk '{print $2}') -gt 600")

    with subtest("a normal boot writes a clean environment"):
        fresh.wait_until_succeeds("nanokvm-ab status | grep -qx env=ok")
        fresh.succeed("nanokvm-ab status | grep -qx active=a")

    with subtest("state survives a reboot and the existing filesystem is kept"):
        fresh.succeed("echo hello > /var/persist-check")
        reboot(fresh)
        state_on_data(fresh)
        fresh.succeed("grep -qx hello /var/persist-check")

    def ab(cmdline, args, state):
        return fresh.succeed(
            f"echo '{cmdline}' > /tmp/cmdline-{state}; mkdir -p /tmp/{state}; "
            f"NANOKVM_AB_CMDLINE=/tmp/cmdline-{state} NANOKVM_AB_STATE_DIR=/tmp/{state} nanokvm-ab {args}"
        )

    def ab_fails(cmdline, args, state):
        fresh.fail(
            f"echo '{cmdline}' > /tmp/cmdline-{state}; mkdir -p /tmp/{state}; "
            f"NANOKVM_AB_CMDLINE=/tmp/cmdline-{state} NANOKVM_AB_STATE_DIR=/tmp/{state} nanokvm-ab {args}"
        )

    def status(cmdline, state):
        return dict(line.split("=", 1) for line in ab(cmdline, "status", state).strip().splitlines())

    def meta(name):
        return open(f"${slot}/{name}").read().strip()

    fresh.succeed("cp /etc/nanokvm-test-slot.img.zst /tmp/slot.img.zst")
    on_a = "nanokvm.slot=a nanokvm.trial=0"
    sha = meta("sha256")
    sizes = f"--raw-sha256 {meta('raw-sha256')} --size {meta('size')}"
    write = f"write --sha256 {sha} {sizes} < /tmp/slot.img.zst"
    slot_b_sha = f"head -c {meta('size')} /dev/vda3 | sha256sum | cut -d' ' -f1"

    with subtest("a corrupted stream is rejected and the slot left unbootable"):
        ab_fails(on_a, f"write --sha256 {'0' * 64} {sizes} < /tmp/slot.img.zst", "boot1")
        fresh.succeed("test \"$(head -c 1048576 /dev/vda3 | tr -d '\\0' | wc -c)\" = 0")
        ab_fails(on_a, "arm", "boot1")

    with subtest("write fills the inactive slot and records its image"):
        assert "slot=b" in ab(on_a, write, "boot1")
        assert fresh.succeed(slot_b_sha).strip() == meta("raw-sha256")

    with subtest("arm schedules a trial of the inactive slot"):
        ab(on_a, "arm --tries 2", "boot1")
        s = status(on_a, "boot1")
        assert (s["active"], s["try"], s["tries"]) == ("a", "b", "2"), s

    trial_b = "nanokvm.slot=b nanokvm.trial=1"

    with subtest("an unconfirmed trial refuses to overwrite the committed slot"):
        ab_fails(trial_b, write, "boot2")
        s = status(trial_b, "boot2")
        assert (s["booted"], s["trial"], s["committed"], s["image"]) == ("b", "1", "0", sha), s

    with subtest("commit after the health check makes the trial slot active"):
        fresh.succeed("touch /tmp/boot2/healthy")
        ab(trial_b, "commit", "boot2")
        s = status(trial_b, "boot2")
        assert (s["active"], s["try"], s["tries"], s["committed"]) == ("b", "none", "0", "1"), s

    on_b = "nanokvm.slot=b nanokvm.trial=0"

    with subtest("a trial that U-Boot could not load is recorded as failed"):
        ab(on_b, write, "boot3")
        ab(on_b, "arm", "boot3")
        assert status(on_b, "boot3")["try"] == "a"
        ab(on_b, "commit", "boot4")
        s = status(on_b, "boot4")
        assert (s["active"], s["try"], s["failed"]) == ("b", "none", "a"), s

    with subtest("a wipe request is cleared by the next commit"):
        ab(on_b, "request-wipe-data", "boot4")
        assert status(on_b, "boot4")["wipe"] == "1"
        ab(on_b, "commit", "boot5")
        assert status(on_b, "boot5")["wipe"] == "0"

    with subtest("a healthy boot clears U-Boot's count of unconfirmed boots"):
        fresh.succeed("fw_setenv -c /tmp/boot5/fw_env.config ab_boots 5")
        assert status(on_b, "boot5")["boots"] == "5"
        ab(on_b, "boot-verify", "boot6")
        s = status(on_b, "boot6")
        assert (s["boots"], s["active"], s["failed"], s["env"]) == ("0", "b", "a", "ok"), s

    with subtest("root logs in over SSH with an authorized key"):
        fresh.wait_until_succeeds("pidof dropbear")
        fresh.succeed("dropbearconvert openssh dropbear /etc/nanokvm-test-ssh-key /tmp/id_dropbear")
        out = fresh.succeed("dbclient -y -i /tmp/id_dropbear root@127.0.0.1 'echo logged-in-as-$(id -u)' 2>&1")
        assert "logged-in-as-0" in out, out
        fresh.succeed("dropbearkey -t ed25519 -f /tmp/id_other >/dev/null")
        # A wrong password, so dbclient's password fallback cannot get in.
        fresh.fail("DROPBEAR_PASSWORD=wrong dbclient -y -i /tmp/id_other root@127.0.0.1 true </dev/null")

    with subtest("keys added on the device and the root password log in"):
        fresh.succeed(
            "mkdir -p -m 0700 /root/.ssh",
            "dropbearkey -y -f /tmp/id_other | grep ^ssh- > /root/.ssh/authorized_keys",
            "sv restart dropbear",
        )
        fresh.wait_until_succeeds("dbclient -y -i /tmp/id_other root@127.0.0.1 true </dev/null")
        out = fresh.succeed("DROPBEAR_PASSWORD=root dbclient -y root@127.0.0.1 'echo pw-$(id -u)' </dev/null 2>&1")
        assert "pw-0" in out, out
        fresh.fail("DROPBEAR_PASSWORD=wrong dbclient -y root@127.0.0.1 true </dev/null")
        # passwd (here its non-interactive twin) replaces the default; the
        # new hash lands in /state's /etc.
        fresh.succeed("echo root:n3w | chpasswd")
        fresh.succeed("test -f /state/etc/upper/shadow")
        fresh.fail("DROPBEAR_PASSWORD=root dbclient -y root@127.0.0.1 true </dev/null")
        fresh.succeed("DROPBEAR_PASSWORD=n3w dbclient -y root@127.0.0.1 true </dev/null")

    with subtest("environment writes leave /state mounted"):
        state_on_data(fresh)
        fresh.shutdown()

    with subtest("nanokvm.wipe=1 erases the data partition before it is mounted"):
        wipe.start()
        state_on_data(wipe)
        wipe.fail("test -e /state/marker")
  '';
}
