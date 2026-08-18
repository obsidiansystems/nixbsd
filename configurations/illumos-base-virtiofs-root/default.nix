{ ... }:
# `illumos-base`, rooted on virtio-fs: the host's export is `/`.
#
# The bisection point for the virtio-fs root, the same way `illumos-base` is
# for everything else. If this boots and `illumos-full-virtiofs-root` does not,
# the fault is in what `illumos-full` adds -- SMF, sshd, nginx -- and not in
# `virtiofs_mountroot()`, the exported root layout or the tmpfs that replaces
# the writable ramdisk.
#
# `illumos-base-virtiofs` (ramdisk root, store over virtio-fs) is the other
# half of that pair and MUST keep working: a virtio-fs root that fails leaves a
# machine with no writable storage and no shell to look at it with, so being
# able to boot the same system the old way is the only diagnostic there is.
{
  imports = [
    ../illumos-base
    ../../modules/illumos/virtiofs-root.nix
  ];
}
