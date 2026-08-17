{ ... }:
# The virtio-fs variant: keep only what mounts the store in the boot archive,
# and reach the rest over virtio-fs from the host.
#
# Import this alongside any illumos configuration to get the `-virtiofs` form
# of it. It is deliberately one import and nothing else, because "which system
# is this" (base / debug / full) and "where does the store come from" are
# orthogonal, and pairing them by hand produced a configuration named
# `illumos-minimal` that answered both questions at once and neither clearly.
#
# What it buys: the boot archive is a multiboot module, so GRUB copies every
# byte of it into RAM before `unix` is entered and the kernel's ramdisk *is*
# that memory -- there is no demand paging. For the debug configuration that
# took the ISO from 328MB to 46MB.
#
# What it costs: if the mount fails there is very little left to debug with.
# `bootArchive.debugTools` exists so that "very little" is still a shell.
{
  boot.illumos.bootArchive.minimal = true;
}
