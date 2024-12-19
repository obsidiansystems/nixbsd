{
  inputs = {
    nixpkgs.url = "github:obsidiansystems/bsd-nixpkgs/openbsd-phase1-split";
  };

  nixConfig = {
    extra-substituters = [ "https://obsidian-open-source.s3.us-east-1.amazonaws.com" ];
    extra-trusted-public-keys = [ "obsidian-open-source:KP1UbL7OIibSjFo9/2tiHCYLm/gJMfy8Tim7+7P4o0I=" ];
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      makePkgs =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = f: lib.genAttrs lib.systems.flakeExposed (system: f (makePkgs system));
    in
    rec {
      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
      packages = forAllSystems (pkgs: rec {
        demo = pkgs.callPackage ./demo.nix { };
        default = demo;
      });

      hydraJobs = packages.x86_64-linux;
    };

}
