{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ../illumos-base

    # `bootstrap`: the remount, the mkdirs, devfsadm, soconfig, the virtio-fs
    # mount and the network bring-up, as a program rather than a shell profile.
    #
    # It used to live in THIS directory, and moving it to modules/illumos was
    # not tidying. While it lived here, only the configurations that import
    # this one performed the mount -- so `illumos-base-virtiofs`, which imports
    # `modules/illumos/virtiofs-store.nix` and not this file, threw its
    # userland out of the boot archive in exchange for a store nothing reached,
    # and booted to the kernel banner and then silence.
    ../../modules/illumos/bootstrap.nix
  ];

  # Run it here too, not only under `-virtiofs`. Nothing about the remount,
  # devfsadm, soconfig or the network bring-up is virtio-fs specific: they are
  # what takes this configuration from an exec'd shell to a machine with a
  # populated /dev and an address, and they have always run here. The one step
  # that does nothing without a virtio-fs store is the mount, which says so on
  # the console and carries on.
  boot.illumos.bootstrap.enable = true;

  # A shell as pid 1, on top of the *minimal* configuration -- and the one and
  # only reason bash is in this configuration's boot archive, as a `debugTools`
  # shell rather than a mount-critical one.
  #
  # This exists to make the edit-boot-look cycle cheap. `illumos-full` stages
  # nix, perl, curl, openssh and the rest, which comes to a ~1.3GB boot
  # archive; since the archive is a multiboot module, GRUB copies every byte of
  # it into RAM before the kernel starts, so each look at the system costs a
  # long rebuild *and* a long boot. `illumos-base` carries bash and coreutils
  # and little else, which is all that is needed to poke at a device node, run
  # a mount, or read /etc/mnttab.
  #
  # `illumos-full` has `boot.illumos.smf.debugShell` for the same purpose, and
  # since that option now sets this one, both routes produce the same chain.
  #
  # That chain is
  #
  #     kernel -> init-shell (console) -> bootstrap (the steps) -> bash
  #
  # and nothing before the last arrow is a shell. Building it -- in particular
  # the shim around init-shell, which BAKES IN `-DPROG=<pkg>/bin/bash`, so that
  # handing it `bootstrap` compiles in a nonexistent <bootstrap>/bin/bash and
  # init reports only "init: exec failed" before powering the machine off --
  # is illumos-boot-image.nix's job now, not this file's.
  #
  # Drive it non-interactively by piping into qemu's serial console -- but
  # delay the input, because GRUB reads stdin at its menu prompt and will
  # swallow anything sent before the kernel starts:
  #
  #     { sleep 60; printf 'ls -l /devices/pseudo/\n'; sleep 20; } \
  #       | run-nixbsd-illumos-debug-vm
  boot.illumos.init.shellProgram = pkgs.bashInteractive;

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
  boot.illumos.bootArchive.storePaths = lib.mkDefault (
    lib.filter (p: p != null) [
      # The init chain itself -- init-shell's compiled-in program, and through
      # it bootstrap -- is no longer named here. illumos-boot-image.nix stages
      # it, because it is what builds it, and the reason it has to be a *root*
      # rather than merely referenced is written down there: /sbin/init is staged
      # with `extraFiles`, which COPIES a file, and a copied file's references
      # are not followed.

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

      # mount -F nfs, for serving /nix/store from the host read-only instead of
      # baking a UFS image per build and copying it into RAM per boot.
      #
      # Kept, though virtio-fs has taken over that job: the NFS client works and
      # will mount from any *privileged* server. What it cannot do is our case --
      # nfs-ganesha rootless -- because FSAL_VFS needs CAP_DAC_READ_SEARCH for
      # open_by_handle_at(2) and treats losing it as fatal.
      (pkgs.illumos.mount-nfs or null)

      # mount(2) with an explicit fstype. Needed because illumos' mount(8) is a
      # dispatcher that execs /usr/lib/fs/<fstype>/mount, we do not package the
      # dispatcher, and virtio-fs has no helper at all -- so without this there
      # is no way to issue the mount, however well the kernel side works. The
      # first virtio-fs boot proved the point by failing at
      #
      #     bash: mount: command not found
      #
      # with the modules loaded and the device attached.
      (pkgs.illumos.mountvfs or null)

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
    ]
  );

  # `bootArchive.minimalStorePaths` needs nothing from this file. It used to
  # need `initProg`, the init chain's compiled-in program, and that one entry
  # was the whole reason `illumos-debug-virtiofs` booted while the other two
  # `-virtiofs` configurations did not: the mount lived in a list that only
  # this configuration declared. illumos-boot-image.nix adds it to both root
  # sets now, for every configuration, as part of building the chain.
  #
  # Everything bootstrap execs (devfsadm, soconfig) is already in the module's
  # minimal list, as are the two mount helpers it replaces -- mount-ufs and
  # mountvfs -- which stay staged for use by hand.

  # What is left of /etc/profile: a PATH, and nothing else.
  #
  # The boot sequence that used to live here is now ./bootstrap.c, exec'd by
  # init before the shell ever starts -- see the top of this file. This
  # remains only because bash reads it and a prompt with no PATH is miserable
  # to type at, and it is deliberately inert: if it never runs, if a package
  # in it is missing, if the whole file is absent, the machine still boots and
  # still mounts its store. That was not true a commit ago, when this file WAS
  # the boot sequence and a "command not found" in it took /mnt/store with it.
  #
  # `grep`, `sed` and friends are NOT in coreutils -- they are their own
  # packages -- so they need naming. Three separate probes have reported
  # "command not found" for `grep` and read as system failures when they were
  # the probe's own. Under `bootArchive.minimal` these are not staged at all
  # (they are not `debugTools`), so the entries simply do not resolve, which is
  # the correct cost for a convenience.
  boot.illumos.bootArchive.files."etc/profile" = ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.bash}/bin:${pkgs.gnugrep}/bin:${pkgs.gnused}/bin:$PATH
  '';
}
