{ ... }:
# The virtio-fs *root*: the host's export is `/`, not just the store.
#
# This is one step further than ./virtiofs-store.nix, and it is a different
# axis from that file's, not a bigger setting of the same one:
#
#   virtiofs-store  the store comes from the host; the ROOT is still the boot
#                   archive ramdisk, which is writable after a remount.
#   virtiofs-root   the ROOT comes from the host too. The ramdisk is still
#                   loaded and still mountable by hand, but nothing mounts it.
#
# It IMPORTS ./virtiofs-store.nix rather than replacing it, and that is worth
# stating because the obvious reading is that a virtio-fs root makes the store
# mount redundant. It does not, for two reasons:
#
#   * The exported root has to be a small tree that virtiofsd can serve at a
#     fixed path, built by `system.build.illumosRootTree`. Making it the whole
#     system closure would mean a second complete copy of the system in the
#     host's store -- gigabytes, rebuilt on every change -- so it carries the
#     `bootArchive.minimal` root set and nothing else. Everything past that
#     still arrives over the `store` share.
#
#   * Something still has to run before userland: /var and /tmp must become
#     tmpfs, devfsadm must populate /dev, soconfig must load the socket
#     mappings. `bootstrap` is that something, and with a virtio-fs root it is
#     literally /sbin/init on the exported tree.
#
# THE WRITABILITY DESIGN, which is the part that had to be settled before any
# of the wiring was worth writing. A virtio-fs export is read-only twice over
# -- virtiofsd is started `--readonly`, and `virtiofs_mountroot()` sets
# VFS_RDONLY with ROOT_REMOUNT a deliberate no-op -- so on this configuration
# the machine has NO writable filesystem at all beyond the tmpfs
# `vfs_mountroot()` puts on /etc/svc/volatile. That is not enough: the SMF
# repository, /var/run, /var/adm/utmpx, /var/svc/log and sshd's host keys all
# need somewhere to go.
#
# The answer is tmpfs on /var and /tmp, mounted by `bootstrap` before it hands
# over. The alternative considered and rejected was the boot archive ramdisk,
# which is still loaded and still a perfectly good UFS filesystem: it is a
# FIXED size chosen at build time, and `boot.illumos.rootfsHeadroom` exists
# because getting that size wrong is how `illumos-full-virtiofs` met
# `NOTICE: alloc: /: file system full` seconds into svc.startd's manifest
# import. tmpfs grows out of the same memory on demand and costs nothing when
# unused. The ramdisk stays unmounted and available at /devices/ramdisk:a,
# which is the right role for it here: the image the machine would otherwise
# have booted from, kept intact for comparison.
{
  imports = [ ./virtiofs-store.nix ];

  boot.illumos.virtiofsRoot.enable = true;

  # /etc is read-only now, and two things in it are not.
  #
  # /etc/dev is already redirected by ./bootstrap.nix, for devfsadm's lock and
  # state directory. /etc/dladm is the same problem one daemon along: dlmgmtd
  # keeps datalink.conf there and rewrites it, and with a read-only /etc it
  # fails at startup, which surfaces as `ifconfig vioif0 plumb` reporting
  # "Interface does not exist" -- a driver-shaped symptom with no driver in it.
  #
  # A symlink rather than a `bootstrap` mkdir, for the reason spelled out on
  # `dirs[]` in ./bootstrap.c: mkdir(2) on a path whose /etc is read-only fails
  # EROFS, and there is no remount available to make it not.
  boot.illumos.bootArchive.symlinks."etc/dladm" = "/etc/svc/volatile/dladm";
}
