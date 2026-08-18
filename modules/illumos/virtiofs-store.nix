{ ... }:
# The virtio-fs variant: keep only what mounts the store in the boot archive,
# and reach the rest over virtio-fs from the host.
#
# Import this alongside any illumos configuration to get the `-virtiofs` form
# of it: "which system is this" (base / debug / full) and "where does the store
# come from" are orthogonal, and pairing them by hand produced a configuration
# named `illumos-minimal` that answered both questions at once and neither
# clearly.
#
# What it buys: the boot archive is a multiboot module, so GRUB copies every
# byte of it into RAM before `unix` is entered and the kernel's ramdisk *is*
# that memory -- there is no demand paging. For the debug configuration that
# took the ISO from 328MB to 46MB.
#
# What it costs: if the mount fails there is very little left to debug with.
# `bootArchive.debugTools` exists so that "very little" is still a shell.
#
# BOTH HALVES BELONG HERE, and for one commit only one of them did. This file
# was `{ boot.illumos.bootArchive.minimal = true; }` and nothing else, while the
# program that performs the mount lived in `configurations/illumos-debug`. So
# `illumos-debug-virtiofs` worked, and the other two combinations threw their
# userland away in exchange for a mount that nothing performed:
# `illumos-base-virtiofs` reached the kernel banner and then produced nothing
# whatsoever, for as long as it was left running. "The store comes from the
# host" has to mean "and something mounts it" for every configuration that
# imports this, or it is not an axis, it is a trap.
{
  imports = [ ./bootstrap.nix ];

  # Where the store comes from.
  boot.illumos.bootArchive.minimal = true;

  # ...and how it gets here. `bootstrap` interposes itself in front of whatever
  # userland the configuration has -- bash, real init(8), or init(8) plus SMF
  # -- rather than replacing it. See `boot.illumos.init.preExec` in
  # modules/system/boot/illumos-boot-image.nix for how, and for why that is not
  # three special cases.
  boot.illumos.bootstrap.enable = true;
}
