{ ... }:
# DEPRECATED NAME -- use `illumos-debug-virtiofs`.
#
# This was `illumos-debug` plus a virtio-fs store, under a name that described
# neither: "minimal" said nothing about which system it was, nor about where
# the store came from. Those are two independent axes and now have two
# independent spellings.
#
# Kept as an alias only because a boot-profiling run in flight refers to it by
# name. Delete once that lands.
{
  imports = [ ../illumos-debug-virtiofs ];
}
