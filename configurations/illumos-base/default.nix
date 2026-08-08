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
  services.tempfiles.useDefaultSpecs = false;
  services.tempfiles.specs = [ ];
  security.sudo.enable = false;
  services.sshd.enable = false;

  users.users.root.initialPassword = "toor";

  fileSystems."/" = {
    device = "/dev/dsk/c0t0d0s0";
    fsType = "ufs";
  };

  # `system.build.illumosImage` / `system.build.vm` -- see
  # modules/system/boot/illumos-boot-image.nix -- build and boot today.
  # `system.build.toplevel` does not, and will not for a long while: it wants
  # bash, coreutils, curl, git and nix cross-compiled for illumos, and nixpkgs
  # has libc and the kernel and nothing else.
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
