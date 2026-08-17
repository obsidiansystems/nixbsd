{
  config,
  lib,
  pkgs,
  ...
}:

# A bootable illumos image, assembled declaratively.
#
# This tracks nixpkgs' `pkgs/os-specific/illumos/boot-qemu.sh`, which is the
# scaffolding this replaces. Everything below is load-bearing.
#
# The boot archive is a *filesystem image*, not an archive format. It reaches
# the kernel as a ramdisk whose block device (/ramdisk:a) is the loaded
# multiboot module byte for byte -- nothing unpacks it, impl_setup_ddi()
# (uts/i86pc/os/ddi_impl.c) just hands ramdisk_start / ramdisk_end to
# drv/ramdisk as its "existing" property -- so it has to *be* something
# vfs_mountroot() can mount. cpio is readable only by krtld's bcpio_ops
# (uts/common/krtld/bootrd.c) and has no entry in uts/common/os/vfs_conf.c, so
# it can never be a root filesystem; the old panic said exactly that ("not a
# UFS magic number (0x394d0000)", 0x394d being "9M", the head of cpio's 070707
# magic).
#
# It is UFS now -- see `boot.illumos.rootfs`. It used to have to be hsfs,
# because that was the only one of bootadm(8)'s four formats synthesisable on a
# Linux build host: mkfs_ufs was a target-only program, and illumos UFS is not
# interchangeable with BSD FFS1 where it counts (struct direct in
# uts/common/sys/fs/ufs_fsdir.h has a 16-bit d_namlen exactly where FreeBSD's
# makefs writes a d_type byte plus an 8-bit namlen, so every directory entry
# would be misread). Both halves of that are now fixed: nixpkgs'
# `illumos.mkfs-ufs` builds the gate's own mkfs for the build host, and its
# `-R` option fills the filesystem in, so the format is illumos' by
# construction. hsfs remains available and is still what to fall back to when
# bisecting a boot failure.
#
# What this does *not* yet buy is a writable root. UFS can be written, unlike
# hsfs, but ufs_mountroot() sets VFS_RDONLY for ROOT_INIT
# (uts/common/fs/ufs/ufs_vfsops.c) -- illumos always mounts the root read-only
# and relies on a later `mount -o remount,rw /` (ROOT_REMOUNT), which upstream
# drives from svc:/system/filesystem/root and nothing here does yet. So the
# redirections onto the kernel's tmpfs at /etc/svc/volatile -- sshd's host
# keys, the SMF repository, /tmp -- are still load-bearing. Removing them is
# what the remount unblocks.
#
# GRUB2 does not pass the kernel path in the multiboot command line, but
# uts/i86pc/os/fakebop.c:1694 takes the first word of that line as
# `boot-file`/`whoami` and krtld opens it as the primary module. Hence the path
# appearing twice in the `multiboot` line; without the repeat krtld goes
# looking for a module called `-B`.
#
# qemu can load a multiboot kernel itself -- `-kernel unix -initrd "archive
# type=rootfs"` -- and it is very tempting, because it copies the archive from
# the host at memory speed and skips both GRUB and the emulated boot device:
# measured, `unix` is entered 0.65s after qemu starts instead of 8.8s. It does
# not work, and the reason is worth writing down so nobody spends another
# afternoon on it.
#
# It gets impressively far. whoami comes out right by luck: fakebop takes the
# first word of the command line, and qemu prepends the *host* path of the
# -kernel file, but fakebop then strips everything before "/platform/"
# (fakebop.c:1707) and the kernel derivation lays its output out as
# $out/platform/i86pc/kernel/amd64/unix, so the store path reduces to exactly
# the right thing. dboot finds the module, parses `type=rootfs`, and sets
# ramdisk_start/ramdisk_end. Then vfs_mountroot() says
#
#     NOTICE: mount: not a UFS magic number (0x0)
#
# because the module is not page aligned. qemu loads modules at page-aligned
# *offsets* from the kernel's multiboot load address (hw/i386/multiboot.c:288,
# `mbs.mb_buf_phys = mh_load_addr`), and illumos' load_addr is 0xbffea8 -- the
# ELF headers are 0x158 bytes and the first PT_LOAD sits at 0xc00000, so the
# file as a whole loads 0x158 below a page boundary and every module inherits
# that. GRUB page-aligns modules independently, which is what unix's multiboot
# header asks for and what qemu ignores.
#
# It is fatal rather than cosmetic because ramdisk(4D) addresses its backing
# store by page frame -- `pfn = btop(rsp->rd_existing[i].phys + offset)`,
# uts/common/io/ramdisk.c:478 -- so the low 0xea8 bytes are simply dropped and
# the whole image reads shifted. There is no padding trick: the shift is in the
# physical address of the module, not in its contents. Fixing it means either
# qemu honouring MULTIBOOT_PAGE_ALIGN or illumos linking `unix` so that file
# offset 0 lands on a page, and neither belongs here.
#
# How far this gets: dboot hands over, unix relocates itself, krtld links
# genunix, startup_modules() loads the boot-time modules, setup_ddi() probes
# the buses, vfs_mountroot() mounts hsfs on /ramdisk:a and then devfs, dev,
# ctfs, objfs, bootfs, mntfs, sharefs and tmpfs on top of it, strplumb() runs
# (and reports the one expected failure, drv/dld -- the IP stack is not
# packaged), consconfig() runs, and init is exec'd and executes user
# instructions. `illumos.init-stub` ends in uadmin(A_SHUTDOWN, AD_POWEROFF), so
# qemu powers off and exits after about 11 seconds.
#
# That timing *is* the test, because kernel console output stops after
# consconfig(): consconfig_init_input() calls prom_io_use_kernel(), which
# repoints `sysp` at a cons_polledio that does not reach the emulated 16550,
# so everything past strplumb is silent. Verified by controlled comparison:
# with /sbin/init in the archive qemu exits by itself at 11s; with
# `boot.illumos.bootArchive.extraFiles` forced empty the same image runs until
# the harness kills it at 90s, which is start_init() -> halt() spinning in
# prom_reboot_prompt(). Nothing but a userland uadmin() produces the former.
#
# The /etc data files are the real ones from the gate
# (uts/intel/os/{name_to_sysnum,minor_perm,driver_classes,dacf.conf});
# path_to_inst is written by add_drv(8) on a live system, so it is empty here,
# and name_to_major and driver_aliases are synthesised -- see below.

let
  inherit (lib) mkOption mkIf types;

  isIllumos = pkgs.stdenv.hostPlatform.isIllumos;
  cfg = config.boot.illumos;

  kernel = config.boot.kernel.package;

  # The gate source, for the static /etc tables. `unix` deliberately does not
  # install them: they are userland data files, not part of the kernel build's
  # $(ROOT).
  gate = pkgs.illumos.source;

  # The store paths staged into the archive, resolved on the build machine.
  #
  # `minimal` switches the *root set*; it does not filter the result. A closure
  # is only ever as small as its roots, and `storePaths` is merged from four
  # places (this module, illumos-init, illumos-smf and the configuration), all
  # at `mkDefault` so that they add rather than replace -- which also means
  # nothing can subtract from it. Hence a second, separate list.
  rootPaths =
    if cfg.bootArchive.minimal then
      cfg.bootArchive.minimalStorePaths ++ cfg.bootArchive.debugTools
    else
      cfg.bootArchive.storePaths;
  closure = pkgs.buildPackages.closureInfo { inherit rootPaths; };

  # Guest RAM, in MB. See the note above `system.build.vm`.
  memMB =
    config.virtualisation.memorySize or (if cfg.bootArchive.minimal then 2048 else 6144);
in
{
  options.boot.illumos = {
    bootArchive.extraFiles = mkOption {
      type = types.attrsOf types.path;
      default = { };
      example = lib.literalExpression ''{ "sbin/init" = "''${pkgs.illumos.init}/sbin/init"; }'';
      description = ''
        Extra files to place in the boot archive, keyed by their path inside
        it (no leading slash). The kernel's `init-path` boot property, and
        anything vfs_mountroot() reaches for, has to resolve inside this
        archive until there is a real root filesystem.
      '';
    };

    bootArchive.storePaths = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Store paths whose whole closure is staged into the archive, at their
        real `/nix/store/...` locations -- `PT_INTERP` and `DT_RUNPATH` are
        absolute store paths, so nothing else will do.

        This is only affordable because the root hsfs is now mounted with Rock
        Ridge, so the image carries symlinks and modes: a nix profile stages as
        a symlink farm rather than materialising every link as a copy of its
        target.
      '';
    };

    bootArchive.minimal = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Stage only the mount-critical closure into the archive, and leave
        everything else to be reached over virtio-fs once the guest has
        mounted the host's `/nix/store`.

        Archive size is the largest single term in boot time, and not by a
        little. The archive is a multiboot module, so GRUB copies every byte
        of it into RAM before unix is entered, and the kernel's ramdisk *is*
        that memory -- there is no demand paging and no second chance. It is
        also what sets the guest's memory size: the image has to fit in RAM
        alongside everything else.

        Measured on `illumos-debug`, ISO size, which is what GRUB reads from:

          full closure   582662144 (556MiB)
          minimal        165328896 (158MiB)

        and the boot archive inside it, 569376768 against 152043520. The
        residue is not slack: at 157MiB the archive is almost entirely the
        kernel modules, which have to be there by construction.

        For scale, the timed phases of a whole `illumos-minimal` boot to a
        shell (KVM, one vCPU) after the boot-device and menu changes below:

          qemu + virtiofsd start        0.28s
          GRUB reads the image          1.46s   <- this option
          unix entered -> init exec'd   3.03s   (~1.3s of it is console
                                                 output: 412 kmem_alloc
                                                 warnings at ~3ms each)
          /etc/profile                  0.10s   (devfsadm 42ms, soconfig 8ms,
                                                 mountvfs 3ms -- nothing here)
                                        -----
                                        ~4.9s   (5-6s under host load; the
                                                 kernel phase is what varies)

        So the next real win here is a smaller archive, not a faster loader:
        what remains is 126MB of DEBUG kernel modules staged unconditionally.
        Staging only the ones needed before the virtio-fs mount would be worth
        seconds, and is not done because a hand-picked module list that is
        subtly wrong fails a long way from where it was written.

        The trade is a bootstrap problem, which is the whole reason this is an
        option rather than the default. Whatever performs the mount cannot
        itself come from the mount, so `minimalStorePaths` below has to be a
        closed set: the kernel and its modules, ld.so.1 and libc, the mount
        helper, and the /etc data files those read. Anything missed is not a
        missing-file error at a convenient moment -- it is a machine with no
        store and no way to get one.

        Not the default, and deliberately so: as of writing the guest-side
        virtio-fs mount has never succeeded. The `vtfs` transport driver and
        the `virtiofs` filesystem compile and the qemu device is wired up (see
        `system.build.vm` below), but nothing has yet been read through it. So
        the full-closure path remains what boots.

        Note also that this only pays off once the store is mounted *at
        /nix/store*: everything staged here lives at its real store path
        because `PT_INTERP` and `DT_RUNPATH` are absolute, and a store mounted
        anywhere else resolves none of them. The debug configuration currently
        mounts it at /mnt/store, which is enough to prove the transport works
        and not enough to run anything out of.
      '';
    };

    bootArchive.minimalStorePaths = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        The root set staged into the archive when `minimal` is true, replacing
        `storePaths` entirely.

        This is the closure that has to exist before the store does, so the
        test for membership is not "is it useful" but "is it on the path
        between the kernel entering init and the virtio-fs mount returning".
        The kernel modules are not in here because they are not store paths --
        they are copied out of the `unix` derivation into /kernel and
        /platform by the archive builder, and stay there in either mode.
      '';
    };

    bootArchive.debugTools = mkOption {
      type = types.listOf types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.bash pkgs.coreutils ]";
      description = ''
        Extra packages staged alongside `minimalStorePaths` when `minimal` is
        true, for looking at a machine whose store never arrived.

        Separate from `minimalStorePaths` on purpose. Everything in that list
        is there because boot does not work without it; everything in this one
        is there because *debugging* does not work without it, and the two
        want to be told apart -- otherwise the debugging tail quietly becomes
        load-bearing and nobody can say which half is which.

        The cost of getting this wrong is asymmetric. Carrying a shell costs a
        megabyte against an archive measured in hundreds; carrying none means
        a failed mount leaves nothing to look at, on a machine whose console
        goes silent after consconfig() anyway. So this defaults to non-empty.

        Measured: bash and coreutils together are worth about 2MB of the
        196MiB minimal ISO. That is the whole argument.
      '';
    };

    bootArchive.symlinks = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = lib.literalExpression ''{ bin = "''${config.system.path}/bin"; }'';
      description = ''
        Symbolic links to create in the archive, as target keyed by link path
        (no leading slash). Used to give the staged closure the conventional
        root layout the shell's `PATH` expects.
      '';
    };

    bootArchive.files = mkOption {
      type = types.attrsOf types.lines;
      default = { };
      example = lib.literalExpression ''{ "etc/hosts" = "127.0.0.1 localhost\n"; }'';
      description = ''
        Plain files to write into the archive, as content keyed by path (no
        leading slash).

        Written as real files rather than as symlinks into the store: the
        name-service switch has to work before anything has proved the store
        is reachable, and a real file does not go through Rock Ridge's symlink
        records.
      '';
    };

    bootArchive.mountPoints = mkOption {
      type = types.listOf types.str;
      default = [
        "dev"
        "devices"
        "proc"
        "tmp"
        "system/contract"
        "system/object"
        "system/boot"
        "etc/svc/volatile"
        "etc/dfs"
        "var/run"
        # sshd(8)'s privilege-separation chroot. OpenSSH has no
        # UsePrivilegeSeparation switch any more -- it always separates -- so
        # this directory and the `sshd` user above are both mandatory.
        "var/empty"
        "usr"
      ];
      description = ''
        Directories that must already exist in the archive. vfs_mountroot()
        does not stop at the root: it goes on to mount devfs on /devices, dev
        on /dev, and then ctfs, objfs, bootfs, mntfs, sharefs and tmpfs on the
        rest. hsfs is read-only, so a missing mount point is a "Cannot
        mount ..." warning at boot.
      '';
    };

    driverAliases = mkOption {
      type = types.lines;
      default = ''
        asy "pciclass,0700"
        asy "pci11c1,480"
        isa "pciclass,060100"
        kb8042 "pnpPNP,303"
        mouse8042 "pnpPNP,f03"
        pseudo "zconsnex"
        vioif "pci1af4,1"
        vioif "pci1af4,1000,p"
        vioif "pci1af4,1041,p"
        vioblk "pci1af4,1001"
        vioblk "pci1af4,1042,p"
        vtfs "pci1af4,105a"
      '';
      description = ''
        Contents of `/etc/driver_aliases`. add_drv(8) writes this on a live
        system from the `alias=` attributes on the `driver` actions in the
        packaging manifests; the default here is copied verbatim from the
        gate's pkg/manifests/driver-i86pc-platform.p5m (asy),
        system-kernel.p5m (kb8042, mouse8042, pseudo) and
        system-kernel-platform.p5m (isa). Without the `pseudo zconsnex` line,
        i_ndi_make_spec_children() complains "init_spec_child: parent=pseudo,
        bad spec (zconsnex)" on every boot.

        The virtio entries come from driver-network-vioif.p5m and
        driver-storage-vioblk.p5m the same way, and they matter more than they
        look. A devinfo node whose driver never binds does not appear in devfs
        at all, so without these `/devices/pci@0,0/` contains only `isa@1` --
        the virtio NIC and disk are simply invisible, and it reads like the
        devices are absent rather than merely unbound. That blocks plumbing an
        address and blocks mounting anything off a virtio disk.
      '';
    };

    kernelArgs = mkOption {
      type = types.str;
      default = "-B console=ttya,input-console=ttya,fstype=${cfg.rootfs}";
      defaultText = lib.literalExpression ''
        "-B console=ttya,input-console=ttya,fstype=''${config.boot.illumos.rootfs}"
      '';
      description = ''
        Arguments appended to the multiboot command line. Note that
        fakebop.c takes the *first* word of that line as the kernel path, so
        this string must not start with the kernel path itself; the image
        builder prepends it. `fstype=hsfs` is what rootconf()
        (common/fs/vfs.c) hands to vfs_mountroot(); it defaults to ufs.
      '';
    };

    rootfs = mkOption {
      type = types.enum [
        "hsfs"
        "ufs"
      ];
      default = "ufs";
      description = ''
        The filesystem the boot archive is made as.

        The archive reaches the kernel as a multiboot module and becomes
        /ramdisk:a byte for byte, so it has to *be* a mountable filesystem;
        this chooses which one, and `kernelArgs`' `fstype=` follows it.

        `hsfs` is iso9660, which is what this used before there was any way to
        make a UFS filesystem on a build host. It is read-only by nature, so
        the running system has no writable storage at all beyond the kernel's
        tmpfs on /etc/svc/volatile -- which is why sshd's host keys, the SMF
        repository and /tmp all have to be redirected there by hand.

        `ufs` is a filesystem that *can* be written, made by
        `illumos.mkfs-ufs` (illumos' own mkfs(8) built to run on the build
        host) and filled in by its `-R` option.

        Note "can be": the kernel still mounts the root read-only
        (ufs_mountroot() sets VFS_RDONLY for ROOT_INIT), so until something
        performs the `mount -o remount,rw /` that upstream's
        svc:/system/filesystem/root does, this behaves like hsfs did. The
        difference is that the remount is now possible at all.

        It also costs more memory than hsfs: the archive is a ramdisk, so the
        whole image is loaded at boot, and a UFS image is larger than the
        equivalent ISO.
      '';
    };

  };

  options.system.build = {
    bootArchive = mkOption {
      type = types.package;
      internal = true;
      description = "The iso9660 root filesystem image handed to the kernel as the rootfs module.";
    };
    illumosImage = mkOption {
      type = types.package;
      internal = true;
      description = "A GRUB2 multiboot rescue ISO holding `unix` and the boot archive.";
    };
  };

  config = mkIf isIllumos {
    # main.c's `init-path` boot property defaults to /sbin/init
    # (uts/common/os/main.c:140, zone_initname), and the boot archive is the
    # root filesystem, so the binary has to be in here. See the note on
    # `system.init` in system/activation/top-level.nix.
    boot.illumos.bootArchive.extraFiles."sbin/init" =
      lib.mkDefault "${config.system.init}/sbin/init";

    # The whole system closure, so that the shell init execs -- an ordinary
    # dynamically linked illumos program -- can actually run, along with
    # everything on its `PATH`. `system.init` is listed separately because it
    # is freestanding and so is not reachable from `toplevel`'s references.
    boot.illumos.bootArchive.storePaths = lib.mkDefault (
      [
        config.system.build.toplevel
        config.system.init
      ]
      # The `files` name service backend. It is symlinked into /lib/amd64
      # below, but it also has to be in the closure or the store path the
      # symlink points at is not in the image at all.
      ++ lib.optional (pkgs.illumos.nss-files or null != null) pkgs.illumos.nss-files
    );

    # The `minimal` root set: what has to be in the archive because it is what
    # mounts the store.
    #
    # Written `or null` and filtered, the same convention the init and SMF
    # modules use, so this still evaluates against a nixpkgs that has not
    # packaged one of these yet -- a missing attribute here would be an
    # evaluation error for every illumos configuration, `minimal` or not.
    boot.illumos.bootArchive.minimalStorePaths = lib.mkDefault (
      lib.filter (p: p != null) [
        # init itself. Freestanding, so it is not reachable from anything
        # else's references -- exactly as in `storePaths` above.
        config.system.init

        # ld.so.1 and libc.so.1. /lib/amd64 is a farm of symlinks *into* the
        # store (see the archive builder), so the store path has to be here or
        # every one of those links dangles and nothing dynamically linked runs
        # at all -- which is everything, including the mount helper.
        pkgs.illumos.libc

        # The name service switch backends, dlopen()'d by bare name. Same
        # argument: /lib/amd64/nss_files.so.1 is a symlink into the store.
        (pkgs.illumos.nss-files or null)

        # mount(2) with an explicit fstype: the virtio-fs mount helper. There
        # is no /usr/lib/fs/virtiofs/mount to dispatch to -- virtio-fs has no
        # helper at all -- so this *is* the mount, and without it the archive
        # is minimal for nothing.
        (pkgs.illumos.mountvfs or null)

        # The three that have to run before the mount can be attempted, in
        # order. See the sequence in the debug configuration's /etc/profile:
        # the root is mounted read-only by ufs_mountroot(), sdev's backing
        # store is the root filesystem, so until mount-ufs has remounted it
        # read-write devfsadm cannot create a single node -- and with no nodes
        # there is no device to mount from.
        (pkgs.illumos.mount-ufs or null)
        (pkgs.illumos.devfsadm or null)

        # Socket-to-transport mappings. Not needed by virtio-fs itself, but
        # without them socket(AF_INET, ...) fails at creation, which takes the
        # network with it -- and the network is the only way to get at a
        # machine whose console has gone quiet after consconfig().
        (pkgs.illumos.soconfig or null)
      ]
    );

    # "Break everything, but quickly" is the accepted trade -- but not so
    # quickly that a failed mount leaves nothing to type into. bash is the
    # shell `init-shell` execs and root's shell in /etc/passwd; coreutils is
    # 1.3MB and is the difference between having ls/cat/mount output to read
    # and having only bash builtins. Both together are under 2MB against a
    # minimal archive of 196MiB, so this is chosen rather than tolerated.
    boot.illumos.bootArchive.debugTools = lib.mkDefault [
      pkgs.bash
      pkgs.coreutils
    ];

    # init-shell's compiled-in environment is PATH=/bin:/usr/bin:/sbin, and
    # nothing here runs an activation script to populate /run, so give the
    # staged closure the conventional layout by hand. This is what makes
    # `nixos-version` -- and everything else in `system.path` -- resolve
    # without an absolute store path.
    boot.illumos.bootArchive.symlinks = {
      "bin" = "${config.system.path}/bin";
      "usr/bin" = "${config.system.path}/bin";
      "run/current-system" = "${config.system.build.toplevel}";

      # /dev/null and /dev/zero. Everywhere else in this module devices are
      # named by their /devices path precisely because there is no devfsadm(8)
      # to make the /dev links -- but these two cannot be, because the programs
      # that want them hard-code the name. svc.startd opens /dev/null for every
      # service it starts and refuses to start any without it:
      #
      #     svc.startd: can't connect stdin to /dev/null: No such file or directory
      #
      # after which the console loops on "Console login service(s) cannot run /
      # Requesting System Maintenance Mode".
      #
      # The minor nodes come from mm(4D) (`intel/mm` in nixpkgs' `unix.nix`,
      # declared in common/io/mem.c at 0666), so the link is to devfs and needs
      # no writable /dev -- which matters, since the root is read-only hsfs.
      # devfsadm would make exactly these links; this is the two of them that
      # boot depends on.
      "dev/null" = "/devices/pseudo/mm@0:null";
      "dev/zero" = "/devices/pseudo/mm@0:zero";
    };

    # The name-service switch, and the files it switches to.
    #
    # libc turns every getpwnam()/getgrnam()/gethostbyname() into a dlopen() of
    # a backend named here -- "nss_%s.so.%d", see
    # lib/libc/port/gen/nss_deffinder.c -- and `files` is the only backend
    # packaged. The file has to exist as well as be correct: with no
    # nsswitch.conf at all libc falls back to a compiled-in default naming
    # backends we do not ship, and the lookup then fails in a way that reads as
    # a missing *user* rather than a missing *plugin*.
    #
    # These are `bootArchive.files` rather than `environment.etc` entries on
    # purpose. environment.etc would stage them as symlinks into the store,
    # and name resolution is too far down for that: it has to work before
    # anything has demonstrated the store is readable.
    boot.illumos.bootArchive.files = {
      # Keep the NIC attached once it has attached once.
      #
      # `vioif` binds to the device and `vioif_attach` runs to completion --
      # instance 0 assigned, interrupts enabled, mac_register successful, no
      # diagnostic of any kind:
      #
      #     mac: NOTICE: vioif0 registered
      #     mac: NOTICE: vioif0 unregistered      <- two ticks later
      #
      # The detach is not a failure. Nothing holds a reference, so the DDI
      # reclaims the instance as soon as whatever provoked the attach lets go
      # (a `DINFOFORCE` devinfo snapshot does exactly this: it holds the
      # driver, attaches every instance, snapshots, then releases).
      #
      # That is circular for a NIC being brought up by hand. `dlpi_open()`
      # wants /dev/net/vioif0, falls back to /dev/vioif0, then to style-2
      # /dev/vioif -- and all three need a minor node, which needs the driver
      # attached. On a complete system the thing that holds it is the datalink,
      # but the datalink is created lazily by `dls_devnet_hold_by_name()`,
      # which is the very lookup that cannot complete. So the device attaches,
      # is reclaimed, and every attempt to use it reports:
      #
      #     ifconfig: cannot plumb vioif0: Could not open DLPI link
      #
      # `ddi-forceattach` breaks the cycle the way illumos intends: the driver
      # is attached during boot and is not subject to autodetach. Several
      # in-gate drivers ship exactly this (ehci.conf, ohci.conf, xhci.conf,
      # pcic.conf) for the same reason -- a device that must be present
      # regardless of whether anyone has opened it yet.
      "kernel/drv/vioif.conf" = ''
        ddi-forceattach=1;
      '';

      "etc/nsswitch.conf" = ''
        passwd:     files
        group:      files
        shadow:     files
        hosts:      files
        ipnodes:    files
        networks:   files
        protocols:  files
        rpc:        files
        ethers:     files
        netmasks:   files
        bootparams: files
        publickey:  files
        netgroup:   files
        automount:  files
        aliases:    files
        services:   files
        project:    files
        auth_attr:  files
        prof_attr:  files
        exec_attr:  files
        user_attr:  files
      '';

      # root's shell is the staged closure's bash, reachable as /bin/sh through
      # the `bin` symlink above. uid 0 with home / keeps this independent of
      # whether /root exists in the archive.
      # nsswitch.conf has said `hosts: files` since the beginning, and there
      # has never been a file for it to read. `getipnodebyname()` is how
      # ifconfig turns its argument into an address -- with flags 0, so it
      # goes through the switch rather than parsing numerically first -- and
      # with no backing file it fails even for a literal dotted quad:
      #
      #     ifconfig: 10.0.2.15: bad address
      #
      # which reads as a syntax complaint about an address that is obviously
      # well formed.
      #
      # `loghost` is in the stock file too: syslogd resolves it, and its
      # absence is a boot-time delay rather than an error.
      "etc/hosts" = ''
        ::1             localhost
        127.0.0.1       localhost loghost
      '';

      # ...and the same table again under the name the *other* database uses.
      # netdb.h has two paths, and they are not the same file:
      #
      #     #define _PATH_HOSTS    "/etc/hosts"
      #     #define _PATH_IPNODES  "/etc/inet/ipnodes"
      #
      # `getipnodebyname()` -- which is what ifconfig calls to turn its
      # argument into an address -- resolves through `ipnodes`, not `hosts`.
      # So staging only /etc/hosts fixes the `hosts` database and leaves
      # ifconfig exactly as broken as before.
      #
      # On a stock install these are the same bytes: /etc/inet/hosts is the
      # real file, /etc/hosts is a symlink to it, and ipnodes sits beside it.
      # Written out three times here rather than symlinked, because the
      # archive builder stages plain files and the duplication is four lines.
      "etc/inet/ipnodes" = ''
        ::1             localhost
        127.0.0.1       localhost loghost
      '';

      "etc/inet/hosts" = ''
        ::1             localhost
        127.0.0.1       localhost loghost
      '';

      # Likewise: `netmasks: files` with no file. Only consulted for classful
      # fallback when no netmask is given, but it is one line and it removes
      # the second half of the same failure.
      "etc/netmasks" = ''
        10.0.2.0        255.255.255.0
      '';

      "etc/passwd" = ''
        root:x:0:0:Super-User:/:/bin/sh
        daemon:x:1:1::/:
        bin:x:2:2::/usr/bin:
        sys:x:3:3::/:
        nobody:x:60001:60001:NFS Anonymous Access User:/:
        sshd:x:22:22:sshd privsep:/var/empty:/bin/false
        noaccess:x:60002:60002:No Access User:/:
      '';

      # No hash is invented here: the build host has no crypt(3) producing
      # illumos' $5$ SHA-256 form, so any hash written now would be
      # unverifiable. Password login is impossible by construction, which is
      # the intent -- authentication is by key.
      #
      # root gets `NP`, not `*LK*`, and the distinction is load-bearing.
      # `*LK*` is illumos' *locked account* marker and OpenSSH knows it:
      # configure sets LOCKED_PASSWD_STRING="*LK*" on this platform, and
      # allowed_user() (auth.c) refuses any account whose shadow password
      # equals it -- before ever consulting authorized_keys. A public-key
      # login then fails as nothing more informative than
      #
      #     Permission denied (publickey,password,keyboard-interactive).
      #
      # and only under `sshd -ddd`:
      #
      #     userauth_pubkey: invalid user root querying public key ...
      #     userauth_pubkey: disabled because of invalid user
      #
      # "invalid user" for a user getpwnam() resolves perfectly well --
      # `getent passwd root` returns the entry -- because the check is on the
      # *shadow* entry, not the passwd one.
      #
      # `NP` ("no password") is illumos' marker for an account that cannot be
      # logged into with a password but is not locked. The daemon accounts
      # below already carry it; it leaves key authentication alone.
      "etc/shadow" = ''
        root:NP:::::::
        daemon:NP:::::::
        bin:NP:::::::
        sys:NP:::::::
        sshd:NP:::::::
        nobody:*LK*:::::::
        noaccess:*LK*:::::::
      '';

      "etc/group" = ''
        root::0:
        other::1:
        bin::2:root,daemon
        sys::3:root,bin,adm
        adm::4:root,daemon
        sshd::22:
        nobody::60001:
        noaccess::60002:
      '';

      # RBAC authorisations. Being uid 0 is *not* sufficient on illumos: a
      # privileged operation asks `chkauthattr()`, which looks the caller up by
      # name and reads that name's authorisations out of this file. With no
      # entry, root has no authorisations and the operation is refused --
      #
      #     ifconfig: cannot plumb vioif0: Insufficient user authorizations
      #
      # -- which reads like a permissions bug in the caller and is really a
      # missing database. `solaris.*` plus `solaris.grant` is what a stock
      # illumos install gives root.
      #
      # This is only half of what that check needs; the other half is a
      # working name service switch, since both the uid-to-name lookup and
      # this file's parsing go through it. See the `nss-files` package.
      "etc/user_attr" = ''
        root::::type=normal;auths=solaris.*,solaris.grant;profiles=All;lock_after_retries=no
      '';
    };

    system.build.bootArchive =
      pkgs.runCommand "illumos-boot-archive"
        {
          nativeBuildInputs = with pkgs.buildPackages; [
            libisoburn
            gawk
          ]
          ++ lib.optional (cfg.rootfs == "ufs") pkgs.illumos.mkfs-ufs;
        }
        ''
          mkdir -p ba/etc

          # krtld resolves unix's DT_NEEDED [genunix] out of here, and
          # modload() looks the rest up along kobj's module search path
          # ("/system/boot/kernel /platform/i86pc/kernel /kernel /usr/kernel").
          # The unix derivation already lays its output out that way -- the
          # module Makefiles' own $(ROOTMODULE) rules put them there -- so copy
          # the trees across whole. `usr` matters because a couple of modules
          # install under $(USR_EXEC_DIR) rather than the root one (shbinexec).
          # ($out/lib/libgenunix.so is deliberately left out: it is a link-time
          # stub, not a loadable module. Naming the three trees rather than
          # copying $out whole is the entire mechanism -- there is no explicit
          # exclusion anywhere, so `lib` stays out only for as long as this
          # list does not grow a fourth entry. It is 19MB, measured, which at
          # ramdisk prices is worth a sentence.)
          cp -RL --no-preserve=mode ${kernel}/kernel ${kernel}/platform ${kernel}/usr ba/

          # Fold byte-identical modules together.
          #
          # A handful of modules are installed under more than one name
          # because they are more than one kind of thing: `ip` is both a
          # driver and a STREAMS module, so the gate's Makefiles install the
          # same object at kernel/drv/amd64/ip *and* kernel/strmod/amd64/ip,
          # and icmp/udp/tcp go to three places each (drv, strmod, socketmod).
          #
          # The `unix` derivation already hard-links these to each other, so
          # this is not fixing its packaging -- it is undoing what `cp -RL`
          # does to it. `-L` dereferences, and dereferencing a hard link means
          # writing the bytes again, so a tree that was compact in the store
          # arrives here with every alias materialised. Dropping `-L` is not
          # the fix: it is there so that a symlink in the kernel tree becomes
          # a real file rather than a link into /nix/store, which the archive
          # is not allowed to depend on.
          #
          # Hard links, not symlinks: kobj resolves modules by walking its
          # search path and opening the file it finds, so either would work
          # for the kernel, but a hard link needs no target resolution in the
          # standalone readers and cannot dangle if a tree is ever moved. Both
          # image formats preserve them -- UFS natively, hsfs through Rock
          # Ridge -- which is the same property the staged closure relies on.
          #
          # Measured saving: 4.47MB of tree, 5MiB off the finished UFS image
          # (564133888 against 569376768 bytes). It was ~35MB when this was
          # written, of which `ip` alone was 32.5MB; the modules have since
          # been stripped in nixpkgs and `ip` is now 2.7MB, so most of what
          # this recovered was debug information that no longer exists. The
          # pass is kept because the *ratio* is what it is -- every alias
          # doubles, whatever the modules happen to weigh -- and because it
          # costs one find(1) at build time.
          find ba/kernel ba/platform ba/usr -type f -links 1 -size +64k -print0 \
            | xargs -0 sha256sum \
            | sort \
            | awk '{ h = $1; sub(/^[0-9a-f]+  /, ""); if (h == ph) print pf "\n" $0; else pf = $0; ph = h }' \
            | while read -r first && read -r dup; do
                ln -f "$first" "$dup"
              done

          # `mach` is in this list for a reason worth writing down, because its
          # absence costs a day. It names the platform-support modules
          # psm_modload() will try -- pcplusmp, apix, xpv_psm -- and it is not
          # optional scaffolding: psm_get_impl_module() on its own only ever
          # offers DEFAULT_PSM_MODULE, which is `uppc`, and open_mach_list()
          # (uts/common/os/modsysfile.c) reads this file for everything else.
          #
          # So with no /etc/mach the machine silently comes up on uppc: the
          # plain 8259 fallback, with no I/O APIC. A PCI interrupt then has to
          # be routed through an ACPI PCI link device, whose _SRS method fails
          # under qemu, and every PCI driver's attach(9E) unwinds *after* it
          # has already registered:
          #
          #     uppc: WARNING: psm: set_irq: _SRS failed
          #     mac: NOTICE: vioif0 registered
          #     mac: NOTICE: vioif0 unregistered
          #
          # which leaves the devinfo node bound to its driver but
          # DI_DRIVER_DETACHED -- from userland indistinguishable from a driver
          # that was never built at all. The giveaway is that *every* PCI
          # driver fails identically, which no device-specific explanation
          # covers. The modules themselves were always here; nothing was ever
          # offered the chance to probe them.
          for f in name_to_sysnum minor_perm driver_classes dacf.conf mach; do
            cp ${gate}/usr/src/uts/intel/os/$f ba/etc/
          done
          # /etc/netconfig is the transport-selection table libnsl reads via
          # getnetconfig(3NSL): it maps a name like `tcp` onto a semantics, a
          # protocol family and the STREAMS device to push (/dev/tcp). Anything
          # built on TI-RPC consults it, which for us means the NFS mount
          # helper.
          #
          # Its absence does not look like a missing file. mount(8) resolves
          # `-o proto=tcp` through the NETPATH machinery, finds no netconfig
          # entries at all, and reports
          #
          #     nfs mount: 10.0.2.2: Error in NETPATH.
          #
          # which reads like a routing or server problem and is neither -- no
          # packet is ever sent. Same shape as /etc/mach and /etc/sock2path.d
          # above: a data file the kernel and libraries assume any real install
          # has, invisible until the one subsystem that needs it runs.
          cp ${gate}/usr/src/cmd/netfiles/netconfig ba/etc/netconfig

          # /etc/nfssec.conf is the companion table: it names the RPC security
          # flavours (`sys`, `dh`, `krb5`, ...) and maps them onto their
          # pseudo-flavour numbers. The NFS mount helper calls
          # nfs_getseconfig_default() (cmd/fs.d/nfs/lib/nfs_sec.c) before it
          # can build the mount arguments, even for plain AUTH_SYS, so with the
          # file absent it stops at
          #
          #     nfs mount: error getting default security entry
          #
          # having again sent no packet. This is the file /etc/netconfig
          # uncovered: fixing one revealed the next.
          cp ${gate}/usr/src/cmd/fs.d/nfs/etc/nfssec.conf ba/etc/nfssec.conf

          cp ${pkgs.writeText "driver_aliases" cfg.driverAliases} ba/etc/driver_aliases
          : >ba/etc/system
          : >ba/etc/mnttab
          echo '#' >ba/etc/path_to_inst

          mkdir -p ${lib.concatMapStringsSep " " (d: "ba/${lib.escapeShellArg d}") cfg.bootArchive.mountPoints}
          : >ba/etc/dfs/sharetab

          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (path: text: ''
              mkdir -p "$(dirname ba/${lib.escapeShellArg path})"
              cp ${pkgs.writeText "ba-${builtins.baseNameOf path}" text} ba/${lib.escapeShellArg path}
              chmod u+w ba/${lib.escapeShellArg path}
            '') cfg.bootArchive.files
          )}

          # /etc/name_to_major is *not* a source file: uts/intel/os/name_to_major
          # in the gate holds only the four majors pinned by ABI (md, devinfo,
          # asy, did). On a real system add_drv(8) appends one line per
          # installed driver at install time, and there is no add_drv here.
          #
          # Without it the very first thing startup_modules() does --
          # setup_ddi() -> getlongprop_buf() for "rootnex" -- panics with
          # "Couldn't find major number for 'rootnex'". So synthesise the file:
          # one entry per driver module actually present in the archive,
          # numbered from 0 upwards, skipping the pinned majors.
          reserved=$(awk '!/^#/ && NF == 2 { print $2 }' \
            ${gate}/usr/src/uts/intel/os/name_to_major)
          drivers=$(find ba -path '*/kernel/drv/amd64/*' -type f -printf '%f\n' | sort -u)

          cp ${gate}/usr/src/uts/intel/os/name_to_major ba/etc/name_to_major
          chmod u+w ba/etc/name_to_major
          major=0
          for drv in $drivers; do
            # Skip anything the gate already pins. asy(4D) in particular is
            # both in the source file (major 106) and in the archive, and a
            # duplicate entry loses the driver its major -- which quietly costs
            # the serial console, since consconfig() resolves ttya by
            # ddi_name_to_major("asy").
            if awk -v d="$drv" '!/^#/ && $1 == d { found = 1 } END { exit !found }' \
                 ba/etc/name_to_major; then
              continue
            fi
            while echo "$reserved" | grep -qx "$major"; do major=$((major + 1)); done
            echo "$drv $major" >>ba/etc/name_to_major
            major=$((major + 1))
          done

          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: path: ''
              mkdir -p "ba/$(dirname ${lib.escapeShellArg name})"
              cp -L ${lib.escapeShellArg path} ba/${lib.escapeShellArg name}
              # exec_common() will not run a file whose mode says it is not
              # executable, and store files arrive read-only.
              chmod 755 ba/${lib.escapeShellArg name}
            '') cfg.bootArchive.extraFiles
          )}

          # The system closure, at its real store paths: PT_INTERP and
          # DT_RUNPATH are absolute, so nothing else will do. `cp -a` rather
          # than `cp -RL`: the image carries symlinks either way -- UFS
          # natively, hsfs through Rock Ridge -- so a nix profile stays a
          # symlink farm instead of every link becoming a full copy of its
          # target. That distinction is the whole reason this is affordable at
          # all. `cp -a` also keeps hard links within a store path, which both
          # image formats preserve.
          while read -r p; do
            mkdir -p "ba$(dirname "$p")"
            cp -a "$p" "ba$p"
          done <${closure}/store-paths
          if [ -d ba/nix ]; then chmod -R u+w ba/nix; fi

          # A real illumos root keeps its 64-bit libraries in /lib/amd64, with
          # /lib/64 as the alias. Two things need this and neither goes through
          # a runpath: ld.so.1's SONAME is the absolute string
          # "/lib/amd64/ld.so.1", and libraries like libnsl.so.1 carry no
          # DT_RUNPATH at all and fall back to the default /lib/64 search path.
          mkdir -p ba/lib/amd64
          ln -sfn amd64 ba/lib/64
          for f in ${pkgs.illumos.libc}/lib/*.so.*; do
            [ -e "$f" ] || continue
            ln -sfn "$f" "ba/lib/amd64/$(basename "$f")"
          done
          ln -sfn ${pkgs.illumos.libc}/lib/amd64/ld.so.1 ba/lib/amd64/ld.so.1

          # The name service switch backends, for the same reason and by the
          # same mechanism: libc does not link against them, it `dlopen()`s
          # "nss_<source>.so.1" by bare name once it has read
          # /etc/nsswitch.conf. A bare name means the default search path, so a
          # store path is invisible no matter what is in the closure -- the
          # library has to appear in /lib/amd64 under exactly that name.
          #
          # Without it every `files` lookup fails, and the failures surface
          # far from here: `ifconfig ... plumb` reports "Insufficient user
          # authorizations" while running as root, because the uid-to-name
          # lookup behind chkauthattr() has no backend to answer it.
          ${lib.optionalString (pkgs.illumos.nss-files or null != null) ''
            for f in ${pkgs.illumos.nss-files}/lib/nss_*.so.*; do
              [ -e "$f" ] || continue
              ln -sfn "$f" "ba/lib/amd64/$(basename "$f")"
            done
          ''}

          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: target: ''
              mkdir -p "ba/$(dirname ${lib.escapeShellArg name})"
              ln -sfn ${lib.escapeShellArg target} ba/${lib.escapeShellArg name}
            '') cfg.bootArchive.symlinks
          )}

          chmod -R u+w ba/etc ba/kernel ba/platform

          ${
            if cfg.rootfs == "ufs" then
              ''
                # Size the image from the tree. mkfs needs the file to be its
                # final length up front, since that is what the geometry is
                # derived from, and UFS wants some slack on top of the data:
                # inodes, cylinder group metadata, and each file's tail rounded
                # up to a whole fragment.
                #
                # The slack is NOT free, which is why it is this tight. The
                # archive is a ramdisk -- the whole image is loaded into memory
                # at boot and the loader copies every byte of it first -- so
                # over-sizing costs RAM and boot time directly, at a measured
                # ~43ms per megabyte read off the boot device.
                #
                # This is a search, not a formula, and it is a search because
                # every fixed formula tried so far has been wrong at one end of
                # the range or the other:
                #
                #   * a fifth plus 32MB was far too generous at the small end:
                #     on `illumos-minimal` it turned a 126MB tree into a 183MB
                #     image, 57MB (45%) of nothing, which is ~2.4s of boot;
                #   * a twentieth plus 12MB fixed that (144MB, and minimal
                #     boots) and was too tight at the large end -- both
                #     `illumos-base` (356MB of data, 385MB image) and
                #     `illumos-debug` (422MB, 455MB) died with
                #
                #         mkfs: populate: filesystem is full. Make the image
                #         larger.
                #
                # The reason no single percentage works is that the overhead is
                # not proportional to the data. UFS rounds every file's tail up
                # to a fragment and spends an inode on it, so the waste is
                # roughly constant *per file* -- and a nix store closure is an
                # enormous number of very small files and symlinks, so the
                # per-file term dominates for a big closure and is negligible
                # for a tree that is mostly kernel modules.
                #
                # A per-file term would model that, but it needs a constant
                # too, and the constant would then be the thing that is wrong
                # in the next configuration. So: start from an estimate that
                # includes both terms, and if mkfs says it does not fit, grow
                # and try again. mkfs is loud and non-destructive when it runs
                # out -- it fails the build rather than truncating anything --
                # which is exactly what makes retrying safe.
                #
                # The cost is bounded: a couple of extra mkfs runs at build
                # time, and none at all when the first estimate holds. What it
                # buys is that the image stays as small as it can be, which is
                # boot time and guest RAM directly, at a measured ~43ms per
                # megabyte read off the boot device.
                kb=$(du -sk --apparent-size ba | cut -f1)
                nfiles=$(find ba | wc -l)

                # Data, plus one fragment (1KB) per file for the tails, plus a
                # twentieth for cylinder-group metadata and inode blocks, plus
                # a floor so that a tiny tree still has somewhere to put its
                # superblock.
                mb=$(( (kb + nfiles) / 1024 * 21 / 20 + 8 ))
                echo "boot archive tree is ''${kb}KB in ''${nfiles} files"

                for attempt in 1 2 3 4 5; do
                  echo "making a ''${mb}MB UFS image (attempt $attempt)"
                  rm -f $out
                  truncate -s ''${mb}M $out
                  if mkfs_ufs -F ufs -R ba $out $(( mb * 2048 )); then
                    break
                  fi
                  if [ "$attempt" = 5 ]; then
                    echo "mkfs could not fit the tree in ''${mb}MB after 5 tries" >&2
                    exit 1
                  fi
                  # A fifth at a time: big enough to converge in one or two
                  # steps from any estimate that was merely optimistic, small
                  # enough that converging does not itself waste the space the
                  # search exists to save.
                  mb=$(( mb * 6 / 5 ))
                done
              ''
            else
              ''
                # -R  Rock Ridge: real names, POSIX modes and ownership, and
                #     symbolic links. Both readers use it -- krtld's standalone
                #     one (common/fs/hsfs.c) for everything loaded before the
                #     root mount, and the hsfs module afterwards.
                # -D  do not relocate directories deeper than iso9660's
                #     eight-level limit, which
                #     platform/i86pc/kernel/drv/amd64/<drv> is right up
                #     against, and which /nix/store/<hash>-<name>/... blows
                #     past.
                #
                # Rock Ridge on the *root* needs illumos' `mount the root hsfs
                # with Rock Ridge` patch: hsfs_mountroot() otherwise calls
                # hs_mountfs() with mount_flags = 1, which is HSFSMNT_NORRIP
                # (uts/common/sys/fs/hsfs_rrip.h:41), so a root hsfs is read as
                # plain iso9660 whatever the medium carries. Without that patch
                # this needs `-d -N -iso-level 4` instead -- plain iso9660
                # renders a file called `ctfs` as `CTFS.;1` and caps names well
                # below what a store directory needs -- and even then there are
                # no symlinks and no modes, so staging a closure would mean
                # materialising every symlink as a copy of its target.
                xorrisofs -R -D -o $out ba
              ''
          }
        '';

    system.build.illumosImage =
      pkgs.runCommand "illumos-${config.system.name}.iso"
        {
          nativeBuildInputs = with pkgs.buildPackages; [
            grub2
            libisoburn
            xorriso
          ];
        }
        ''
          mkdir -p iso/boot/grub iso/platform/i86pc/kernel/amd64
          cp ${config.system.build.bootArchive} iso/platform/i86pc/boot_archive
          cp ${kernel}/platform/i86pc/kernel/amd64/unix \
             iso/platform/i86pc/kernel/amd64/unix

          # `timeout=0` boots the single entry immediately. It was 1, which
          # cost a measured 1.07s of every boot -- GRUB spends the whole
          # countdown redrawing the menu over a 115200-baud serial line, so the
          # "1 second" is really the second plus the drawing. There is one
          # menuentry and nothing to choose between, so the menu bought
          # nothing; to get it back for a one-off, edit here or press a key
          # (GRUB still reads stdin, which is why anything piped into the
          # console before the kernel starts is still swallowed).
          cat >iso/boot/grub/grub.cfg <<'EOF'
          serial --unit=0 --speed=115200
          terminal_input serial console
          terminal_output serial console
          set timeout=0
          set default=0
          menuentry "illumos" {
              multiboot /platform/i86pc/kernel/amd64/unix /platform/i86pc/kernel/amd64/unix ${cfg.kernelArgs}
              module /platform/i86pc/boot_archive type=rootfs
              boot
          }
          EOF
          sed -i 's/^          //' iso/boot/grub/grub.cfg

          grub-mkrescue -o $out iso
        '';

    # `mkForce` rather than a `solaris` branch inside qemu-vm.nix: that module
    # builds a partitioned disk image and boots it off a disk controller, and
    # illumos has no packaged boot loader and no devfsadm to create the device
    # nodes one would need. This boots the kernel with the system closure
    # carried in the boot archive instead.
    #
    # The memory default is high because the boot archive is a multiboot
    # module: GRUB loads the whole thing into RAM and the kernel's ramdisk
    # device *is* that memory, so the VM needs the archive's full size on top
    # of everything else.
    #
    # Which is why `minimal` gets a different number rather than one being
    # chosen for both. 6144 was picked when the archive was ~1GB; under
    # `minimal` it is ~145MB and 2048 is measured to be *faster* than 6144
    # (5.86s to the virtio-fs mount against 6.03-6.10s) as well as six times
    # cheaper on the host. 1024 is not: at that size the archive plus the
    # kernel puts the guest under memory pressure and boot goes to ~12s, which
    # is worse than where this started. So this is a floor, not a knob to keep
    # turning down.
    #
    # The full closure still needs the large number and has not been
    # re-measured with it; do not collapse these to one value without booting
    # `illumos-full`.
    system.build.vm = lib.mkForce (
      pkgs.buildPackages.writeShellScriptBin "run-${config.system.name}-vm" ''
        # `accel=kvm:tcg` is qemu's own fallback list: use KVM when /dev/kvm is
        # usable and drop to emulation when it is not, so this stays runnable
        # on hosts without it. It is worth the trouble -- almost all of boot is
        # GRUB copying the boot archive out of the ISO, and under TCG that one
        # phase costs ~71s against ~26s with KVM (76s vs 31s to a shell).
        # `model=virtio-net-pci` rather than qemu's default e1000: the kernel
        # carries both drivers (`intel/vioif` and `intel/e1000g` in nixpkgs'
        # illumos `unix.nix`), but e1000g's attach(9E) unwinds silently after a
        # mac_register() we can see succeed, so vioif is the one with a chance
        # of coming up. Change the model here to test the other path.
        #
        # `hostfwd` forwards the guest's port 22 to a host port, so that once an
        # address is plumbed `ssh -p <port> root@localhost` reaches it.
        #
        # The port is chosen at random rather than fixed at 2222 so that
        # several of these can run at once. A fixed port means the second VM
        # dies at startup with
        #
        #     Could not set up host forwarding rule 'tcp::2222-:22'
        #
        # which produces a ~100-byte log and looks exactly like a boot failure
        # -- it cost three debugging runs before it was recognised. Set
        # $ILLUMOS_SSH_PORT to pin it when you want a predictable number.
        #
        # Freeness is checked against /proc/net/tcp{,6} in pure bash, because
        # this script has no PATH to speak of and pulling in ss(8) or python
        # for one lookup is not worth it. The check is advisory: something else
        # could still take the port in the moment between looking and binding,
        # which is why it retries rather than trusting the first answer.
        port=''${ILLUMOS_SSH_PORT:-}
        if [ -z "$port" ]; then
          for _ in $(seq 1 50); do
            cand=$(( 20000 + RANDOM % 20000 ))
            printf -v hex ':%04X' "$cand"
            inuse=
            while read -r _ local _; do
              case "$local" in *"$hex") inuse=1; break;; esac
            done < <(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null)
            [ -z "$inuse" ] && { port=$cand; break; }
          done
          : "''${port:=2222}"
        fi
        echo "illumos VM: guest ssh port 22 -> localhost:$port" >&2

        # virtio-fs: the host's /nix/store, read-only, as a mountable device.
        #
        # This is what replaces materialising the store into a UFS image per
        # build and copying it into RAM at every boot. NFS cannot do it here:
        # nfs-ganesha's FSAL_VFS reaches files through open_by_handle_at(2),
        # which needs CAP_DAC_READ_SEARCH, checked against the *initial* user
        # namespace -- so a rootless server simply cannot serve, and unshare(1)
        # does not help.
        #
        # virtiofsd meets the same wall and steps around it. Its log says
        #
        #     Failed to open file handle for the root node: Operation not permitted
        #     File handles do not appear safe to use, disabling file handles altogether
        #
        # and then serves happily by path. That graceful degradation, not any
        # difference in privilege, is why this works rootless and NFS does not.
        #
        # Read-only twice over, deliberately: --readonly on the daemon, and the
        # guest cannot write what the daemon will not. The host store must not
        # be mutable from inside the VM.
        #
        # --sandbox none because the namespace sandbox wants privileges we do
        # not have. It is the right call for a throwaway VM reading a store
        # that is already world-readable; it would not be for a real service.
        #
        # --cache metadata is what allows mmap of shared files, and mmap is not
        # optional here: executing an ELF binary maps it rather than reading
        # it, so the store is unusable without it.
        vfsdir=$(mktemp -d)
        trap 'rm -rf "$vfsdir"' EXIT
        ${pkgs.buildPackages.virtiofsd}/bin/virtiofsd \
          --shared-dir /nix/store \
          --socket-path "$vfsdir/vfs.sock" \
          --tag store \
          --readonly \
          --sandbox none \
          --cache metadata \
          >"$vfsdir/virtiofsd.log" 2>&1 &
        vfspid=$!
        trap 'kill $vfspid 2>/dev/null; rm -rf "$vfsdir"' EXIT

        for _ in $(seq 1 50); do
          [ -S "$vfsdir/vfs.sock" ] && break
          sleep 0.1
        done
        echo "illumos VM: virtiofs tag 'store' -> /nix/store (ro)" >&2

        # vhost-user needs the guest's memory to be shareable with the daemon,
        # which plain -m does not give: hence memory-backend-memfd,share=on and
        # a numa node using it. Without this qemu refuses the device outright
        # ("failed to set up shared memory").
        #
        # The boot image is a virtio-blk disk, not `-cdrom`, and that is a
        # measured 3.3s. GRUB reads the whole image through the BIOS before
        # `unix` is entered -- the boot archive is a multiboot module -- so the
        # speed of the emulated boot device is a first-order term in boot time.
        # On `illumos-minimal` (a 183MB image) the same read costs:
        #
        #   -cdrom (SeaBIOS ATAPI)        8.81s
        #   if=ide,media=disk            54.3s   -- do not
        #   virtio-blk-pci,bootindex=0    5.48s
        #   nvme                          never boots (this SeaBIOS has no
        #                                 nvme support; no output at all)
        #
        # `if=virtio` without an explicit `bootindex` also produces no output:
        # SeaBIOS finds nothing to boot and sits there, which reads exactly
        # like a hung kernel. The bootindex is load-bearing.
        #
        # `snapshot=on` because the image is a store path and therefore
        # read-only, and qemu refuses a writable drive it cannot open for
        # write. Nothing writes to it; the overlay is discarded on exit.
        #
        # The cost of this is one spurious warning per boot -- the guest now
        # sees a virtio-blk device and vioblk's attach(9E) fails on it
        # ("Failed to map CAP 2 @ BAR4"). Nothing depends on that device: the
        # root is the ramdisk. If that ever becomes confusing, the honest fix
        # is to make vioblk work, not to go back to the CD.
        exec ${pkgs.buildPackages.qemu}/bin/qemu-system-x86_64 \
          -display none -no-reboot \
          -machine accel=kvm:tcg,memory-backend=mem0 -cpu max \
          -m ${toString memMB} \
          -object memory-backend-memfd,id=mem0,size=${toString memMB}M,share=on \
          -smp ${toString (config.virtualisation.cores or 1)} \
          -nic user,model=virtio-net-pci,hostfwd=tcp::"$port"-:22 \
          -chardev socket,id=vfs0,path="$vfsdir/vfs.sock" \
          -device vhost-user-fs-pci,chardev=vfs0,tag=store \
          -drive file=${config.system.build.illumosImage},format=raw,if=none,id=boot0,snapshot=on \
          -device virtio-blk-pci,drive=boot0,bootindex=0 \
          -serial mon:stdio "$@"
      ''
    );
  };
}
