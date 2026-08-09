{ lib, pkgs, ... }:
{
  imports = [ ../illumos-base/default.nix ];

  # NixOS [modular services](https://nixos.org/manual/nixos/unstable/#modular-services)
  # lowered onto SMF, the same way ../modular-test/default.nix lowers them onto
  # FreeBSD rc. See ../../modules/system/service/illumos/.
  #
  # `process.argv` here is deliberately a shell one-liner rather than a real
  # package: nothing in the illumos package set cross-compiles yet, and the
  # point of this configuration is to exercise the `system.services` ->
  # `smf.services` -> manifest path, which is pure and testable today.
  system.services.hello =
    { config, ... }:
    {
      _class = "service";

      process.argv = [
        "/bin/sh"
        "-c"
        "while :; do echo hello from ${config.smf.meta.servicePrefix}; sleep 60; done"
      ];
    };
}
