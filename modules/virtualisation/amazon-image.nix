# Configuration for Amazon EC2 instances, and the disk image to upload as an
# AMI. Import this module from a configuration and build
# `system.build.amazonImage`, then register it with
# `system.build.uploadAmazonImage`.
#
# Loader and rc settings follow what FreeBSD release engineering uses for the
# official AMIs (`release/tools/ec2.conf` in freebsd-src).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.virtualisation.amazonImage;

  rootFilesystemLabel = "nixos";
  espFilesystemLabel = "ESP";

  efiPartition = pkgs.callPackage ../../lib/make-partition-image.nix {
    inherit pkgs lib;
    label = espFilesystemLabel;
    filesystem = "efi";
    contents = [
      {
        target = "/";
        source = config.boot.loader.espContents;
      }
    ];
    totalSize = "64m";
  };

  rootPartition = pkgs.callPackage ../../lib/make-partition-image.nix {
    inherit pkgs lib;
    label = rootFilesystemLabel;
    filesystem = "ufs";
    makeRootDirs = true;
    contents = lib.optionals (config.boot.loader.bootContents != null) [
      {
        target = "/boot";
        source = config.boot.loader.bootContents;
      }
    ];
    nixStorePath = "/nix/store";
    nixStoreClosure = [ config.system.build.toplevel ];
    nixStoreRegistration = true;
  };

  # The ESP goes first so the root partition is last on the disk and can be
  # grown into the (larger) EBS volume on first boot.
  amazonImage = pkgs.callPackage ../../lib/make-disk-image.nix {
    inherit pkgs lib;
    name = cfg.name;
    partitions = [
      efiPartition
      rootPartition
    ];
    format = "raw";
    partitionTableType = "efi";
    totalSize = if cfg.sizeMB == null then null else "${toString cfg.sizeMB}m";
  };

  uploadAmazonImage = pkgs.buildPackages.callPackage ./upload-ami.nix {
    image = amazonImage;
    imageName = cfg.name;
    architecture =
      {
        x86_64 = "x86_64";
        aarch64 = "arm64";
      }
      .${pkgs.stdenv.hostPlatform.parsed.cpu.name};
  };
in
{
  options.virtualisation.amazonImage = {
    name = lib.mkOption {
      type = lib.types.str;
      default = "nixbsd-amazon-image-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}";
      defaultText = lib.literalExpression ''"nixbsd-amazon-image-''${config.system.nixos.label}-''${pkgs.stdenv.hostPlatform.system}"'';
      description = "Name of the disk image and of the registered AMI.";
    };

    sizeMB = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = ''
        Size of the disk image in megabytes, or null to make it exactly as
        large as its partitions. The root filesystem is grown to fill the EBS
        volume on first boot, so padding the image only makes the upload
        bigger.
      '';
    };
  };

  config = {
    fileSystems."/" = {
      device = lib.mkDefault "/dev/gpt/${rootFilesystemLabel}";
      fsType = lib.mkDefault "ufs";
    };

    fileSystems."/boot" = {
      device = lib.mkDefault "/dev/msdosfs/${espFilesystemLabel}";
      fsType = lib.mkDefault "msdosfs";
      noCheck = lib.mkDefault true;
    };

    boot.loader.stand-freebsd.enable = lib.mkDefault true;

    # Elastic Network Adapter driver; NVMe is already in GENERIC.
    boot.kernelModules = [ "if_ena" ];

    boot.kernelEnvironment = {
      # Serial console on ttyu0 (EC2 serial console / "get system log"),
      # with output also going to the EFI framebuffer for screenshots.
      console = "comconsole,efi";
      boot_multicons = "YES";
      # Works around an old Xen serial port bug.
      "hw.broken_txfifo" = "1";
      # There is no keyboard; don't wait for one.
      "hint.atkbd.0.disabled" = "1";
      "hint.atkbdc.0.disabled" = "1";
      # Use the modern nda(4) NVMe driver rather than nvd(4).
      "hw.nvme.use_nvd" = "0";
      beastie_disable = "YES";
    };

    # Cloud-init handles SSH keys, user-data, and growing the root filesystem.
    services.cloud-init.enable = lib.mkDefault true;
    services.cloud-init.settings.datasource_list = [ "Ec2" ];

    services.sshd.enable = lib.mkDefault true;
    services.openssh.settings.PermitRootLogin = lib.mkDefault "prohibit-password";
    services.openssh.settings.PasswordAuthentication = lib.mkDefault false;

    networking.useDHCP = lib.mkDefault true;
    # The EC2 DHCP server is trusted; skip the ARP probe.
    networking.dhcpcd.extraConfig = "noarp";

    # The image ships a store without a database. Register the closure on the
    # first boot, then drop the manifest so it doesn't get re-loaded.
    init.services.loadNixPathRegistration = lib.mkIf config.nix.enable {
      description = "Register the pre-installed Nix store paths";
      startType = "oneshot";
      dependencies = [ "FILESYSTEMS" ];
      startCommand = [
        (pkgs.writeShellScript "load-nix-path-registration" ''
          reg=/nix/store/nix-path-registration
          if [ -e "$reg" ]; then
            ${config.nix.package.out}/bin/nix-store --load-db < "$reg" && rm -f "$reg"
          fi
        '')
      ];
    };

    system.build.amazonImage = amazonImage;
    system.build.uploadAmazonImage = uploadAmazonImage;
  };
}
