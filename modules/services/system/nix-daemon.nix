/*
  Declares what makes the nix-daemon work on systemd.

  See also
   - nixos/modules/config/nix.nix: the nix.conf
   - nixos/modules/config/nix-remote-build.nix: the nix.conf
*/
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let

  cfg = config.nix;

  nixPackage = cfg.package.out;

  isNixAtLeast = versionAtLeast (getVersion nixPackage);

  makeNixBuildUser = nr: {
    name = "nixbld${toString nr}";
    value = {
      description = "Nix build user ${toString nr}";

      /*
        For consistency with the setgid(2), setuid(2), and setgroups(2)
        calls in `libstore/build.cc', don't add any supplementary group
        here except "nixbld".
      */
      uid = builtins.add config.ids.uids.nixbld nr;
      isSystemUser = true;
      group = "nixbld";
      extraGroups = [ "nixbld" ];
    };
  };

  nixbldUsers = listToAttrs (map makeNixBuildUser (range 1 cfg.nrBuildUsers));

in
{
  ###### interface

  options = {

    nix = {

      # nix.enable, nix.package and nix.nrBuildUsers are no longer declared
      # here: upstream's nixos/modules/config/nix.nix, which nixbsd imports,
      # now declares all three itself, and two declarations of the same option
      # are an error. Only envVars below is nixbsd's own.

      # Environment variables for running Nix.
      envVars = mkOption {
        type = types.attrs;
        internal = true;
        default = { };
        description = "Environment variables used by Nix.";
      };
    };
  };

  ###### implementation

  config = mkIf cfg.enable (mkMerge [
    {
      environment.systemPackages = [
        nixPackage
        pkgs.nix-info
        pkgs.gitMinimal
      ]
      ++ optional (config.programs.bash.completion.enable) pkgs.nix-bash-completions;

      services.tempfiles.specs = [
        {
          root = "/nix/var/nix";
          extraFlags = [
            "-d"
            "-e"
            "-U"
          ];
          text = ".\n\tdaemon-socket type=dir uname=root gname=root mode=0755";
        }
      ];

      # Set up the environment variables for running Nix.
      environment.sessionVariables = cfg.envVars;

      # Legacy configuration conversion.
      nix.settings.sandbox-fallback = false;
      nix.settings.sandbox-paths = [ "/bin/sh=${lib.getExe pkgs.pkgsStatic.bash}" ];

    }
    (mkIf (!config.boot.isJail) {
      init.services.nix-daemon = {
        description = "nix daemon for a multi-user store";
        dependencies = [
          "FILESYSTEMS"
          "tempfiles"
        ];

        path = with pkgs; [ nixPackage ] ++ optionals cfg.distributedBuilds [ gzip ];
        environment = cfg.envVars // {
          CURL_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
        };

        startType = "foreground";
        startCommand = [ "${nixPackage}/bin/nix-daemon" ];

        # THIS IS A HACK
        preStop = ''
          kill -INT $(cat ''${pidfile-/dev/null}) &>/dev/null || true
        '';

      };
      nix.nrBuildUsers = mkDefault (
        if cfg.settings.auto-allocate-uids or false then
          0
        else
          max 32 (if cfg.settings.max-jobs == "auto" then 0 else cfg.settings.max-jobs)
      );

      users.users = nixbldUsers;
    })
  ]);
}
