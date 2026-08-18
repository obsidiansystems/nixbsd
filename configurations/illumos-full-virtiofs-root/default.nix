{ ... }:
# `illumos-full`, rooted on virtio-fs.
#
# The three axes stay independent, which is why this file is four lines: how
# fancy the system is (base/debug/full), where the store comes from
# (../../modules/illumos/virtiofs-store.nix), and what `/` itself is
# (../../modules/illumos/virtiofs-root.nix, which imports the store module
# because the root export deliberately carries only the mount-critical set).
#
# This is the configuration with something to prove: SMF, sshd and nginx all
# write, and on a read-only root every one of those writes lands on the tmpfs
# that ../../modules/illumos/virtiofs-root.nix mounts on /var. The
# ramdisk-rooted `illumos-full-virtiofs` is the control.
{
  imports = [
    ../illumos-full
    ../../modules/illumos/virtiofs-root.nix
  ];
}
