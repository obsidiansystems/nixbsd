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

  # The network bring-up sequence, written down because the ordering is not
  # guessable and every step was found the hard way. With everything below
  # staged, this is what takes a booted machine to a plumbed interface:
  #
  #   mount -o remount,rw /devices/ramdisk:a /   # sdev's backing store is the
  #                                             # root fs; without this
  #                                             # devfsadm cannot create nodes
  #                                             # and /etc is unwritable
  #   mkdir -p /etc/svc/volatile/dev /etc/dladm  # devfsadm's lock lives behind
  #                                             # the /etc/dev symlink below;
  #                                             # `mkdir -p /etc/dev` does NOT
  #                                             # create it, it follows the link
  #   devfsadm                                  # populates /dev
  #   soconfig -d <pkg>/etc/sock2path.d         # or socket(AF_INET) = EAFNOSUPPORT
  #   cp <pkg>/share/dlmgmtd/datalink.conf /etc/dladm/
  #   SMF_FMRI=svc:/network/datalink-management:default dlmgmtd   # or -d
  #   ifconfig vioif0 plumb
  #
  # The NIC itself needs no coaxing: with the `net_dacf` kernel module built,
  # it attaches during boot and stays attached, and /dev/net/vioif0 exists
  # before any of this runs. Without that module every step above still
  # "succeeds" and the plumb fails with "Could not open DLPI link".
  #
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

    # Walks the devinfo tree and prints each node's driver binding and
    # state. devfs hides unattached nodes, so this is the only way from
    # userland to tell "device absent" from "driver bound, attach failed".
    (pkgs.illumos.ditree or null)

    # Prints the kernel messages. illumos has no dmesg(1) that works without
    # syslogd: cmn_err(9F) output goes to the console driver and to log(4D),
    # and log(4D) holds everything printed before a console logger registers.
    # Nothing here registers, so the early boot messages -- including whatever
    # a failing attach(9E) printed -- exist but are unread. Pair it with
    # `ditree`, which forces an attach, to catch the failure as it happens:
    #
    #     klog -t 5 > /tmp/k.out &
    #     ditree
    #     wait; cat /tmp/k.out
    (pkgs.illumos.klog or null)

    # Loads the socket-to-transport mappings into sockfs. Without it every
    # AF_INET socket fails at creation -- `ifconfig -a` cannot even open one,
    # before naming any interface -- so nothing about networking is testable
    # and the failure looks like a driver problem. Must run *after* devfsadm,
    # since some mappings name /dev entries devfsadm creates:
    #
    #     soconfig -d <this package>/etc/sock2path.d
    (pkgs.illumos.soconfig or null)

    # The modern IP configuration tool. `ifconfig` is staged too, but it cannot
    # parse an address here -- it resolves even a literal dotted quad through
    # the name service switch, and the hosts lookup is broken. ipadm goes
    # through getaddrinfo(), which parses numerics directly:
    #
    #     ipadm create-addr -T static -a 10.0.2.15/24 vioif0/v4
    (pkgs.illumos.ipadm or null)

    # Last resort for putting an address on the interface: both ifconfig and
    # ipadm fail before reaching the kernel (name service switch, and address
    # objects, respectively). This does the three ioctls directly.
    (pkgs.illumos.setaddr or null)

    # sshd, the actual objective. nixpkgs builds openssh with `withPAM`
    # defaulting to `isLinux`, so this is a *non*-PAM build: it authenticates
    # against /etc/shadow through getpwnam/getspnam, which is why nss-files
    # had to work first.
    (pkgs.openssh or null)

    # The datalink management daemon. libdladm asks it, over a door, for every
    # datalink question; with no daemon there is no door, and ifconfig (via
    # libipadm) fails before doing anything:
    #
    #     ifconfig: unable to open handle to libipadm: Datalink does not exist
    #
    # It needs a *writable* /etc/dladm/datalink.conf, so the probe has to copy
    # the seed out of the package's share/ rather than link it.
    #
    # And it will not start from a shell without help. dlmgmt_init() does:
    #
    #     if ((fmri = getenv("SMF_FMRI")) == NULL) {
    #             dlmgmt_log(LOG_ERR, "dlmgmtd is an smf(7) managed service
    #                 and should not be run from the command line.");
    #             return (EINVAL);
    #     }
    #
    # -- it derives its cache file name from the FMRI. So invoke it as either
    #
    #     SMF_FMRI=svc:/network/datalink-management:default dlmgmtd
    #     dlmgmtd -d      # skips the check, stays in foreground, .debug.cache
    #
    # Getting this wrong is expensive to notice: `dlmgmt_log` goes to syslog
    # unless `-d` is given, nothing here reads syslog, and the daemon exits 1
    # with no output at all. It looks exactly like a daemon that started fine,
    # and every downstream symptom ("Datalink does not exist", "Could not open
    # DLPI link") is consistent with a *running* dlmgmtd that simply has no
    # links -- so the failure hides behind plausible errors one layer up.
    (pkgs.illumos.dlmgmtd or null)
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
