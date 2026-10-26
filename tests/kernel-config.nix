# Every enabled node of the board's device tree has a driver built into the
# minimal kernel, or is listed here as intentionally unused.
{
  lib,
  runCommand,
  dtc,
  python3,
  writeText,
  kernel,
  fdt,
  h264Encoder,
}:
let
  # compatible -> why a NanoKVM does without it. Everything else enabled in
  # the device tree must have a built-in driver.
  unused = {
    # Codecs, I2S and the microphone belong to the LicheeRV Nano module;
    # NanoKVM firmware ships no audio driver and the product has no audio.
    "sophgo,cv1800b-i2s" = "audio (LicheeRV module microphone/speaker)";
    "sophgo,cv1800b-sound-dac" = "audio";
    "sophgo,cv1800b-sound-adc" = "audio";
    "simple-audio-card" = "audio";
    "sophgo,cv1800b-axi-dma" = "DMA engine only used by audio";
    "sophgo,cv1800b-dmamux" = "DMA routing only used by audio";
    "sophgo,cv1800b-saradc" = "ADC with no NanoKVM function";
    "iio-hwmon" = "hwmon view of that ADC";
    "sophgo,cv1800-pwm" = "PWM with no NanoKVM function";
    "thead,c900-clint" = "M-mode timer owned by OpenSBI; Linux uses the SBI timer";
    "snps,dw-apb-gpio-port" = "ports of the DW GPIO controller, driven by its parent";
    "sipeed,licheerv-nano-bw" = "board root node";
  }
  // lib.optionalAttrs (!h264Encoder) {
    "sophgo,sg2002-coda980" = "H.264 encoder disabled (nanokvm.h264Encoder.enable)";
  };
in
runCommand "nanokvm-kernel-dt-coverage"
  {
    nativeBuildInputs = [
      dtc
      python3
    ];
  }
  ''
    mkdir src
    tar -xf ${kernel.src} -C src --strip-components=1
    ${builtins.concatStringsSep "\n" (map (p: "patch -d src -p1 -s < ${p.patch}") kernel.kernelPatches)}
    if grep '=m$' ${kernel.configfile}; then
      echo "the kernel must not build modules" >&2
      exit 1
    fi
    python3 ${./dt-drivers.py} ${fdt} src ${kernel.configfile} ${writeText "unused.json" (builtins.toJSON unused)}
    touch $out
  ''
