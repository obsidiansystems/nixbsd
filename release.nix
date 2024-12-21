let pkgs = import ./nixpkgs { system = "x86_64-linux"; crossSystem.config = "x86_64-openbsd"; };
in {
  inherit (pkgs.openbsd) sys stand;
}
