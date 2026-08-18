{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.boot.kernel.sysctl;
  sysctlOption = mkOptionType {
    name = "sysctl option value";
    check =
      val:
      let
        checkType = x: isBool x || isString x || isInt x || x == null;
      in
      checkType val || (val._type or "" == "override" && checkType val.content);
    merge = loc: defs: mergeOneOption loc (filterOverrides defs);
  };

in
{

  options = {

    boot.kernel.sysctl = mkOption {
      type = types.submodule { freeformType = types.attrsOf sysctlOption; };
      default = { };
      example = literalExpression ''
        { "kern.sync_on_panic" = false; "kern.maxvnodes" = 4096; }
      '';
      description = ''
        Runtime parameters of the FreeBSD kernel, as set by
        {manpage}`sysctl(8)`.  Note that sysctl
        parameters names must be enclosed in quotes
        (e.g. `"kern.sync_on_panic"` instead of
        `kern.sync_on_panic`).  The value of each
        parameter may be a string, integer, boolean, or null
        (signifying the option will not appear at all).
      '';

    };

  };

  config =
    let
      # `null` where the platform has no sysctl(8) at all. It used to be
      # "/no-sysctl-on-illumos" -- a path chosen to fail loudly -- but nothing
      # was gated on it, so the services below were still defined and illumos
      # simply ran it:
      #
      #     svc:/site/sysctl:default           maintenance
      #     svc:/site/sysctl-lastload:default  maintenance
      #     Start method failed repeatedly, last exited with status 127
      #
      # on every boot. 127 is command-not-found. Two permanently broken
      # services are worse than none: `svcs -xv` is how you find a service
      # that is genuinely wrong, and it stops being useful once it always has
      # something in it.
      sysctlBin =
        {
          freebsd = "${pkgs.freebsd.sysctl}/bin/sysctl";
          openbsd = "${pkgs.openbsd.sysctl}/bin/sysctl";
          # illumos has no sysctl(8). /etc/system is the rough analogue, and
          # it is read by the kernel at boot rather than by a userland tool,
          # so there is nothing for these services to run.
          solaris = null;
        }
        .${pkgs.stdenv.hostPlatform.parsed.kernel.name};
    in
    mkIf (cfg != { } && sysctlBin != null) {

      environment.etc."sysctl.conf".text = concatStrings (
        mapAttrsToList (
          n: v:
          optionalString (v != null) ''
            ${n}=${if v == false then "0" else toString v}
          ''
        ) cfg
      );

      init.services.sysctl = {
        description = "Set sysctl variables";
        startType = "oneshot";
        startCommand = [
          "${sysctlBin}"
          "-i"
          "-f"
          "/etc/sysctl.conf"
        ];
      };

      init.services.sysctl-lastload = {
        description = "Set sysctl variables after services are started";
        dependencies = [ "LOGIN" ];
        before = [ "jail" ];

        startType = "oneshot";
        startCommand = [
          "${sysctlBin}"
          "-i"
          "-f"
          "/etc/sysctl.conf"
        ];
      };

    };
}
