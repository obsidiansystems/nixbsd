# cloud-init for NixBSD. Modelled on the NixOS module, but the services are
# expressed with the portable `init.services` abstraction so they become rc.d
# scripts, ordered the same way as the FreeBSD port's rc scripts
# (`sysvinit/freebsd/*.tmpl` in the cloud-init sources).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.cloud-init;

  settingsFormat = pkgs.formats.yaml { };
  cfgfile = settingsFormat.generate "cloud.cfg" cfg.settings;

  # The nixpkgs `cloud-init` derivation has a few Linux-only dependencies that
  # only end up in wrapper `PATH`s or in test inputs. cloud-init itself has
  # native FreeBSD support (it is what the FreeBSD port ships), so stub those
  # out rather than pulling in packages that don't evaluate for this host.
  freebsdPackage =
    (pkgs.cloud-init.override {
      dmidecode = pkgs.emptyDirectory;
      systemd = pkgs.emptyDirectory;
      iproute2 = pkgs.emptyDirectory;
      shadow = pkgs.emptyDirectory;
      busybox = pkgs.emptyDirectory;
      procps = pkgs.emptyDirectory;
      cloud-utils = {
        guest = pkgs.emptyDirectory;
      };
    }).overrideAttrs
      (old: {
        # The test-suite assumes a Linux host.
        doCheck = false;
        nativeCheckInputs = [ ];
      });

  # Commands cloud-init's FreeBSD distro/datasource code shells out to.
  path =
    with pkgs;
    [
      cfg.package
      openssh
      gnugrep
      gnused
      coreutils
    ]
    ++ lib.optionals stdenv.hostPlatform.isFreeBSD (
      with pkgs.freebsd;
      [
        bin # kenv, ps, ...
        sysctl
        mount
        ifconfig
        route
        service
        geom # gpart, glabel: used by the `growpart` module
        growfs # used by the `resizefs` module on UFS
      ]
    )
    ++ cfg.extraPackages;

  mkStage =
    {
      description,
      args,
      dependencies,
      before ? [ ],
    }:
    {
      inherit description dependencies before;
      startType = "oneshot";
      inherit path;
      startCommand = [
        (pkgs.writeShellScript "cloud-init-stage" ''
          if ${pkgs.freebsd.bin}/bin/kenv -q kernel_options | grep -q 'cloud-init=disabled'; then
            echo "cloud-init is disabled via kernel_options."
          elif test -e /etc/cloud/cloud-init.disabled; then
            echo "cloud-init is disabled via cloud-init.disabled file."
          else
            exec ${lib.getExe' cfg.package "cloud-init"} ${args}
          fi
        '')
      ];
    };
in
{
  options.services.cloud-init = {
    enable = lib.mkEnableOption "cloud-init";

    package = lib.mkOption {
      type = lib.types.package;
      default = if pkgs.stdenv.hostPlatform.isFreeBSD then freebsdPackage else pkgs.cloud-init;
      defaultText = lib.literalExpression "pkgs.cloud-init";
      description = "The cloud-init package to use.";
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Additional packages to make available to the cloud-init stages.";
    };

    settings = lib.mkOption {
      description = "Structured cloud-init configuration, written to {file}`/etc/cloud/cloud.cfg`.";
      type = lib.types.submodule {
        freeformType = settingsFormat.type;
      };
      default = { };
    };

    config = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Raw cloud-init configuration. Takes precedence over `settings` if set.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.cloud-init.settings = {
      system_info = lib.mkDefault {
        distro = "freebsd";
        # NixBSD manages /etc/rc.conf and the interfaces itself (dhcpcd), so
        # never let cloud-init try to render network configuration.
        network.renderers = [ ];
        paths.run_dir = "/var/run/cloud-init/";
        ssh_svcname = "sshd";
        syslog_fix_perms = "root:wheel";
      };
      network.config = lib.mkDefault "disabled";
      # There is no `pw(8)` in NixBSD yet and users are declarative anyway, so
      # only provision SSH keys for root. `lock_passwd` would need `pw`.
      users = lib.mkDefault [
        {
          name = "root";
          lock_passwd = false;
        }
      ];
      disable_root = lib.mkDefault false;
      # /etc/rc.conf is generated from the configuration, so cloud-init can't
      # write the hostname there; dhcpcd sets it from DHCP instead.
      preserve_hostname = lib.mkDefault true;
      # sshd's own rc script generates host keys; don't let cloud-init delete
      # and regenerate them behind its back.
      ssh_deletekeys = lib.mkDefault false;
      ssh_genkeytypes = lib.mkDefault [ ];
      cloud_init_modules = lib.mkDefault [
        "seed_random"
        "bootcmd"
        "write_files"
        "growpart"
        "resizefs"
        "ca_certs"
        "users_groups"
        "ssh"
      ];
      cloud_config_modules = lib.mkDefault [
        "runcmd"
      ];
      cloud_final_modules = lib.mkDefault [
        "scripts_vendor"
        "scripts_per_once"
        "scripts_per_boot"
        "scripts_per_instance"
        "scripts_user"
        # `keys_to_console` is left out: it needs a helper at a hardcoded
        # /usr/local/lib path, and `ssh_authkey_fingerprints` already prints
        # the fingerprints to the console.
        "ssh_authkey_fingerprints"
        "phone_home"
        "final_message"
        "power_state_change"
      ];
    };

    environment.etc."cloud/cloud.cfg" =
      if cfg.config == "" then { source = cfgfile; } else { text = cfg.config; };

    environment.systemPackages = [ cfg.package ];

    # Same names and ordering as the FreeBSD port's rc.d scripts.
    init.services.cloudinitlocal = mkStage {
      description = "Initial cloud-init job (pre-networking)";
      args = "init --local";
      dependencies = [ "FILESYSTEMS" ];
      before = [ "NETWORKING" ];
    };

    init.services.cloudinit = mkStage {
      description = "Initial cloud-init job (metadata service crawler)";
      args = "init";
      dependencies = [
        "FILESYSTEMS"
        "NETWORKING"
        "cloudinitlocal"
      ];
      before = [
        "LOGIN"
        "sshd"
      ];
    };

    init.services.cloudconfig = mkStage {
      description = "Apply the settings specified in cloud-config";
      args = "modules --mode config";
      dependencies = [ "cloudinit" ];
      before = [ "cloudfinal" ];
    };

    init.services.cloudfinal = mkStage {
      description = "Execute cloud user/final scripts";
      args = "modules --mode final";
      dependencies = [
        "LOGIN"
        "cloudconfig"
        "sshd"
      ];
    };
  };
}
