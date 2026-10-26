# Web KVM: HDMI video, USB keyboard and mouse, ATX buttons (pkgs/nanokvm-kvm).
#
# Listens on localhost by default and has no login of its own: reach it
# through SSH, which already holds the keys that may log in:
#   ssh -L 8080:localhost:8080 root@nanokvm, then http://localhost:8080
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nanokvm.kvm;
  kvm = pkgs.callPackage ../pkgs/nanokvm-kvm { };
  h264 = config.nanokvm.h264Encoder.enable;
  args = [
    "--listen"
    cfg.listenAddress
    "--port"
    (toString cfg.port)
    "--mode"
    cfg.mode
    "--quality"
    (toString cfg.jpegQuality)
    "--max-fps"
    (toString cfg.maxFps)
  ]
  ++ lib.optionals h264 [
    "--h264-bridge"
    (lib.getExe' pkgs.sg2002-h264-bridge "sg2002-h264-bridge")
  ];
in
{
  options.nanokvm.kvm = {
    enable = lib.mkEnableOption "the web KVM" // {
      default = true;
    };
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address the web UI listens on. The UI has no authentication: anyone
        who reaches it controls the target's keyboard, mouse and power.
      '';
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
    };
    mode = lib.mkOption {
      type = lib.types.enum (
        [
          "tiles"
          "mjpeg"
          "mjpeg-half"
        ]
        ++ lib.optional h264 "h264"
      );
      default = "tiles";
      description = "Initial video mode; viewers can switch it in the UI.";
    };
    jpegQuality = lib.mkOption {
      type = lib.types.ints.between 10 95;
      default = 70;
    };
    maxFps = lib.mkOption {
      type = lib.types.ints.between 1 60;
      default = 30;
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [ kvm ] ++ lib.optional h264 pkgs.sg2002-h264-bridge;
    services.nanokvm-kvm.run = pkgs.writeScript "nanokvm-kvm-run" ''
      #!/bin/sh
      # ATX header pads to GPIO: A23 power button, A24 power LED, A25 reset
      # button (pinmux base 0x03001000, function 3).
      devmem 0x0300105c 32 0x3
      devmem 0x03001060 32 0x3
      devmem 0x03001054 32 0x3
      exec ${lib.getExe kvm} ${lib.escapeShellArgs args}
    '';
  };
}
