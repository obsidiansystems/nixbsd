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
# The boot archive is an *iso9660* filesystem image, not an archive format.
# The archive reaches the kernel as a ramdisk whose block device (/ramdisk:a)
# is the loaded multiboot module byte for byte -- nothing unpacks it,
# impl_setup_ddi() (uts/i86pc/os/ddi_impl.c) just hands ramdisk_start /
# ramdisk_end to drv/ramdisk as its "existing" property -- so it has to *be* a
# mountable filesystem. cpio is readable only by krtld's bcpio_ops
# (uts/common/krtld/bootrd.c) and has no entry in uts/common/os/vfs_conf.c, so
# it can never be a root filesystem; the old panic said exactly that ("not a
# UFS magic number (0x394d0000)", 0x394d being "9M", the head of cpio's 070707
# magic). Of the four formats bootadm(8) knows, hsfs is the only one
# synthesisable on a Linux build host: mkfs_ufs is a *target* program, and
# illumos UFS is not interchangeable with BSD FFS1 where it counts -- struct
# direct in uts/common/sys/fs/ufs_fsdir.h has a 16-bit d_namlen exactly where
# FreeBSD's makefs writes a d_type byte plus an 8-bit namlen, so every
# directory entry would be misread.
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
      default = "-B console=ttya,input-console=ttya,fstype=hsfs";
      description = ''
        Arguments appended to the multiboot command line. Note that
        fakebop.c takes the *first* word of that line as the kernel path, so
        this string must not start with the kernel path itself; the image
        builder prepends it. `fstype=hsfs` is what rootconf()
        (common/fs/vfs.c) hands to vfs_mountroot(); it defaults to ufs.
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
    # root filesystem, so the binary has to be in here. `system.init` is a
    # placeholder stub -- see the note on that option in
    # system/activation/top-level.nix.
    boot.illumos.bootArchive.extraFiles."sbin/init" =
      lib.mkDefault "${config.system.init}/sbin/init";

    system.build.bootArchive =
      pkgs.runCommand "illumos-boot-archive"
        {
          nativeBuildInputs = with pkgs.buildPackages; [
            libisoburn
            gawk
          ];
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

          chmod -R u+w ba

          # None of these flags is cosmetic.
          #
          # -R  Rock Ridge. krtld's standalone reader (common/fs/hsfs.c, which
          #     parses SUSP/RRIP) uses it, so every module loaded *before* the
          #     root mount is found under its real lowercase name.
          # -D  do not relocate directories deeper than iso9660's eight-level
          #     limit, which platform/i86pc/kernel/drv/amd64/<drv> is right up
          #     against.
          #
          # After the root mount Rock Ridge is *off*, and this is the trap:
          # hsfs_mountroot() calls hs_mountfs() with mount_flags = 1, and 1 is
          # HSFSMNT_NORRIP (uts/common/sys/fs/hsfs_rrip.h:41). A root hsfs is
          # therefore always read as plain iso9660, so every post-root
          # modload() sees ISO names. hs_dirlook() upper-cases before comparing,
          # so directories are fine ("kernel" finds "KERNEL"), but the default
          # ISO rendering of a file is "CTFS.;1" -- trailing period, version
          # suffix -- which "CTFS" does not match. Hence:
          #
          # -d           omit the trailing period from extensionless names
          # -N           omit the ";1" version suffix
          # -iso-level 2 allow names longer than 8.3, for driver_aliases,
          #              name_to_sysnum, pci_autoconfig and friends
          #
          # Without those three the root mounts, the directory walk works, and
          # then every single modload fails with ENOENT -- which reads like a
          # corrupt filesystem and is really just filename translation.
          xorrisofs -R -D -d -N -iso-level 2 -o $out ba
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
    # builds a partitioned disk image out of `system.build.toplevel`, which
    # needs a userland nixpkgs cannot cross-compile for illumos yet. This boots
    # the kernel and the boot archive alone, which is as far as anything gets
    # today.
    system.build.vm = lib.mkForce (
      pkgs.buildPackages.writeShellScriptBin "run-${config.system.name}-vm" ''
        exec ${pkgs.buildPackages.qemu}/bin/qemu-system-x86_64 \
          -display none -no-reboot \
          -m ${toString (config.virtualisation.memorySize or 4096)} \
          -smp ${toString (config.virtualisation.cores or 1)} \
          -cdrom ${config.system.build.illumosImage} \
          -serial mon:stdio "$@"
      ''
    );
  };
}
