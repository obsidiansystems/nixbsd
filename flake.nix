{
  inputs = {
    nixpkgs.url = "github:obsidiansystems/bsd-nixpkgs/openbsd-phase1-split";
  };

  nixConfig = {
    extra-substituters = [ "https://nixcache.reflex-frp.org" ];
    extra-trusted-public-keys = [ "ryantrinkle.com-1:JJiAKaRv9mWgpVAz8dwewnZe0AzzEAzPkagE9SP5NWI=" ];
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
