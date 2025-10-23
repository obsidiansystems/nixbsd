{ pkgs, ... }:

{
  imports = [ ../openbsd-base/default.nix ];

  fileSystems."/" = {
    device = "/dev/sd0a";
    fsType = "ffs";
  };
  fileSystems."/boot/efi" = {
    device = "/dev/sd0i";
    fsType = "msdos";
  };

  services.nginx = {
    enable = true;
    virtualHosts."localhost" = {
      default = true;
      root = ./.;
    };
  };
}
