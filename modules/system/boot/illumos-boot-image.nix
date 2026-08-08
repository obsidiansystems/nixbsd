{
  config,
  lib,
  pkgs,
  ...
}:

# A bootable illumos image, assembled declaratively.
#
# This is a direct translation of nixpkgs'
# `pkgs/os-specific/illumos/boot-qemu.sh`, which is the only thing that has
# ever actually booted this kernel. Everything it encodes is load-bearing:
#
#   * The boot archive is an old-style ASCII ("odc") cpio -- 070707 magic,
#     octal fields, no leading `/` on member names. That is what
#     common/fs/bootrd_cpio.c reads, and it is one of the four readers
#     dispatched from uts/common/krtld/bootrd.c:47. No bootadm, no UFS image
#     and no lofi are involved.
#   * GRUB2 does not pass the kernel path in the multiboot command line, but
#     uts/i86pc/os/fakebop.c:1694 takes the first word of that line as
#     `boot-file`/`whoami` and krtld opens it as the primary module. Hence the
#     path appearing twice in the `multiboot` line; without the repeat krtld
#     goes looking for a module called `-B`.
#   * `-B console=ttya,input-console=ttya` plus GRUB's own `serial` /
#     `terminal_output` is what gets output onto -serial.
#
# How far it gets, as of this commit: dboot hands over, unix relocates itself,
# krtld links genunix, the banner prints, setup_ddi() finds rootnex and builds
# the devinfo tree root, and then impl_setup_ddi() (i86pc/os/ddi_impl.c:2610)
# panics on `ASSERT(err == 0)` after ndi_devi_bind_driver() for the "ramdisk"
# node -- there is no drv/ramdisk module in the archive, because
# pkgs/os-specific/illumos/pkgs/unix.nix does not list `intel/ramdisk` in its
# `kmods`. The assertion is unconditional in a DEBUG kernel, which this is, so
# the module has to exist. That is the next thing to add there, not here.
#
# The /etc data files are the real ones from the gate
# (uts/intel/os/{name_to_major,name_to_sysnum,minor_perm,driver_classes}).
# driver_aliases and path_to_inst are written by add_drv(8) on a live system,
# so they are empty here.

let
  inherit (lib) mkOption mkIf types;

  isIllumos = pkgs.stdenv.hostPlatform.isIllumos;
  cfg = config.boot.illumos;

  kernel = config.boot.kernel.package;

  # The gate source, for the handful of static /etc tables above. `unix`
  # deliberately does not install them: they are userland data files, not part
  # of the kernel build's $(ROOT).
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

    kernelArgs = mkOption {
      type = types.str;
      default = "-B console=ttya,input-console=ttya";
      description = ''
        Arguments appended to the multiboot command line. Note that
        fakebop.c takes the *first* word of that line as the kernel path, so
        this string must not start with the kernel path itself; the image
        builder prepends it.
      '';
    };
  };

  options.system.build = {
    bootArchive = mkOption {
      type = types.package;
      internal = true;
      description = "The `odc` cpio boot archive handed to the kernel as the rootfs module.";
    };
    illumosImage = mkOption {
      type = types.package;
      internal = true;
      description = "A GRUB2 multiboot rescue ISO holding `unix` and the boot archive.";
    };
  };


  config = mkIf isIllumos {
    # main.c's `init-path` boot property defaults to /sbin/init, and until
    # there is a real root filesystem the boot archive *is* the root, so the
    # binary has to be in here. `system.init` is a placeholder stub -- see the
    # note on that option in system/activation/top-level.nix.
    boot.illumos.bootArchive.extraFiles."sbin/init" =
      lib.mkDefault "${config.system.init}/sbin/init";

    system.build.bootArchive =
      pkgs.runCommand "illumos-boot-archive"
        {
          nativeBuildInputs = [ pkgs.buildPackages.cpio ];
        }
        ''
          mkdir -p ba/etc

          # krtld resolves unix's DT_NEEDED [genunix] out of here, and
          # modload() looks the rest up under kernel/<class>/amd64 and
          # platform/i86pc/kernel/<class>/amd64. The unix derivation already
          # lays its output out that way -- the module Makefiles' own
          # $(ROOTMODULE) rules put them there -- so copy both trees whole.
          # ($out/lib/libgenunix.so is deliberately left out: it is a link-time
          # stub, not a loadable module.)
          cp -RL --no-preserve=mode ${kernel}/kernel ${kernel}/platform ba/

          for f in name_to_sysnum minor_perm driver_classes dacf.conf; do
            cp ${gate}/usr/src/uts/intel/os/$f ba/etc/
          done
          : >ba/etc/driver_aliases
          : >ba/etc/system
          echo '#' >ba/etc/path_to_inst

          # /etc/name_to_major is *not* a source file: uts/intel/os/name_to_major
          # in the gate holds only the four majors that are pinned by ABI (md,
          # devinfo, asy, did). On a real system add_drv(8) appends one line per
          # installed driver at install time, and there is no add_drv here.
          #
          # Without it the very first thing startup_modules() does --
          # setup_ddi() -> getlongprop_buf() for "rootnex" -- panics with
          # "Couldn't find major number for 'rootnex'". So synthesise the file:
          # one entry per driver module actually present in the archive,
          # numbered from 0 upwards, skipping the pinned majors.
          reserved=$(${pkgs.buildPackages.gawk}/bin/awk '!/^#/ && NF == 2 { print $2 }' \
            ${gate}/usr/src/uts/intel/os/name_to_major)
          drivers=$(find ba -path '*/kernel/drv/amd64/*' -type f -printf '%f\n' | sort -u)

          cp ${gate}/usr/src/uts/intel/os/name_to_major ba/etc/name_to_major
          chmod u+w ba/etc/name_to_major
          major=0
          for drv in $drivers; do
            while echo "$reserved" | grep -qx "$major"; do major=$((major + 1)); done
            echo "$drv $major" >>ba/etc/name_to_major
            major=$((major + 1))
          done

          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: path: ''
              mkdir -p "ba/$(dirname ${lib.escapeShellArg name})"
              cp -L ${lib.escapeShellArg path} ba/${lib.escapeShellArg name}
              # cpio -H odc records the mode, and exec_common() will not run a
              # file the mode says is not executable.
              chmod 755 ba/${lib.escapeShellArg name}
            '') cfg.bootArchive.extraFiles
          )}

          chmod -R u+w ba
          ( cd ba && find . -type f | sed 's|^\./||' | sort | cpio -o -H odc ) >$out
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
