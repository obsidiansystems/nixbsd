{ lib, ... }:
{
  options.systemd.packages = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [ ];
    description = "This option exists only for compatibility with NixOS modules and does not have any effect.";
  };
  # Upstream moved the display manager out of services.xserver.displayManager
  # into a top-level services.displayManager, and nixos/modules/config/nix.nix
  # now unconditionally sets .hiddenUsers from the nixbld users. Importing
  # upstream's services/display-managers/default.nix instead would drag in its
  # renamed-option aliases, whose targets assume systemd; nixbsd's own
  # services/x11/display-managers still owns the services.xserver.* half.
  options.services.displayManager.hiddenUsers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "This option exists only for compatibility with NixOS modules and does not have any effect.";
  };
  # system/boot/loader/efi.nix now declares a systemd service. Inert here for
  # the same reason as systemd.packages above.
  options.systemd.services = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "This option exists only for compatibility with NixOS modules and does not have any effect.";
  };
  options.security.sudo-rs = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = [ ];
    description = "This option exists only for compatibility with NixOS modules and does not have any effect.";
  };
}
