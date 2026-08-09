# This module generates nixos-install, nixos-rebuild,
# nixos-generate-config, etc.

{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  tools = pkgs.callPackages ./package.nix {
    nix = config.nix.package.out;
    nixosVersion = config.system.nixos.version;
    # Defaults to null in package.nix, and a null substitution leaves the
    # literal `@codeName@` in the output -- which is what `nixos-version`
    # printed.
    nixosCodeName = config.system.nixos.codeName;
    nixosRevision = config.system.nixos.revision;
    configurationRevision = config.system.configurationRevision;
  };
in
{

  options.system.disableInstallerTools = mkOption {
    internal = true;
    type = types.bool;
    default = false;
    description = ''
      Disable nixos-rebuild, nixos-generate-config, nixos-installer
      and other NixOS tools. This is useful to shrink embedded,
      read-only systems which are not expected to be rebuild or
      reconfigure themselves. Use at your own risk!
    '';
  };

  config = lib.mkMerge [
    (lib.mkIf (config.nix.enable && !config.system.disableInstallerTools) {
      environment.systemPackages = with tools; [
        nixos-install
        nixos-rebuild
        nixos-enter
      ];
    })

    # `nixos-version` is not gated on `nix.enable`, unlike the three above: it
    # is a shell script that prints strings substituted in at build time and
    # never invokes nix. Excluding it from a system built without nix -- which
    # is how a port with no nix of its own has to start out -- costs the most
    # basic "what am I running" command for no reason.
    (lib.mkIf (!config.system.disableInstallerTools) {
      environment.systemPackages = [ tools.nixos-version ];
    })

    # These may be used in auxiliary scripts (ie not part of toplevel), so they are defined unconditionally.
    ({
      system.build = { inherit (tools) nixos-install nixos-rebuild nixos-enter; };
      system.installerDependencies = [ pkgs.installShellFiles ];
    })
  ];

}
