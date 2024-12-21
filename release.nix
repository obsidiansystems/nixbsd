let pkgs = import ./nixpkgs { system = "x86_64-linux"; crossSystem.config = "x86_64-openbsd"; };
in {
  nix = pkgs.pkgsStatic.nixVersions.nix_2_24;
  inherit (pkgs) tailscale;
}
