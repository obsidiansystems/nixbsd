let pkgs = import ./nixpkgs {};
in {
  inherit (pkgs.pkgsCross.x86_64-openbsd.openbsd) sys stand;
}
