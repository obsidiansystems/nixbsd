{ ... }:
# `illumos-full-virtiofs`, booted by qemu's own multiboot loader rather than
# through SeaBIOS and GRUB.
#
# Third axis, kept independent of the other two (how fancy is the system, and
# where does the store live): how does the VM get `unix` into memory. The ISO
# path is still the default everywhere else, because it is the only one that
# works on an unpatched qemu -- see `boot.illumos.directKernelBoot` in
# ../../modules/system/boot/illumos-boot-image.nix for what the patch is and
# how it fails without it.
{
  imports = [ ../illumos-full-virtiofs ];

  boot.illumos.directKernelBoot = true;
}
