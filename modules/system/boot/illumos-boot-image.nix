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
  closure = pkgs.buildPackages.closureInfo { rootPaths = cfg.bootArchive.storePaths; };
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
    boot.illumos.bootArchive.storePaths = lib.mkDefault [
      config.system.build.toplevel
      config.system.init
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
      "etc/passwd" = ''
        root:x:0:0:Super-User:/:/bin/sh
        daemon:x:1:1::/:
        bin:x:2:2::/usr/bin:
        sys:x:3:3::/:
        nobody:x:60001:60001:NFS Anonymous Access User:/:
        noaccess:x:60002:60002:No Access User:/:
      '';

      # `*LK*` is illumos' locked-account marker. No hash is invented here:
      # nothing consumes /etc/shadow yet -- login(1) is not packaged and sshd
      # is not reachable without a network stack -- and the build host has no
      # crypt(3) producing illumos' $5$ SHA-256 form, so any hash written now
      # would be unverifiable.
      "etc/shadow" = ''
        root:*LK*:::::::
        daemon:NP:::::::
        bin:NP:::::::
        sys:NP:::::::
        nobody:*LK*:::::::
        noaccess:*LK*:::::::
      '';

      "etc/group" = ''
        root::0:
        other::1:
        bin::2:root,daemon
        sys::3:root,bin,adm
        adm::4:root,daemon
        nobody::60001:
        noaccess::60002:
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
          # stub, not a loadable module.)
          cp -RL --no-preserve=mode ${kernel}/kernel ${kernel}/platform ${kernel}/usr ba/

          for f in name_to_sysnum minor_perm driver_classes dacf.conf; do
            cp ${gate}/usr/src/uts/intel/os/$f ba/etc/
          done
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
                # at boot and GRUB copies every byte of it first -- so
                # over-sizing costs RAM and boot time directly. Measured
                # overhead on the current tree is about 8% (a 1.11GB tree left
                # 493MB free in a 1.7GB image), so a fifth plus 32MB leaves a
                # comfortable margin without doubling the memory footprint.
                kb=$(du -sk --apparent-size ba | cut -f1)
                mb=$(( kb / 1024 * 6 / 5 + 32 ))
                echo "boot archive tree is ''${kb}KB; making a ''${mb}MB UFS image"

                truncate -s ''${mb}M $out
                mkfs_ufs -F ufs -R ba $out $(( mb * 2048 ))
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

          cat >iso/boot/grub/grub.cfg <<'EOF'
          serial --unit=0 --speed=115200
          terminal_input serial console
          terminal_output serial console
          set timeout=1
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
        # `hostfwd` puts the guest's port 22 on localhost:2222, so that once an
        # address is plumbed `ssh -p 2222 root@localhost` reaches it. Nothing
        # plumbs one yet: `ifconfig` links libdladm and libipadm, neither of
        # which is packaged, so this is the host half of a path whose guest
        # half is still missing.
        exec ${pkgs.buildPackages.qemu}/bin/qemu-system-x86_64 \
          -display none -no-reboot \
          -machine accel=kvm:tcg -cpu max \
          -m ${toString (config.virtualisation.memorySize or 6144)} \
          -smp ${toString (config.virtualisation.cores or 1)} \
          -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22 \
          -cdrom ${config.system.build.illumosImage} \
          -serial mon:stdio "$@"
      ''
    );
  };
}
