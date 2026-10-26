{
  description = "Sipeed NanoKVM (Lite/Full): static mixos with A/B full-image deploys";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # SG2002 board packages: mainline kernel, U-Boot, OpenSBI, FIP, DTBs.
    nanokvm = {
      url = "github:georgewhewell/nixos-nanokvm";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    mixos = {
      url = "github:jmbaur/mixos";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nanokvm,
      mixos,
      disko,
    }:
    let
      inherit (nixpkgs) lib;
      # Machines that can cross-build the riscv64 image.
      buildSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      # Machines the packages and apps run on; Darwin builds the image on a
      # Linux remote builder.
      hostSystems = buildSystems ++ [ "aarch64-darwin" ];
      linuxBuilderFor =
        system:
        if lib.hasSuffix "-darwin" system then "${lib.head (lib.splitString "-" system)}-linux" else system;

      boardPkgsFor =
        buildSystem:
        import nixpkgs {
          localSystem = buildSystem;
          # As nixos-nanokvm's platform module: baseline ISA and ABI, C906
          # scheduling.
          crossSystem = {
            system = "riscv64-linux";
            gcc.tune = "thead-c906";
          };
          # Only built with nanokvm.h264Encoder.enable: Sipeed's H.264 encoder
          # firmware, extracted from their factory image.
          config.allowUnfreePredicate =
            pkg:
            builtins.elem (lib.getName pkg) [
              "nanokvm-factory-runtime"
              "sg2002-coda980-firmware"
            ];
          overlays = [
            nanokvm.overlays.default
            (import ./overlays/latest.nix)
            (import ./overlays/busybox.nix)
            mixos.overlays.default
          ];
        };

      mkSystem =
        buildSystem:
        mixos.lib.mixosSystem {
          modules = [
            {
              _module.args = {
                boardPkgs = boardPkgsFor buildSystem;
                diskoLib = disko.lib;
              };
            }
            ./modules/ab.nix
            ./modules/board.nix
            ./modules/ssh.nix
            ./modules/mixos-fixes.nix
            ./configuration.nix
          ];
        };

      systems = lib.genAttrs buildSystems mkSystem;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      mixosConfigurations = lib.mapAttrs' (system: lib.nameValuePair "nanokvm-${system}") systems;

      packages = lib.genAttrs hostSystems (
        system:
        let
          pkgs = pkgsFor system;
          build = systems.${linuxBuilderFor system}.config.system.build;
        in
        {
          sd-image = build.sdImage;
          slot = build.slot;
          fip = build.fip;
          deploy = pkgs.callPackage ./pkgs/nanokvm-deploy.nix {
            inherit (build) slot;
            inherit (systems.${linuxBuilderFor system}.config.nanokvm.ab) maxTries;
          };
          default = self.packages.${system}.deploy;
          flash-from-stock = pkgs.callPackage ./pkgs/nanokvm-flash-from-stock.nix {
            inherit (build) sdImage;
            deviceTools = build.stockFlashTools;
            deviceArch = "riscv64";
          };
        }
      );

      apps = lib.genAttrs hostSystems (system: {
        deploy = {
          type = "app";
          program = lib.getExe self.packages.${system}.deploy;
          meta.description = "Deploy this flake's image to a NanoKVM's inactive slot";
        };
        default = self.apps.${system}.deploy;
        flash-from-stock = {
          type = "app";
          program = lib.getExe self.packages.${system}.flash-from-stock;
          meta.description = "Replace a NanoKVM's stock firmware with this flake's image over SSH";
        };
      });

      checks = lib.genAttrs buildSystems (
        system:
        let
          pkgs = pkgsFor system;
          ab = systems.${system}.config.nanokvm.ab;
          boardUboot = (boardPkgsFor system).sg2002-uboot-mainline;
          sandbox = pkgs.callPackage ./tests/uboot-sandbox.nix {
            ubootSrc = boardUboot.src;
            ubootVersion = boardUboot.version;
          };
          layout = import ./lib/layout.nix { inherit (ab) slotSizeMiB disk; };
          abBootScript = import ./lib/boot-script.nix { inherit lib; };
        in
        {
          uboot-bootcmd = pkgs.callPackage ./tests/uboot-bootcmd.nix {
            inherit sandbox layout abBootScript;
            inherit (ab) maxTries maxUnconfirmedBoots;
          };
          uboot-env = pkgs.callPackage ./tests/uboot-env.nix {
            inherit sandbox layout abBootScript;
            inherit (ab) maxTries maxUnconfirmedBoots;
            envTools = pkgs.pkgsStatic.callPackage ./pkgs/uboot-env-tools.nix {
              inherit (boardUboot) src version;
            };
          };
          fastboot-flash = pkgs.callPackage ./tests/fastboot-flash.nix {
            inherit sandbox layout;
          };
          flash-from-stock = pkgs.testers.runNixOSTest ./tests/flash-from-stock.nix;
          kernel-config = pkgs.callPackage ./tests/kernel-config.nix {
            inherit (systems.${system}.config.system.build) kernel;
            inherit (systems.${system}.config.nanokvm.ab) fdt;
            h264Encoder = systems.${system}.config.nanokvm.h264Encoder.enable;
          };
          # mixos' test driver needs its Python package from the overlay.
          device = (pkgs.extend mixos.overlays.default).testers.runNixOSTest {
            imports = [
              mixos.lib.nixosTestModule
              (import ./tests/device.nix { diskoLib = disko.lib; })
            ];
          };
        }
      );

      formatter = lib.genAttrs hostSystems (system: (pkgsFor system).nixfmt);
    };
}
