{
  inputs = {
    nixpkgs.url = "github:obsidiansystems/bsd-nixpkgs/a846fa7e092552e9e7636233f118d5f61a97dc82";
    utils.url = "github:numtide/flake-utils";
    nix = {
      url = "github:rhelmot/nix/freebsd-staging";
      inputs.nixpkgs.follows = "nixpkgs";
      # We don't need another nixpkgs clone, it won't evaluate anyway
      inputs.nixpkgs-regression.follows = "nixpkgs";
    };
    mini-tmpfiles = {
      url = "github:nixos-bsd/mini-tmpfiles";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.utils.follows = "utils";
    };
  };

  nixConfig = {
    extra-substituters = [ "https://nixcache.reflex-frp.org" ];
    extra-trusted-public-keys = [ "ryantrinkle.com-1:JJiAKaRv9mWgpVAz8dwewnZe0AzzEAzPkagE9SP5NWI=" ];
  };

  outputs = { self, nixpkgs, utils, nix, mini-tmpfiles }:
    let
      inherit (nixpkgs) lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-freebsd" ];
      configBase = ./configurations;
      makeSystem = name: module:
        self.lib.nixbsdSystem {
          modules = [ module {  } ];
        };
      allSystems = (utils.lib.eachSystem supportedSystems (system:
        let
          makeImage = conf:
            let
              extended = conf.extendModules {
                modules = [{ config.nixpkgs.buildPlatform = system; }];
              };
            in extended.config.system.build // {
              # appease `nix flake show`
              type = "derivation";
              name = "system-build";

              closureInfo = extended.pkgs.closureInfo {
                rootPaths = [ extended.config.system.build.toplevel.drvPath ];
              };
              vmClosureInfo = extended.pkgs.closureInfo {
                rootPaths = [ extended.config.system.build.vm.drvPath ];
              };
              inherit (extended) pkgs;
            };
          pkgs = import nixpkgs { inherit system; };
        in {
          packages = lib.mapAttrs'
            (name: value: lib.nameValuePair "${name}" (makeImage value))
            self.nixosConfigurations;

          formatter = pkgs.nixfmt;
        }));
    in {
      lib.nixbsdSystem = args:
        import ./lib/eval-config.nix (args // {
          inherit (nixpkgs) lib;
          nixpkgsPath = nixpkgs.outPath;
          specialArgs = {
            nixFlake = nix;
            mini-tmpfiles-flake = mini-tmpfiles;
          } // (args.specialArgs or { });
        } // lib.optionalAttrs (!args ? system) { system = null; });

      nixosConfigurations =
        lib.mapAttrs (name: _: makeSystem name (configBase + "/${name}"))
          (builtins.readDir configBase);

      hydraJobs = allSystems.packages.x86_64-linux.base.vm;
    } // allSystems;
}
