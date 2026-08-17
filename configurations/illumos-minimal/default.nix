{ ... }:
# illumos-debug, but with a boot archive holding only what is needed to mount
# the store over virtio-fs.
#
# The archive is a multiboot module: GRUB copies every byte of it into RAM
# before `unix` is entered, and the kernel's ramdisk *is* that memory. There is
# no demand paging and no second chance, so archive size is very nearly the
# whole of boot time. Everything not needed to reach the mount belongs on the
# host's store, not in the image.
#
# Two independent savings compose here:
#
#   * the kernel's DWARF now lives in a separate `debug` output, which took
#     kernel/ + platform/ from ~105MB to 11MB (`genunix` alone was 81MB), and
#     the ISO from 328MB to 129MB on its own;
#   * `bootArchive.minimal` stages only the mount-critical closure -- kernel
#     modules, libc/ld.so.1, init, mountvfs, and the mount bring-up sequence --
#     leaving openssh, ipadm, klog and the rest to be reached over virtio-fs.
#
# The trade, taken deliberately: if the mount fails there is very little left
# to debug with. `bootArchive.debugTools` (bash + coreutils, ~2MB) exists so
# that "very little" is still a shell rather than nothing.
{
  imports = [ ../illumos-debug ];

  boot.illumos.bootArchive.minimal = true;
}
