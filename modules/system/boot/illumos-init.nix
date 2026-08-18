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
  inherit (lib) mkIf;

  isIllumos = config.nixpkgs.hostPlatform.isSunOS;
  cfg = config.boot.illumos;

  startd = pkgs.illumos.svc-startd or null;
  configd = pkgs.illumos.svc-configd or null;
  haveSmf = startd != null && configd != null;

  # See the note on extraFiles below: every package this module reaches for is
  # spelled `or null`, so the module stays evaluable against a nixpkgs that
  # does not have it yet.
  consoleShim = pkgs.illumos.init-console or null;

  # The console "getty": opens the console by /devices path, pushes ldterm and
  # ttcompat onto the bare asy(4D) stream, and runs a root shell on it. Same
  # `or null` spelling, and for the same reason.
  consoleLogin = pkgs.illumos.console-login or null;
in
{
  options.boot.illumos.debugConsoleInit = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Run `illumos.init-console` as /sbin/init instead of init itself. It
      opens the console by device path, puts it on fds 0/1/2 and execs the
      real init in the same process, so init is still pid 1.

      Only useful for debugging an early failure: init writes its diagnostics
      to /dev/console and /dev/msglog, neither of which exists until devfsadm
      is packaged, so without this a crash before init opens anything is
      completely silent.
    '';
  };

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
    #
    # `boot.illumos.init.file` rather than `bootArchive.extraFiles."sbin/init"`
    # directly: the latter is computed from the former now, so that whatever is
    # interposed in front of userland (the virtio-fs store mount, through
    # `init.preExec`) is still interposed here rather than being silently
    # replaced by this shim.
    boot.illumos.init.file = lib.mkIf (cfg.debugConsoleInit && consoleShim != null) (
      lib.mkForce "${consoleShim}/sbin/init"
    );

    boot.illumos.bootArchive.files = {

      # init reads this through definit(3) for the environment it hands to
      # everything it starts. Same two settings as cmd/init/init.dfl.
      "etc/default/init" = ''
        TZ=UTC
        CMASK=022
      '';

      # Two entries. `smf` is how svc.startd gets started, and therefore the
      # only route from init to a running service; `co` is the interactive
      # console, and is what makes a boot something you can type at.
      #
      # Departures from cmd/initpkg/inittab, all forced:
      #
      #   * No `>/dev/msglog 2<>/dev/msglog </dev/console` on the smf line.
      #     Those nodes are created by devfsadm(8), which is not packaged, so
      #     none of them exist -- see the console hunt in init-shell.c. init
      #     does not start a command whose redirections it cannot open, so
      #     leaving them in means svc.startd never runs at all. `co` needs no
      #     redirection either, for a stronger reason: init sets FD_CLOEXEC on
      #     every descriptor before exec'ing an inittab command
      #     (cmd/init/init.c, spawn() and boot_init()), so the command starts
      #     with no open descriptors at all and console-login has to open the
      #     console for itself regardless.
      #
      #   * `co` has no counterpart in the gate's inittab at all, and that is
      #     the interesting part. On a real system the console login is
      #     `svc:/system/console-login:default` -- cmd/initpkg/inittab says
      #     outright that inittab is no longer the place for this -- and
      #     its method runs `ttymon -d /dev/console -m ldterm,ttcompat`. That
      #     route is closed here: svc.startd runs now, but svc.configd exits
      #     102 ("database initialization failure") because there is no
      #     repository for it to open, so startd goes to maintenance mode and
      #     starts no service whatsoever. A console reachable only through SMF
      #     is a console you cannot use to debug SMF.
      #
      #     So the entry is a pre-SMF-style inittab line, but `sysinit` rather
      #     than the `co:234:respawn:` an old Solaris inittab would have used.
      #     Two independent reasons, and both are why console-login exists
      #     rather than a bare shell:
      #
      #       - `respawn` would never fire. init boots with `cur_state = 0`
      #         ("It's fine to boot up with state as zero, because startd will
      #         later tell us the real state", init.c:735), state_to_mask(0) is
      #         0, and spawn_processes() skips every entry whose rstate mask
      #         does not intersect the current one. So no respawn entry runs
      #         until svc.startd reports a run level -- which is exactly the
      #         thing one wants a console in order to debug.
      #
      #       - init *waits* for each sysinit entry, and starts svc.startd only
      #         after all of them. So the command has to return promptly:
      #         console-login forks a supervisor and lets its parent exit, and
      #         does the respawning itself. That is also why `co` comes first
      #         here -- the console is up before svc.startd is even started, so
      #         a startd that hangs still leaves a usable machine.
      #
      #   * Still no `ap`/`sp` sysinit lines: they run /sbin/autopush and
      #     /sbin/soconfig, neither of which is packaged. Packaging autopush
      #     plus /etc/iu.ap (`asy -1 0 ldterm ttcompat`) is the *proper* fix
      #     for the missing line discipline and would let console-login drop
      #     its private I_PUSH; until then console-login pushes the modules
      #     itself, as init-shell.c already did.
      #
      # There is deliberately no `initdefault`. On illumos the run levels are
      # vestigial -- SMF milestones replaced them -- and both entries here are
      # `sysinit`, which runs regardless of run level.
      #
      # The `smf` line is conditional on SMF actually being configured, and
      # that is not tidiness. svc.startd is staged whenever the package exists,
      # so on a configuration that does not run SMF -- `illumos-base` -- init
      # starts a startd that has no repository to bind to. It cannot come up,
      # it cannot reach a milestone, and it says so for ever:
      #
      #     Requesting System Maintenance Mode
      #     Console login service(s) cannot run
      #
      # 24041 times in the 95 seconds after boot, measured, which drowns the
      # console-login prompt that the `co` line above did successfully start.
      # Invisible until `-virtiofs` configurations could exec anything at all;
      # visible immediately afterwards.
      "etc/inittab" =
        lib.optionalString (consoleLogin != null) ''
          co::sysinit:/sbin/console-login
        ''
        + lib.optionalString config.boot.illumos.smf.enable ''
          smf::sysinit:/lib/svc/bin/svc.startd
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
    boot.illumos.bootArchive.symlinks =
      {
        # init does not exec inittab commands directly: every one of them goes
        # through `execle(SH, "INITSH", "-c", cmd, ...)` with SH the literal
        # "/sbin/sh" (cmd/init/init.c:493), and so does svc.startd itself, from
        # startd_run(). Without this the *only* thing that ever happens is
        #
        #     Command "/lib/svc/bin/svc.startd" failed to execute.
        #     errno = 2 (exec of shell failed)
        #
        # and even that goes to /dev/console, which does not exist. bash is in
        # `environment.requiredPackages` for every illumos configuration here,
        # and provides `sh`.
        "sbin/sh" = "${config.system.path}/bin/sh";
      }
      // lib.optionalAttrs (consoleLogin != null) {
        "sbin/console-login" = "${consoleLogin}/sbin/console-login";
      }
      // lib.optionalAttrs haveSmf {
        "lib/svc/bin/svc.startd" = "${startd}/lib/svc/bin/svc.startd";
        "lib/svc/bin/svc.configd" = "${configd}/lib/svc/bin/svc.configd";
      };

    # svc.startd, svc.configd and console-login are reached only through the
    # symlinks above, so nothing in `toplevel` refers to them and they would
    # not otherwise be staged.
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
      ++ lib.optional (consoleLogin != null) consoleLogin
    );
  };
}
