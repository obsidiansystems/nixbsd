{
  lib,
  pkgs,
  ...
}:
{
  imports = [ ../illumos-base ];

  # A shell as pid 1, on top of the *minimal* configuration.
  #
  # This exists to make the edit-boot-look cycle cheap. `illumos-full` stages
  # nix, perl, curl, openssh and the rest, which comes to a ~1.3GB boot
  # archive; since the archive is a multiboot module, GRUB copies every byte of
  # it into RAM before the kernel starts, so each look at the system costs a
  # long rebuild *and* a long boot. `illumos-base` carries bash and coreutils
  # and little else, which is all that is needed to poke at a device node, run
  # a mount, or read /etc/mnttab.
  #
  # `illumos-full` has `boot.illumos.smf.debugShell` for the same purpose, but
  # that option lives in the SMF module and base does not run SMF, so force the
  # init path directly. The effect is the same: /sbin/init is a shell, and
  # every step that the real init or the SMF bootstrap would have taken can be
  # run by hand and its output read.
  #
  # Drive it non-interactively by piping into qemu's serial console -- but
  # delay the input, because GRUB reads stdin at its menu prompt and will
  # swallow anything sent before the kernel starts:
  #
  #     { sleep 60; printf 'ls -l /devices/pseudo/\n'; sleep 20; } \
  #       | run-nixbsd-illumos-debug-vm
  boot.illumos.bootArchive.extraFiles."sbin/init" = lib.mkForce "${pkgs.illumos.init-shell}/sbin/init";

  # The things under investigation, staged so they can be run by hand from the
  # shell above. `storePaths` rather than `environment.systemPackages` because
  # with a bare shell as init there is no profile and no PATH to speak of;
  # these get staged at their real store paths and are invoked in full.
  #
  # Spelled `or null` and filtered, so this configuration still evaluates
  # against a nixpkgs that has not packaged one of them yet -- the same
  # convention the SMF and init modules use.
  # `mkDefault`, and it matters. The init and SMF modules both declare
  # `storePaths` with `lib.mkDefault`, and a normal-priority definition here
  # would not add to those lists -- it would *discard* them, because the module
  # system keeps only the highest-priority definitions of an option and drops
  # the rest. The result is a boot archive holding /sbin/init but not the libc
  # and ld.so.1 it needs, which the kernel reports as the memorably terse:
  #
  #     init: starting shell on the console
  #     init: exec failed
  #
  # Declaring this at the same priority lets all three lists merge.
  boot.illumos.bootArchive.storePaths = lib.mkDefault (lib.filter (p: p != null) [
    # Populates /dev. Without it there is no /dev/dsk, no /dev/rdsk, and no
    # link for the ramdisk, which is why mount(8) has had nothing to open.
    (pkgs.illumos.devfsadm or null)

    # mount(8) for ufs, to remount the root read-write.
    (pkgs.illumos.mount-ufs or null)

    # Assigns an address. qemu's SLIRP hands out fixed ones: guest 10.0.2.15,
    # host 10.0.2.2, /24.
    (pkgs.illumos.ifconfig or null)
  ]);

  # Break the deadlock between devfsadm and the read-only root.
  #
  # devfsadm keeps its state and its lock in /etc/dev, and refuses to run
  # without them:
  #
  #     devfsadm: mkdir failed for /etc/dev 0x1ed: Read-only file system
  #     devfsadm: open failed for /etc/dev/.devfsadm_dev.lock: No such file...
  #
  # which is circular, because the reason we want devfsadm is to create the
  # device node that mount(8) needs to remount the root read-write.
  #
  # It is only the *state* directory that is a problem: the device nodes
  # themselves go into /dev, which is a `dev` filesystem mount and already
  # writable. So point /etc/dev at the kernel's tmpfs on /etc/svc/volatile,
  # the same trick the sshd host keys use. The symlink has to be baked into
  # the image, since /etc itself cannot be written to at run time.
  #
  # Whatever runs devfsadm must create the target directory first -- there is
  # no init here to do it, so the probe does it by hand.
  boot.illumos.bootArchive.symlinks = {
    "etc/dev" = "/etc/svc/volatile/dev";
  }
  // lib.optionalAttrs (pkgs.illumos.devfsadm or null != null) {
    # devfsadm reads these from absolute /etc paths, and without the first it
    # creates nothing at all while still exiting 0:
    #
    #     devfsadm: fopen failed for /etc/devlink.tab: No such file or directory
    #
    # devlink.tab is the table mapping /devices nodes to the /dev names to
    # make -- it *is* the rules, so an absent one means an empty /dev rather
    # than an error. Linked from the store rather than copied; the package is
    # in the archive anyway, so this costs only the link.
    #
    # Only devlink.tab. The package also ships etc/dev/reserved_devnames, but
    # it cannot be linked here: `etc/dev` is itself the symlink above, and
    # staging a path *under* it would make the archive builder create a real
    # directory there instead. devfsadm does not ask for that file, so it
    # stays unstaged rather than being worked around.
    "etc/devlink.tab" = "${pkgs.illumos.devfsadm}/etc/devlink.tab";
  };
}
