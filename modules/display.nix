# Status screen on the NanoKVM's OLED (SSD1306, 128x64, 1 bpp, /dev/fb0):
# nanokvm-oled shows a splash with the project's logo and build revision,
# then hostname, slot and health, IP address, link, SoC temperature, CPU
# utilisation and uptime, drawn straight into the framebuffer.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nanokvm.display;
  oled = pkgs.callPackage ../pkgs/nanokvm-oled {
    inherit (pkgs.buildPackages) spleen;
    inherit (cfg) version;
  };
in
{
  options.nanokvm.display = {
    enable = lib.mkEnableOption "the status screen on the OLED" // {
      default = true;
    };
    version = lib.mkOption {
      type = lib.types.str;
      default = "dev";
      description = "Build identifier shown on the splash screen.";
    };
    brightness = lib.mkOption {
      type = lib.types.ints.between 0 255;
      default = 255;
      description = "OLED contrast, via the ssd1307fb backlight device.";
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [ oled ];
    services.nanokvm-oled.run = pkgs.writeScript "nanokvm-oled-run" ''
      #!/bin/sh
      for bl in /sys/class/backlight/ssd1307fb*/brightness; do
        [ -e "$bl" ] && echo ${toString cfg.brightness} > "$bl"
      done
      exec ${lib.getExe oled} /dev/fb0
    '';
  };
}
