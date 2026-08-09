# Mirror of ../freebsd/config-data-path.nix for SMF: sets the path of
# `configData` entries and exposes per-service metadata (data directory,
# service account name).
let
  setPathsModule =
    prefix:
    { lib, name, ... }:
    let
      inherit (lib) mkOption types;
      servicePrefix = "${prefix}${name}";
    in
    {
      _class = "service";
      options = {
        smf.meta = mkOption {
          readOnly = true;
          default = {
            dataDir = "/var/lib/system-services/${servicePrefix}";
            username = "m-${servicePrefix}";
            inherit servicePrefix;
          };
        };
        configData = mkOption {
          type = types.lazyAttrsOf (
            types.submodule (
              { config, ... }:
              {
                config = {
                  path = lib.mkDefault "/etc/system-services/${servicePrefix}/${config.name}";
                };
              }
            )
          );
        };
        services = mkOption {
          type = types.attrsOf (
            types.submoduleWith {
              modules = [
                (setPathsModule "${servicePrefix}-")
              ];
            }
          );
        };
      };
    };
in
setPathsModule ""
