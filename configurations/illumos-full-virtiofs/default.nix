{ ... }:
# `illumos-full`, with the store reached over virtio-fs instead of baked into
# the boot archive.
#
# Two independent axes, kept independent:
#
#   how fancy is the system      illumos-base / illumos-debug / illumos-full
#   where does the store live    in the boot archive, or on the host over
#                                virtio-fs (../../modules/illumos/virtiofs-store.nix)
#
# so each combination is one import of each, and neither has to know about the
# other. The earlier `illumos-minimal` answered both questions at once under a
# name that described neither.
{
  imports = [
    ../illumos-full
    ../../modules/illumos/virtiofs-store.nix
  ];
}
