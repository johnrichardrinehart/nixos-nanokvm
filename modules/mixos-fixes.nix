# Fixes to mixos itself, until they are upstream. Imported by the board and
# the device VM test, so the test runs the same init.
{ options, ... }:
{
  # mixos mounts the new root as a tmpfs without a mode, so / is 1777
  # (world-writable); dropbear then rejects every authorized key.
  mixos.package = options.mixos.package.default.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ../patches/mixos-root-tmpfs-mode-0755.patch ];
  });
}
