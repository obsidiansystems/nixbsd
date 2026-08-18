{
  config,
  lib,
  pkgs,
  ...
}:
{
  nixpkgs.hostPlatform = "x86_64-unknown-solaris2.11";

  # illumos must be cross-compiled: unlike the BSDs, nixpkgs has no native
  # illumos stdenv bootstrap, so letting buildPlatform default to hostPlatform
  # sends the bootstrap into an infinite recursion (bashInteractive -> bison ->
  # help2man -> gettext -> bash) long before any derivation is produced.
  # mkDefault so the cross entry points in flake.nix, which set buildPlatform
  # themselves, still win.
  nixpkgs.buildPlatform = lib.mkDefault "x86_64-linux";

  # `pkgs.illumos.unix` is the cross-built i86pc kernel. It boots as far as
  # module loading today; see pkgs/os-specific/illumos/boot-qemu.sh in nixpkgs.
  boot.kernel.enable = true;

  # The illumos boot loader (usr/src/boot, a FreeBSD loader fork) is not
  # packaged; we multiboot the kernel from GRUB instead, exactly as
  # boot-qemu.sh does.
  boot.loader.stand-illumos.enable = false;

  # PLACEHOLDER: nixpkgs packages no illumos userland at all -- no login,
  # passwd, su, syslogd, devd, mtree, sysctl, mount helpers, rc scripts. Every
  # module below defaults to a FreeBSD (or OpenBSD) binary, which is not merely
  # unbuildable here, it fails `meta.platforms` at *evaluation* time. Turn them
  # off until there is something illumos-native to point them at.
  programs.passwd.enable = false;
  programs.su.enable = false;
  services.devd.enable = false;
  # mini-tmpfiles has no illumos build, and its `meta.platforms` refuses to
  # evaluate rather than merely failing to build.
  services.tempfiles.enable = false;
  services.tempfiles.useDefaultSpecs = false;
  services.tempfiles.specs = [ ];
  security.sudo.enable = false;
  services.sshd.enable = false;

  # `system.build.toplevel` otherwise drags in bash, coreutils, curl, git, nix,
  # dhcpcd, fcron, nano and fontconfig, all cross-compiled for illumos. Almost
  # none of that builds yet, and waiting for all of it keeps the toplevel path
  # unreachable indefinitely. Cut it to the smallest set that could plausibly
  # work, so `toplevel` becomes reachable when a handful of packages land
  # rather than when the whole tree does. With this, `system.build.toplevel`
  # *evaluates*; building it is still gated on the userland port.
  #
  # `coreutils` and not `coreutils-full`: the latter links openssl, and
  # openssl's target table (pkgs/development/libraries/openssl/default.nix)
  # keys on `hostPlatform.system`, where it has `x86_64-solaris` but not
  # `x86_64-solaris2.11`, so it throws "Not sure what configuration to use"
  # during evaluation.
  environment.requiredPackages = lib.mkForce [
    pkgs.bashInteractive
    pkgs.coreutils
  ];
  environment.defaultPackages = lib.mkForce [ ];
  networking.dhcpcd.enable = false;
  networking.useDHCP = false;
  nix.enable = false;
  services.fcron.enable = false;
  fonts.fontconfig.enable = false;

  fileSystems."/" = {
    device = "/dev/dsk/c0t0d0s0";
    fsType = "ufs";
  };

  # `system.build.illumosImage` / `system.build.vm` -- see
  # modules/system/boot/illumos-boot-image.nix -- build and boot today.
  # They boot to user mode: init is exec'd and runs. `system.build.toplevel`
  # evaluates but does not build yet -- it still wants `bashInteractive` and
  # `coreutils` cross-compiled for illumos.
  virtualisation.vmVariant = {
    virtualisation.diskImage = "./${config.system.name}.qcow2";
    # dboot_startkern.c calls bcons_init() before anything else, so a serial
    # console gives output from the very first line of kernel C code.
    virtualisation.graphics = false;
  };

  documentation.enable = false;
  documentation.man.man-db.enable = false;
  programs.bash.completion.enable = false;
  xdg.mime.enable = false;
}
