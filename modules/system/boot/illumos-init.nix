{
  lib,
  config,
  pkgs,
  ...
}:

# What real init(8) needs in the boot image, as opposed to the freestanding
# `init-shell` this bring-up booted before it.
#
# `system.init` already resolves to `pkgs.illumos.init` when that package
# exists (system/activation/top-level.nix), so packaging it is what switches
# the image over; this module supplies the files it then goes looking for.
#
# Kept separate from illumos-boot-image.nix on purpose: `bootArchive.files`
# and `.symlinks` are `attrsOf`, so two modules merge into them cleanly, and
# the name-service files over there have a different owner and a different
# reason to exist.

let
  inherit (lib) mkIf mkAfter;

  isIllumos = config.nixpkgs.hostPlatform.isSunOS;

  startd = pkgs.illumos.svc-startd or null;
  configd = pkgs.illumos.svc-configd or null;
  haveSmf = startd != null && configd != null;

  # See the note on extraFiles below: every package this module reaches for is
  # spelled `or null`, so the module stays evaluable against a nixpkgs that
  # does not have it yet.
  consoleShim = pkgs.illumos.init-console or null;
in
{
  config = mkIf isIllumos {

    # DEBUGGING: when `illumos.init-console` is available, run it as /sbin/init
    # instead of init itself. It opens the console by device path, puts it on
    # 0/1/2 and execs the real init in the same process, so init is still pid 1
    # -- without it, init's diagnostics go to /dev/console, which does not
    # exist, and an early failure is completely silent.
    #
    # Written as `or null` on purpose. This module has to evaluate against a
    # nixpkgs that does not have the package yet: a bare reference here is a
    # forward reference to something unbuilt, and it breaks `nix run` for
    # anyone on an older nixpkgs with an "attribute missing" error that reads
    # like a real bug rather than work in progress. Same reason `system.init`
    # is spelled `pkgs.illumos.init or pkgs.illumos.init-shell`.
    boot.illumos.bootArchive.extraFiles."sbin/init" =
      lib.mkIf (consoleShim != null) (lib.mkForce "${consoleShim}/sbin/init");

    boot.illumos.bootArchive.files = {

      # init reads this through definit(3) for the environment it hands to
      # everything it starts. Same two settings as cmd/init/init.dfl.
      "etc/default/init" = ''
        TZ=UTC
        CMASK=022
      '';

      # The one entry that matters is `smf`: this is how svc.startd gets
      # started, and therefore the only route from init to a running service.
      #
      # Two departures from cmd/initpkg/inittab, both forced:
      #
      #   * No `>/dev/msglog 2<>/dev/msglog </dev/console` on the smf line.
      #     Those nodes are created by devfsadm(8), which is not packaged, so
      #     none of them exist -- see the console hunt in init-shell.c. init
      #     does not start a command whose redirections it cannot open, so
      #     leaving them in means svc.startd never runs at all.
      #
      #   * No `ap`/`sp` sysinit lines: they run /sbin/autopush and
      #     /sbin/soconfig, neither of which is packaged, and a missing
      #     sysinit command is a per-boot error rather than something fatal.
      #
      # There is deliberately no `initdefault`. On illumos the run levels are
      # vestigial -- SMF milestones replaced them -- and svc.startd is started
      # from `sysinit`, which runs regardless of run level.
      "etc/inittab" = ''
        # CONTROL EXPERIMENT -- sysinit entry removed on purpose, to separate
        # "init cannot run" from "init cannot start svc.startd".
        # smf::sysinit:/lib/svc/bin/svc.startd
      '';

      # init calls pam_start("init", ...) in notify_pam_dead(), which closes
      # a PAM session when a utmpx entry goes away, and sulogin(8) would
      # authenticate through PAM too. Neither is on the boot path, and no PAM
      # *modules* are packaged yet, so this exists to give pam_start something
      # to parse rather than to authenticate anybody. Keep it until
      # pam_unix_auth and friends are packaged, then replace it with the real
      # lib/libpam/pam.conf.
      "etc/pam.conf" = ''
        other   auth      required        pam_permit.so.1
        other   account   required        pam_permit.so.1
        other   session   required        pam_permit.so.1
        other   password  required        pam_permit.so.1
      '';
    };

    # /etc/inittab names svc.startd by its absolute path, which on a real
    # system is /lib/svc/bin. Point that at the packaged binaries rather than
    # copying them, so the store paths their RUNPATHs refer to stay the ones
    # that get staged.
    boot.illumos.bootArchive.symlinks = mkIf haveSmf {
      "lib/svc/bin/svc.startd" = "${startd}/lib/svc/bin/svc.startd";
      "lib/svc/bin/svc.configd" = "${configd}/lib/svc/bin/svc.configd";
    };

    # svc.startd and svc.configd are reached only through the symlinks above,
    # so nothing in `toplevel` refers to them and they would not otherwise be
    # staged.
    #
    # `mkDefault` is load-bearing, not decoration. illumos-boot-image.nix
    # defines this list with `mkDefault`, and NixOS keeps only the
    # highest-priority definitions of an option before merging them -- so a
    # plain definition here does not append to that list, it *replaces* it,
    # silently dropping `toplevel` and `system.init`. That is exactly what
    # happened: real init's own store path stopped being staged, its /sbin/init
    # copy had nothing to exec, and the kernel reported errno 2. Matching the
    # priority makes the two lists concatenate as intended.
    boot.illumos.bootArchive.storePaths = lib.mkDefault (
      lib.optionals haveSmf [
        startd
        configd
      ]
    );
  };
}
