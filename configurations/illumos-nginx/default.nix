{ lib, pkgs, ... }:
{
  imports = [ ../illumos-base/default.nix ];

  # Mirrors ../openbsd-nginx/default.nix. Unlike that one, this configuration
  # cannot boot into anything useful yet: nginx is not cross-compiled for
  # illumos, and the kernel has no working network stack (strplumb fails to
  # initialise drv/dld, so there is no IP). What it *does* do is evaluate and
  # render `svc:/site/nginx` to a service manifest; see
  # `system.build.smfManifests`.
  services.nginx = {
    enable = true;
    virtualHosts."localhost" = {
      default = true;
      root = ./.;
    };
  };
}
