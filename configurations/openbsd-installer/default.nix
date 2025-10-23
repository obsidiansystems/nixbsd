{ pkgs, ... }:

{
  imports = [ ../openbsd-base/default.nix ];

  nixpkgs.buildPlatform = "x86_64-linux";
  nix.settings.trusted-users = [ "demo" ];
  environment.systemPackages = [ pkgs.openssh ];
}
