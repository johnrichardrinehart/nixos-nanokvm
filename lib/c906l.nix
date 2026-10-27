# Memory the 700 MHz C906L ("little" core) works in: the top 8 MiB of DRAM,
# hidden from U-Boot (memoryTopHide) and reserved no-map for Linux, so
# neither ever allocates it. nanokvm-kvm loads the firmware there at runtime
# and copies frames in (pkgs/nanokvm-kvm/c906l/protocol.h has the layout).
rec {
  size = 8 * 1024 * 1024;
  base = 2415919104 - size; # 0x90000000, the end of the 256 MiB DRAM
}
