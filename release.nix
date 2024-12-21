let pkgs = import ./nixpkgs {};
in {
  nix = pkgs.pkgsCross.x86_64-openbsd.pkgsStatic.nixVersions.nix_2_24;
  inherit (pkgs.pkgsCross.x86_64-openbsd) tailscale;
}
