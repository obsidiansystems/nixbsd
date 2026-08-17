{
  config,
  lib,
  pkgs,
  ...
}:
let
  p = n: pkgs.illumos.${n} or null;

  # The boot sequence, as a program: ./bootstrap.c does the remount, the
  # mkdirs, devfsadm, soconfig and the virtio-fs mount, checking every one, and
  # then execs the shell.
  #
  # It lives here rather than in nixpkgs' illumos set because it is policy, not
  # mechanism -- see the header comment in ./bootstrap.nix. `callPackage` off
  # that set so it is built by the same cross compiler, against the same gate
  # headers, as `mountvfs` and the rest.
  #
  # This used to be the /etc/profile below, and moving it out of the shell was
  # not tidying. It changes two things:
  #
  #   * bash and coreutils stop being BOOT dependencies. Nothing on the path
  #     from the kernel exec'ing init to the store being mounted is a shell
  #     command any more; the shell is the thing that runs AFTER, and it is
  #     staged as `bootArchive.debugTools`, which is the option that exists to
  #     say precisely that. A failed mount still lands on a usable prompt.
  #
  #   * failures stop being invisible. A non-interactive profile continues
  #     past every error without a word -- that is how a missing `mkdir
  #     -p /mnt/store` presented as a virtio-fs bug -- and `set -e` would only
  #     have made it stop without a word. Each step now names itself and its
  #     errno on the console.
  #
  # The network bring-up is passed only when the packages that perform it are
  # actually staged. Under `bootArchive.minimal` they are not (they are meant
  # to be reached over the very mount this program performs), and a store path
  # compiled into the binary is a nix *reference*: naming them there would drag
  # dlmgmtd, ifconfig, setaddr and their libdladm closure into the archive to
  # do nothing at all.
  haveNetwork = builtins.all (x: x != null) [
    (p "dlmgmtd")
    (p "ifconfig")
    (p "setaddr")
  ];

  # Guarded the same way every other illumos reference in this file is: the
  # configuration must still evaluate against a nixpkgs whose illumos set has
  # not packaged devfsadm or soconfig yet, and `callPackage` would throw on the
  # missing argument rather than return null.
  haveBootstrap = builtins.all (x: x != null) [
    (p "devfsadm")
    (p "soconfig")
    (p "init-shell")
  ];

  bootstrapPkg =
    if !haveBootstrap then
      null
    else
      pkgs.illumos.callPackage ./bootstrap.nix {
      # The shell to hand the console to when the sequence is done. This is
      # the one and only reason bash appears in this configuration's boot
      # archive -- and it is a `debugTools` shell, not a mount-critical one.
      shell = pkgs.bashInteractive;

      network =
        if config.boot.illumos.bootArchive.minimal || !haveNetwork then
          null
        else
          {
            inherit (pkgs.illumos) dlmgmtd ifconfig setaddr;
            # qemu's SLIRP hands out fixed addresses: guest 10.0.2.15, host
            # 10.0.2.2, /24.
            interface = "vioif0";
            address = "10.0.2.15";
            netmask = "255.255.255.0";
          };
      };

  # `init-shell` is an /sbin/init that sets the console up -- session, ldterm,
  # termios -- and then execs one compiled-in program. Its argument is named
  # `bashInteractive` because that program used to be bash; here it is
  # `bootstrap`, which does the boot sequence and *then* execs bash itself. So
  # the chain is
  #
  #     kernel -> init (console) -> bootstrap (the six steps) -> bash
  #
  # and nothing before the last arrow is a shell.
  #
  # The shim exists because init-shell.nix does not merely take a package, it
  # bakes in a PATH:
  #
  #     -DPROG='"${bashInteractive}/bin/bash"'
  #
  # so overriding the argument with `bootstrap` compiles in
  # <bootstrap>/bin/bash, which does not exist -- and init reports that as the
  # single unhelpful line "init: exec failed", with the machine then powering
  # itself off. (Asked, answered, and cost one boot.) Rather than change the
  # nixpkgs package -- init-shell is general-purpose, and "what to exec" is
  # this configuration's business -- give it a directory whose `bin/bash` is
  # the program we actually want.
  initProg =
    if bootstrapPkg == null then
      null
    else
      pkgs.runCommandLocal "illumos-init-prog" { } ''
        mkdir -p $out/bin
        ln -s ${lib.getExe bootstrapPkg} $out/bin/bash
      '';

  initShell =
    if initProg == null then
      p "init-shell"
    else
      (p "init-shell").override { bashInteractive = initProg; };
in
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
  boot.illumos.bootArchive.extraFiles."sbin/init" = lib.mkForce "${initShell}/sbin/init";

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
    # The boot sequence itself. It has to be a *root*, not merely referenced:
    # /sbin/init is staged with `extraFiles`, which copies a file, and a copied
    # file's references are not followed. Without this the archive holds an
    # init whose compiled-in program does not exist -- which the kernel reports
    # as the memorably terse "init: exec failed".
    initProg

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
  ]);

  # And the same root under `bootArchive.minimal`, which replaces `storePaths`
  # wholesale rather than filtering it (see the archive builder). `mkDefault`
  # for the same merge reason as above: the module declares this list at that
  # priority, and a normal-priority definition here would discard it -- leaving
  # a minimal archive with no libc.
  #
  # This is the *only* addition minimal needs. Everything bootstrap execs
  # (devfsadm, soconfig) is already in that list, and the two mount helpers it
  # replaces -- mount-ufs and mountvfs -- are still there for use by hand.
  boot.illumos.bootArchive.minimalStorePaths = lib.mkDefault (
    lib.filter (x: x != null) [ initProg ]
  );

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
