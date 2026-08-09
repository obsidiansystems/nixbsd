{
  lib,
  config,
  options,
  pkgs,
  ...
}:
# Mirror of ../freebsd/system.nix: exposes `system.services` (NixOS modular
# services) and lowers them onto `smf.services`.
let
  inherit (lib)
    concatMapAttrs
    mkOption
    types
    concatLists
    mapAttrsToList
    ;

  portable-lib = import "${pkgs.path}/lib/services/lib.nix" { inherit lib; };

  dash =
    before: after:
    if after == "" then
      before
    else if before == "" then
      after
    else
      "${before}-${after}";

  makeEtcFiles =
    prefix: service:
    let
      serviceConfigData = lib.mapAttrs' (name: cfg: {
        name =
          # cfg.path is read only and prefixed with unique service name; see ./config-data-path.nix
          assert lib.hasPrefix "/etc/system-services" cfg.path;
          lib.removePrefix "/etc/" cfg.path;
        value = {
          inherit (cfg) enable source;
        };
      }) (service.configData or { });

      subServiceConfigData = concatMapAttrs (
        subServiceName: subService: makeEtcFiles (dash prefix subServiceName) subService
      ) service.services;
    in
    serviceConfigData // subServiceConfigData;

  # Modular services land in the `site/` FMRI namespace, which is the one
  # reserved for services not delivered by illumos itself.
  makeServices =
    prefix: service:
    concatMapAttrs (serviceName: serviceModule: {
      "site/${dash prefix serviceName}" =
        { ... }:
        {
          imports = [ serviceModule ];
        };
    }) service.smf.services
    // concatMapAttrs (
      subServiceName: subService: makeServices (dash prefix subServiceName) subService
    ) service.services;

  makeUsers =
    _: service:
    {
      "${service.smf.meta.username}" = {
        group = service.smf.meta.username;
        home = service.smf.meta.dataDir;
        createHome = true;
        isSystemUser = true;
      };
    }
    // (concatMapAttrs makeUsers service.services);

  makeGroups =
    _: service:
    {
      "${service.smf.meta.username}" = { };
    }
    // (concatMapAttrs makeGroups service.services);

  modularServiceConfiguration = portable-lib.configure {
    serviceManagerPkgs = pkgs;
    extraRootModules = [
      ./service.nix
      ./config-data-path.nix
    ];
  };
in
{
  _class = "nixos";

  options = {
    system.services = mkOption {
      description = ''
        A collection of NixOS [modular services](https://nixos.org/manual/nixos/unstable/#modular-services)
        that are configured as SMF services.
      '';
      type = types.attrsOf modularServiceConfiguration.serviceSubmodule;
      default = { };
      visible = "shallow";
    };
  };

  config = {
    assertions = concatLists (
      mapAttrsToList (
        name: cfg: portable-lib.getAssertions (options.system.services.loc ++ [ name ]) cfg
      ) config.system.services
    );

    warnings = concatLists (
      mapAttrsToList (
        name: cfg: portable-lib.getWarnings (options.system.services.loc ++ [ name ]) cfg
      ) config.system.services
    );

    # As in the FreeBSD equivalent, the attribute name of the modular service
    # is passed as the prefix, so `system.services.foo` with a sub-service
    # `bar` yields `site/foo` and `site/foo-bar`.
    smf.services = concatMapAttrs makeServices config.system.services;

    environment.etc = concatMapAttrs makeEtcFiles config.system.services;

    users.users = concatMapAttrs makeUsers config.system.services;

    users.groups = concatMapAttrs makeGroups config.system.services;

    # NOTE: the FreeBSD equivalent also declares a tmpfiles rule creating
    # /var/lib/system-services. illumos has no tmpfiles implementation here and
    # `services.tempfiles` is off in configurations/illumos-base, so each
    # service's dataDir must be created by hand for now.
  };
}
