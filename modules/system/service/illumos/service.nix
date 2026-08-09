{
  lib,
  config,
  ...
}:
# Mirror of ../freebsd/service.nix: teaches NixOS modular services how to
# render themselves as SMF services.
let
  inherit (lib)
    mkOption
    types
    ;
in
{
  _class = "service";
  imports = [
    (lib.mkAliasOptionModule [ "smf" "service" ] [ "smf" "services" "" ])
  ];
  options = {
    smf.mainCommand = mkOption {
      description = ''
        Command to run for the main program.

        It should execute as a foreground process: the generated service has
        `duration = "child"`, so svc.startd itself waits on the start method
        and treats its exit as the service stopping. There is no equivalent of
        FreeBSD's {manpage}`daemon(3)` wrapper to add, and none is wanted.
      '';
      type = types.listOf types.str;
      default = config.process.argv;
      defaultText = lib.literalExpression "config.process.argv";
    };

    smf.services = mkOption {
      description = ''
        This option configures `smf.services`, with the notable difference that
        the service names will be prefixed with the abstract service name.

        This option's value is not suitable for reading, but you can define a
        module here that interacts with just the service configuration in the
        host system configuration.

        Note that this option contains _deferred_ modules. This means that the
        module has not been combined with the system configuration yet, so no
        values can be read from this option.
      '';
      type = types.lazyAttrsOf (types.deferredModuleWith { staticModules = [ ]; });
      default = { };
    };

    # Also import the SMF logic into sub-services; extends the portable
    # `services` option.
    services = mkOption {
      type = types.attrsOf (
        types.submoduleWith {
          class = "service";
          modules = [
            ./service.nix
          ];
        }
      );
      # Rendered by the portable docs instead.
      visible = false;
    };
  };
  config = {
    # Note that this is the smf.services option above, not the system one.
    smf.services."" = {
      duration = "child";
      methodContext = {
        user = config.smf.meta.username;
        workingDirectory = config.smf.meta.dataDir;
      };
      execMethods.start = {
        exec = lib.escapeShellArgs config.smf.mainCommand;
        # A "child" service's start method does not return while the service
        # runs, so a start timeout would be a kill switch. 0 means no timeout.
        timeoutSeconds = 0;
      };
      execMethods.stop = {
        exec = ":kill";
        timeoutSeconds = 60;
      };
      dependents.multi-user = {
        grouping = "optional_all";
        restartOn = "none";
        fmris = [ "svc:/milestone/multi-user" ];
      };
    };
  };
}
