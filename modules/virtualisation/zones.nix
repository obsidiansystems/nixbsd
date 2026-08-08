{ lib, ... }:
# illumos' analogue of FreeBSD jails is zones. Actual zone support is NOT
# implemented; this module only declares the portability flag that shared
# modules (e.g. modules/services/system/nix-daemon.nix, the loader modules)
# already read unconditionally. On FreeBSD the same option is declared by
# modules/virtualisation/jails.nix.
{
  options.boot.isJail = lib.mkOption {
    type = lib.types.bool;
    default = false;
    internal = true;
    description = ''
      Whether this configuration is for a container-like environment (an
      illumos zone) rather than a machine that boots its own kernel.

      PLACEHOLDER: nixbsd cannot build or manage illumos zones yet; this
      option exists so that shared modules referencing `boot.isJail`
      evaluate on illumos.
    '';
  };
}
