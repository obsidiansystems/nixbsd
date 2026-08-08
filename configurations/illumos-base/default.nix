{
  config,
  lib,
  pkgs,
  ...
}:
{
  nixpkgs.hostPlatform = "x86_64-unknown-solaris2.11";

  # PLACEHOLDER: there is no illumos kernel package (`unix`) in nixpkgs yet, so
  # nothing here is buildable end-to-end. `pkgs.illumos.sys` is only the
  # uts/common/sys headers. Everything below exists so the module tree
  # evaluates and so the plumbing is in place the moment `unix` lands.
  boot.kernel.enable = false;

  # The illumos boot loader (usr/src/boot, a FreeBSD loader fork) is not
  # packaged either; see modules/system/boot/loader/stand-illumos.
  boot.loader.stand-illumos.enable = false;

  users.users.root.initialPassword = "toor";

  fileSystems."/" = {
    device = "/dev/dsk/c0t0d0s0";
    fsType = "ufs";
  };

  virtualisation.vmVariant = {
    virtualisation.diskImage = "./${config.system.name}.qcow2";
    # dboot_startkern.c calls bcons_init() before anything else, so a serial
    # console gives output from the very first line of kernel C code. Nothing
    # boots yet, but this is the shape the VM target should have.
    virtualisation.graphics = false;
  };

  documentation.enable = false;
  documentation.man.man-db.enable = false;
  programs.bash.completion.enable = false;
  xdg.mime.enable = false;
}
