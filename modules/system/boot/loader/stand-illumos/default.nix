{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.boot.loader.stand-illumos;

  # illumos' boot loader (usr/src/boot/) is a fork of the FreeBSD loader: same
  # Lua API (menu/core/config modules), same loader.efi -> BOOTX64.EFI, plus
  # usr/src/boot/i386/{gptzfsboot,pmbr} for BIOS. So the stand-freebsd builder
  # and the nixbsd loader.lua override apply almost verbatim, and we reuse them
  # rather than forking a second copy.
  #
  # PLACEHOLDER: what is *not* yet handled is illumos' kernel layout. illumos
  # boots `/platform/i86pc/kernel/amd64/unix` together with a `boot_archive`
  # ramdisk (built by cmd/boot/bootadm from cmd/boot/filelist/i386/filelist.ramdisk),
  # not a FreeBSD kernel directory with .ko modules. Once pkgs.illumos.unix
  # exists, addEntry() in stand-conf-builder.sh needs an illumos variant that
  # emits `unix` + boot_archive and passes the `init-path` boot property.
  builder = import ../stand-freebsd/stand-conf-builder.nix {
    inherit pkgs;
    stand-efi = cfg.package;
  };
  populateBuilder = import ../stand-freebsd/stand-conf-builder.nix {
    pkgs = pkgs.buildPackages;
    stand-efi = cfg.package;
  };

  timeoutStr = "-1";

  findMount =
    path:
    if config.fileSystems ? "${path}" then
      path
    else if path == "/" then
      path
    else
      findMount (dirOf path);
  nixStorePath =
    if config.readOnlyNixStore.enable then config.readOnlyNixStore.readOnlySource else "/nix/store";
  nixStoreMount = findMount nixStorePath;
  nixStoreFs = config.fileSystems.${nixStoreMount};

  mkDevice =
    fs:
    if fs.fsType == "zfs" then
      "zfs:${fs.device}"
    else if hasPrefix "/dev/" fs.device then
      substring 5 (-1) fs.device
    else
      throw "Can't tell the illumos bootloader how to find ${fs.fsType} ${fs.device}.";

  nixStoreDevice = if config.boot.copyKernelToBoot then "notused" else mkDevice nixStoreFs;
  nixStoreSuffix =
    if config.boot.copyKernelToBoot then "/not/used" else removePrefix nixStoreMount nixStorePath;
  copyKernelsArg = optionalString config.boot.copyKernelToBoot "-C";
  builderArgs = "-g ${toString cfg.configurationLimit} -t ${timeoutStr} -n ${nixStoreDevice} -N '${nixStoreSuffix}' ${copyKernelsArg} -c";
in
{
  options.boot.loader.stand-illumos = {
    # Defaults to off: pkgs.illumos has no boot loader package yet, so turning
    # this on makes the system fail to *build* (it still evaluates).
    enable = mkEnableOption "the illumos boot loader (a fork of the FreeBSD loader)";

    package = mkOption {
      type = types.package;
      default =
        pkgs.illumos.stand-efi or (throw ''
          The illumos boot loader (usr/src/boot) is not packaged yet.
          Set `boot.loader.stand-illumos.package` explicitly, or leave
          `boot.loader.stand-illumos.enable = false`.
        '');
      defaultText = literalExpression "pkgs.illumos.stand-efi";
      description = "Package providing loader.efi and the loader's Lua files.";
    };

    configurationLimit = mkOption {
      default = 20;
      type = types.int;
      description = "Maximum number of configurations in the boot menu.";
    };
  };

  config = mkIf cfg.enable {
    system.build.installBootLoader = "${builder} ${builderArgs}";
    system.boot.loader.id = "stand-illumos";
    boot.loader.espContents = pkgs.runCommand "espDerivation" { } ''
      mkdir -p $out
      ${populateBuilder} ${builderArgs} ${config.system.build.toplevel} -d $out -g 0
    '';

    # illumos takes the init binary from the `init-path` boot property
    # (uts/common/os/main.c: initname defaults to /sbin/init).
    boot.kernelEnvironment = {
      "init-path" = "${config.system.build.toplevel}/init";
    };
  };
}
