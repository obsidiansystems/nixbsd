{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ../illumos-base ];

  # Use nixpkgs' own `nix`, not the one from the `cppnix` flake input.
  #
  # `modules/misc/nix-overlay.nix` applies `cppnixFlake.overlays.internal` when
  # this is on, which replaces `nix` with the flake's build. That build forces
  # `onetbb`, which has no Solaris support at all -- its malloc proxy is tied to
  # Linux-only symbol version scripts -- and since the guard is a
  # `meta.platforms` refusal it fails at *evaluation*, taking out the entire
  # closure rather than one package.
  #
  # nixpkgs' `nix` does not have this problem: its `libblake3` computes
  # `useTBB ? lib.meta.availableOn stdenv.hostPlatform onetbb`, which is `false`
  # here, so blake3 drops to single-threaded and nothing references oneTBB.
  # Note an overlay cannot fix the flake's copy -- it is instantiated
  # separately, so `nixpkgs.overlays` is invisible to it.
  nixpkgs.overrideNix = false;

  # `illumos-base` is deliberately minimal: it cuts `environment.requiredPackages`
  # to bash and coreutils and turns nix off, so that `system.build.toplevel`
  # becomes reachable as soon as a handful of packages land rather than when the
  # whole tree does. That constraint has now expired for a useful set of things,
  # so this configuration turns them back on.
  #
  # Keep `illumos-base` as the minimum that boots. When something here breaks,
  # `illumos-base` is the bisection point: if it still boots, the fault is in
  # what this file adds, not in the kernel, init or the boot archive.

  # `nix.enable` stays **off**, deliberately. The nix module is about running a
  # daemon: it wants build users and groups, a writable `/nix/var`, and
  # something to launch `nix-daemon` at boot. None of those exist here --
  # `svc.startd` is unpackaged so nothing launches services at all, the root
  # filesystem is read-only hsfs, and `socket(2)` itself lives in `sockfs`,
  # which is absent from the kernel module list, so even a unix-domain socket
  # cannot be created yet.
  #
  # What we can have today is the *binary* in the image, which is worth having:
  # nix cross-compiles to 12 illumos-native executables, `PT_INTERP` pointing
  # at our own `ld.so.1`. Enough for `nix --version` and to poke at, not enough
  # to build anything.
  #
  # Running `nix-daemon` under SMF is the eventual goal; it needs `svc.startd`,
  # `fs/sockfs` and a writable `/nix/var` first.
  environment.systemPackages = [
    pkgs.nix

    # Cross-compiles and is genuinely illumos-native (`sshd` pulls in
    # libsocket/libnsl/libmd), but it cannot *run* yet: there is no TCP/IP
    # stack in the kernel module list -- no `sockfs`, so no sockets in
    # userland at all -- no NIC driver, and qemu is passed no `-nic`. It is
    # here so the binaries are in the image to poke at, not because ssh works.
    pkgs.openssh

    # curl now has GSSAPI, which took packaging `libresolv` so that krb5's
    # `AC_SEARCH_LIBS(res_nsearch, resolv)` could succeed. Same caveat as
    # openssh: no network stack, so this is a binary you can run `--version`
    # on rather than a working client.
    pkgs.curl

    # These do work today, since they need nothing but libc.
    pkgs.perl
    pkgs.gnugrep
    pkgs.gnused
    pkgs.findutils
    pkgs.diffutils
    pkgs.gawk
    pkgs.gzip
    pkgs.xz
    pkgs.zstd

    # The name-service switch has a `files` backend now (`nss_files.so.1`, in
    # the composite libc so a pathless `dlopen` can find it) and the boot
    # archive carries `/etc/{passwd,shadow,group,nsswitch.conf}`. So
    # `getent passwd root` should return a row -- that single command
    # exercises the backend, the switch config and the runpath reasoning.
    pkgs.illumos.getent
  ]
  # The verb half of SMF: `svcadm enable/disable/restart/refresh/clear/
  # milestone`. `svccfg` could already import and export manifests, but until
  # now there was no way to change an instance's administrative state from the
  # console. Spelled `or null` so this configuration stays evaluable against a
  # nixpkgs that predates the package.
  #
  # Note what it cannot do yet: `svc.configd` currently exits 102 (database
  # initialization failure), so there is no repository to bind to and every
  # subcommand will fail against it. Failing with a message is still strictly
  # better than having no command at all.
  ++ lib.optional (pkgs.illumos.svcadm or null != null) pkgs.illumos.svcadm
  # The query half: `svcs`, `svcs -a`, `svcs -l <fmri>`, and `svcs -x`, which
  # walks the dependency graph backwards from each impaired instance to the
  # root cause. Built without libzonecfg (a Tier 4 bring-up shim, nixpkgs
  # patches/0019); the only thing that costs is `svcs -z <zone> -L` log-path
  # prefixing, which would need zones this system cannot create anyway. Same
  # configd caveat as above applies -- svcs will report that it cannot reach
  # the repository rather than report any services.
  ++ lib.optional (pkgs.illumos.svcs or null != null) pkgs.illumos.svcs;

  # `coreutils-full` links openssl, whose target table used to lack
  # `x86_64-solaris2.11` and threw during evaluation. That is fixed, so the
  # reason `illumos-base` pins plain `coreutils` no longer applies here.
  environment.requiredPackages = lib.mkForce [
    pkgs.bashInteractive
    pkgs.coreutils
  ];

  # See modules/system/boot/illumos-smf.nix. This is what turns the packaged
  # svc.startd and svc.configd from binaries in the image into a running init
  # system: it configures sockets, builds a writable repository under
  # /etc/svc/volatile, imports `system.build.smfManifests` and exec's startd.
  #
  # This lives here rather than in a configuration of its own so that the
  # `svcs` and `svcadm` installed above have something to talk to. They were
  # previously in a configuration that ran SMF but shipped no CLI, and in one
  # that shipped the CLI but never started SMF.
  boot.illumos.smf.enable = true;

  # With the real init there is no console prompt by design -- /etc/inittab
  # holds one `sysinit` line -- so a boot that reaches userland and a boot that
  # hangs look identical. Set this to put a shell on the console instead and
  # run the bootstrap by hand as /lib/svc/bin/smf-bootstrap:
  #
  #     boot.illumos.smf.debugShell = true;

  # sshd and nginx, both as SMF services. `illumos-base` turns sshd off
  # because for a long time nothing in the userland cross-compiled; openssh
  # does now, and nginx builds too, so force it back on here. Both render into
  # the `site/` namespace rather than the OS-delivered `network/ssh`, since
  # they are not gate-delivered services -- compare usr/src/cmd/ssh/etc/ssh.xml
  # in illumos-gate for what a hand-written manifest looks like.
  #
  # These were three separate configurations (illumos-sshd, illumos-nginx,
  # illumos-modular) that existed only to render manifests, since none of it
  # could run. They are folded in here instead: the manifests still get
  # rendered, and now there is an SMF to import them into.
  #
  # What still does not work is reaching them: the kernel has a NIC and the IP
  # stack, but `e1000g` attach fails silently before it can be plumbed, so
  # there is no address to connect to. See `boot.illumos.kernel` notes and
  # nixpkgs' illumos `unix.nix`.
  services.sshd.enable = lib.mkForce true;

  services.nginx = {
    enable = true;
    virtualHosts."localhost" = {
      default = true;
      root = ./.;
    };
  };

  # NixOS modular services lowered onto SMF, the same way ../modular-test does
  # for FreeBSD rc. See ../../modules/system/service/illumos/. This is a
  # different path from `init.services` below -- `system.services` ->
  # `smf.services` -- and nothing else here exercises it, which is why the
  # demo survives the folding-in of the old illumos-modular configuration.
  # Drop it once a real service uses this path.
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

  # The daemon SMF exists to supervise here. Declared through the portable
  # `init.services` layer, which modules/system/boot/init/portable/illumos.nix
  # renders into an SMF manifest.
  init.services.nix-daemon = {
    description = "Nix build daemon";
    startCommand = [ "${pkgs.nix}/bin/nix-daemon" ];
    startType = "foreground";
    environment = {
      # /tmp is a directory in the read-only root, not a filesystem; the one
      # writable tree this early is the kernel's tmpfs on /etc/svc/volatile.
      TMPDIR = "/etc/svc/volatile/tmp";
    };
  };
}
