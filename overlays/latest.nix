# Boot-chain releases newer than what nixpkgs and nixos-nanokvm ship.
# Remove an entry once the input it overrides reaches that version (the
# build asserts each pin is not older than what the input provides).
#
# OpenSBI 1.9 fits the SG2002 firmware region only when built with this
# board's drivers alone (modules/board.nix); the build checks its size.
final: prev:
let
  inherit (prev) lib;
  pins = {
    kernel = {
      version = "7.3";
      hash = "sha256-hzY8JPEOBjIes2J2VSEJTpRHH2v/i84taz5A858ASVM=";
    };
    uboot = {
      version = "2026.10";
      # ftp.denx.de has no 2026.10 tarball yet; the GitHub mirror has the tag.
      hash = "sha256-BXIpyAY+uKSohrdG4BxAo0zq4CYmh2z9rFw1jA7Yu8s=";
    };
    opensbi = {
      version = "1.9";
      hash = "sha256-3RXsdo5e494odYtcRMMtAwes2LLniohHlOXEWy6CmrU=";
    };
  };

  notOlder =
    what: pinned: shipped:
    lib.throwIf (lib.versionOlder pinned shipped) "overlays/latest.nix: ${what} pin ${pinned} is older than the ${shipped} the inputs ship; drop the pin";
in
{
  # nixos-nanokvm calls `linux_7_2.override { argsOverride = ...; }`,
  # which would replace a plain argsOverride. Merge the pin into every
  # later override instead. Its SG2002 patch queue targets 7.2; 7.3 moved
  # the context of the hwrng Makefile hunk, so that patch is rebased.
  linux_7_2 =
    let
      pin = rec {
        inherit (pins.kernel) version;
        # 7.3 -> 7.3.0, as the kernel's own version string reads.
        modDirVersion = lib.versions.pad 3 version;
        src = final.fetchurl {
          url = "mirror://kernel/linux/kernel/v7.x/linux-${version}.tar.xz";
          inherit (pins.kernel) hash;
        };
      };
    in
    notOlder "kernel" pins.kernel.version prev.linux_7_2.version (
      lib.makeOverridable (
        args:
        prev.linux_7_2.override (
          args
          // {
            argsOverride = (args.argsOverride or { }) // pin;
            kernelPatches = map (
              p:
              if p.name == "hwrng-sg2002" then
                p // { patch = ../patches/linux-7.3-hwrng-add-sg2002-support.patch; }
              else
                p
            ) (args.kernelPatches or [ ]);
          }
        )
      ) { }
    );

  sg2002-uboot-mainline = notOlder "U-Boot" pins.uboot.version prev.sg2002-uboot-mainline.version (
    prev.sg2002-uboot-mainline.overrideAttrs (old: {
      inherit (pins.uboot) version;
      src = final.fetchFromGitHub {
        owner = "u-boot";
        repo = "u-boot";
        rev = "v${pins.uboot.version}";
        inherit (pins.uboot) hash;
      };
      # 2026.10 changed the context of nixos-nanokvm's LMB patch.
      patches = map (
        p:
        if lib.hasSuffix "-lmb-respect-SYS_MEM_TOP_HIDE-for-allocations.patch" (baseNameOf p) then
          ../patches/u-boot-2026.10-lmb-respect-SYS_MEM_TOP_HIDE.patch
        else
          p
      ) old.patches;
    })
  );

  opensbi = notOlder "OpenSBI" pins.opensbi.version prev.opensbi.version (
    prev.opensbi.overrideAttrs {
      inherit (pins.opensbi) version;
      src = final.fetchFromGitHub {
        owner = "riscv-software-src";
        repo = "opensbi";
        rev = "v${pins.opensbi.version}";
        inherit (pins.opensbi) hash;
      };
    }
  );

  # nixos-nanokvm's FIP builder takes BL2 (the FSBL) and the DDR parameters
  # from this fip.bin. Upstream extracts it from a Sipeed release image;
  # here it is built from Sipeed's source (pkgs/sg2002-fsbl).
  sg2002-fip = final.callPackage ../pkgs/sg2002-fsbl { };
}
