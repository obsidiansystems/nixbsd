nixpkgsPath: hostPlatform:

if hostPlatform.isFreeBSD then
  [
    ./config/i18n-freebsd.nix
    ./programs/services-mkdb.nix
    ./programs/shutdown-freebsd.nix
    ./services/newsyslog.nix
    ./services/syslogd.nix
    ./services/ttys/getty-freebsd.nix
    ./system/boot/init/portable/freebsd.nix
    ./system/boot/loader/stand-freebsd
    ./system/service/freebsd/system.nix
    ./virtualisation/jails.nix
  ]
else if hostPlatform.isOpenBSD then
  [
    ./programs/shutdown-openbsd.nix
    ./programs/su-openbsd.nix
    ./services/ttys/getty-openbsd.nix
    ./system/boot/loader/stand-openbsd
    ./system/boot/init/portable/openbsd.nix
  ]
else if hostPlatform.isIllumos then
  [
    ./system/boot/init/portable/illumos.nix
    ./system/boot/loader/stand-illumos
    ./system/service/illumos/system.nix
    ./virtualisation/zones.nix
  ]
else
  throw "Unsupported target platform ${hostPlatform.system}"
