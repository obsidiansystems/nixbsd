{
  config,
  lib,
  pkgs,
  ...
}:
# `bootstrap`, the boot sequence as a program: remount / read-write, make the
# directories, run devfsadm and soconfig, mount the store over virtio-fs, and
# (when the packages for it are staged) bring the network up. Then hand over.
#
# This module INSTALLS it; ./bootstrap-package.nix and ./bootstrap.c are the
# thing itself.
#
# It is a module rather than a few lines in a configuration because the mount
# it performs is what makes `bootArchive.minimal` -- "the store is on the host,
# reach it over virtio-fs" -- true rather than merely asserted. Those two
# halves were split for one commit: ./virtiofs-store.nix set `minimal = true`
# while the mount lived in `configurations/illumos-debug`, so
# `illumos-base-virtiofs` and `illumos-full-virtiofs` threw their userland away
# in exchange for a mount that nothing performed, and booted to a console that
# printed the kernel banner and then nothing whatsoever, for ever. Keeping the
# promise and the code that keeps it in one importable unit is the fix.
#
# Where bootstrap ends up in the chain is `boot.illumos.init.preExec`'s
# business, not this module's -- see modules/system/boot/illumos-boot-image.nix.
# Both shapes matter and both are exercised here:
#
#     kernel -> init-shell (console) -> bootstrap -> bash     (illumos-debug)
#     kernel -> bootstrap -> real /sbin/init                  (base, full)
let
  inherit (lib) mkIf mkOption types;

  cfg = config.boot.illumos;

  p = n: pkgs.illumos.${n} or null;

  # Spelled `or null` and guarded, the convention every other illumos
  # reference in this tree uses: these configurations must still EVALUATE
  # against a nixpkgs whose illumos set has not packaged one of these yet, and
  # `callPackage` would throw on the missing argument rather than return null.
  haveBootstrap = builtins.all (x: x != null) [
    (p "devfsadm")
    (p "soconfig")
  ];

  # The network bring-up is passed only when the packages that perform it are
  # actually staged. Under `bootArchive.minimal` they are not -- they are meant
  # to be reached over the very mount this program performs -- and a store path
  # compiled into the binary is a nix *reference*: naming them there would drag
  # dlmgmtd, ifconfig, setaddr and their libdladm closure into the archive to
  # do nothing at all.
  haveNetwork = builtins.all (x: x != null) [
    (p "dlmgmtd")
    (p "ifconfig")
    (p "setaddr")
  ];

  network =
    if cfg.bootArchive.minimal || !haveNetwork then
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
in
{
  options.boot.illumos.bootstrap.enable = mkOption {
    type = types.bool;
    default = false;
    description = ''
      Run `bootstrap` before userland: remount the root read-write, create the
      directories the rest of the boot needs, run devfsadm and soconfig, and
      mount the host's store over virtio-fs on /mnt/store.

      Required by, and enabled by, `modules/illumos/virtiofs-store.nix`: a
      configuration that drops its userland from the boot archive has nothing
      left to mount the store with unless this runs first.

      Harmless -- and useful -- without it. On a configuration whose store IS
      the boot archive the mount simply fails and says so, and the remaining
      steps are ones every illumos boot here needs anyway.
    '';
  };


  options.boot.illumos.bootstrap.storeMountPoint = mkOption {
    type = types.str;
    default = "/nix/store";
    description = ''
      Where `bootstrap` mounts the host's store.

      /nix/store, and that is not a detail. Everything the boot archive stages
      lives at its REAL store path, because `PT_INTERP` and `DT_RUNPATH` are
      absolute; a store mounted anywhere else resolves none of it. The first
      version of this mounted on /mnt/store, which proved the transport worked
      and ran nothing: `illumos-base-virtiofs` reached its real init(8), which
      then could not exec /sbin/sh, because that symlink points into
      /nix/store and /nix/store was the archive's near-empty copy.

      Mounting over the archive's own /nix/store is safe rather than clever.
      The host directory is a superset of what was staged -- everything in the
      archive was built on the host and is still there under the same path --
      and anything already mapped keeps the mapping it opened.

      Set it elsewhere to look at the transport without letting it take over
      the system's own store.
    '';
  };

  config = mkIf (cfg.bootstrap.enable && haveBootstrap) {
    # The hook the whole design turns on: `preExec` is "a program to run as, or
    # instead of, the thing /sbin/init would have exec'd", given what that
    # thing was so it can hand over to it. So this module never has to know
    # whether the configuration importing it wants bash as pid 1, real init, or
    # real init plus SMF -- it interposes on whatever is there.
    #
    # `callPackage` off the illumos set, so this is built by the same cross
    # compiler, against the same gate headers, as `mountvfs` and the rest.
    boot.illumos.init.preExec =
      next:
      pkgs.illumos.callPackage ./bootstrap-package.nix {
        inherit next network;
        storeDir = cfg.bootstrap.storeMountPoint;
      };

    # The two /etc entries devfsadm needs, which have to be baked into the
    # image because /etc cannot be written to before bootstrap's remount.
    #
    # These moved here from `configurations/illumos-debug` along with the
    # program that needs them, and the move was not cosmetic: without them
    # devfsadm creates NOTHING while still exiting 0, so on the first boot of
    # `illumos-base-virtiofs` the store mounted onto a system with an empty
    # /dev -- and a real init(8) with no /dev/console has nothing to say about
    # it.
    boot.illumos.bootArchive.symlinks = {
      # Break the deadlock between devfsadm and the read-only root.
      #
      # devfsadm keeps its state and its lock in /etc/dev, and refuses to run
      # without them:
      #
      #     devfsadm: mkdir failed for /etc/dev 0x1ed: Read-only file system
      #     devfsadm: open failed for /etc/dev/.devfsadm_dev.lock: No such...
      #
      # which is circular, because the reason we want devfsadm is to create
      # the device nodes the rest of the boot opens by name.
      #
      # It is only the *state* directory that is a problem: the device nodes
      # themselves go into /dev, which is a `dev` filesystem mount and already
      # writable. So point /etc/dev at the kernel's tmpfs on /etc/svc/volatile,
      # the same trick the sshd host keys use. bootstrap.c creates the target
      # -- and creates it by its spelled-out path, because `mkdir -p /etc/dev`
      # follows this link and silently makes nothing.
      "etc/dev" = "/etc/svc/volatile/dev";
    }
    // lib.optionalAttrs (p "devfsadm" != null) {
      # devfsadm reads this from an absolute /etc path, and without it creates
      # nothing at all while still exiting 0:
      #
      #     devfsadm: fopen failed for /etc/devlink.tab: No such file or...
      #
      # devlink.tab is the table mapping /devices nodes to the /dev names to
      # make -- it *is* the rules, so an absent one means an empty /dev rather
      # than an error. Linked from the store rather than copied; the package is
      # in the archive anyway, so this costs only the link.
      #
      # Only devlink.tab. The package also ships etc/dev/reserved_devnames,
      # which cannot be linked here: `etc/dev` is itself the symlink above, and
      # staging a path *under* it would make the archive builder create a real
      # directory there instead. devfsadm does not ask for that file, so it
      # stays unstaged rather than being worked around.
      "etc/devlink.tab" = "${pkgs.illumos.devfsadm}/etc/devlink.tab";
    };
  };
}
