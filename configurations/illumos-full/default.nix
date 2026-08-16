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

  # `nix.enable` stays **off**, deliberately -- but no longer for the original
  # reasons, which have all since been fixed. The module wants build users and
  # groups and a `/nix/var` it can write to, and the parts of that story that
  # were missing (nothing to launch services, no sockets, a read-only root) are
  # not missing any more: SMF runs, `fs/sockfs` is in the kernel module list,
  # and the root is a writable UFS ramdisk (`boot.illumos.rootfs`).
  #
  # What replaces it for now is `init.services.nix-daemon` at the bottom of
  # this file, which launches the same daemon through the portable init layer
  # without the module's user/group machinery. Turning the module on properly
  # is the remaining work.
  environment.systemPackages = [
    pkgs.nix

    # Genuinely illumos-native (`sshd` pulls in libsocket/libnsl/libmd) and
    # started by SMF below. The kernel now has the IP stack and a NIC driver,
    # and qemu is passed a virtio NIC with a port forward -- what is still
    # missing is an address on it, since `ifconfig` links libdladm and
    # libipadm and neither is packaged yet.
    pkgs.openssh

    # curl now has GSSAPI, which took packaging `libresolv` so that krb5's
    # `AC_SEARCH_LIBS(res_nsearch, resolv)` could succeed. Same caveat as
    # openssh: the stack is there but nothing has an address, so this reaches
    # nothing off-box yet.
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
  # This used to be noted as useless because `svc.configd` exited 102 (database
  # initialization failure) and there was no repository to bind to. That is
  # fixed: configd starts, startd builds the graph, and services reach
  # `online`, so these actually work now.
  ++ lib.optional (pkgs.illumos.svcadm or null != null) pkgs.illumos.svcadm
  # The query half: `svcs`, `svcs -a`, `svcs -l <fmri>`, and `svcs -x`, which
  # walks the dependency graph backwards from each impaired instance to the
  # root cause. Built without libzonecfg (a Tier 4 bring-up shim, nixpkgs
  # patches/0019); the only thing that costs is `svcs -z <zone> -L` log-path
  # prefixing, which would need zones this system cannot create anyway.
  #
  # `svcs -x` is the first thing to reach for when a service here misbehaves:
  # it is how the missing-milestone and sulogin-storm problems were found.
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
  # What still does not work is reaching them. The kernel has the IP stack and
  # two NIC drivers, and the VM is given a virtio NIC with host port 2222
  # forwarded to guest 22 -- but nothing assigns an address, because
  # `ifconfig` links libdladm and libipadm and neither is packaged yet.
  # (`e1000g` is also built, but its attach(9E) unwinds silently after a
  # mac_register() that can be seen to succeed, which is why the VM asks for
  # virtio instead. See nixpkgs' illumos `unix.nix`.)
  services.sshd.enable = lib.mkForce true;

  # The host keys have to live somewhere writable. The default paths are under
  # /etc/ssh, which is on the read-only hsfs root, so the start method fails
  # every time and the service lands in maintenance:
  #
  #     mkdir: cannot create directory '/etc/ssh': Read-only file system
  #     Saving key "/etc/ssh/ssh_host_rsa_key" failed: No such file or directory
  #     [ start + 2.76s Method "start" exited with status 1. ]
  #
  # /etc/svc/volatile is the kernel-mounted tmpfs, and the module's `preStart`
  # already does `mkdir -p` on each key's directory, so pointing the paths
  # there is enough. Regenerated every boot, which is what a VM with no
  # persistent storage can offer: expect a host-key warning on reconnect.
  services.openssh.hostKeys = lib.mkForce [
    {
      type = "ed25519";
      path = "/etc/svc/volatile/ssh/ssh_host_ed25519_key";
    }
    {
      type = "rsa";
      bits = 4096;
      path = "/etc/svc/volatile/ssh/ssh_host_rsa_key";
    }
  ];

  # sshd reads /etc/ssh/sshd_config by name -- the generated start method runs
  # `sshd` with no `-f` -- and the boot archive stages `bootArchive.files` and
  # `bootArchive.symlinks` only, not `environment.etc`. So the config the
  # module generates never reaches the image, and sshd exits 1 on every start:
  #
  #     illumos# sshd -t
  #     /etc/ssh/sshd_config: No such file or directory
  #
  # Link them in from the store rather than copying: the system closure is
  # already in the archive, so this costs nothing but the link. `moduli` comes
  # along for the same reason -- sshd wants it for diffie-hellman-group-exchange
  # and complains when it is absent.
  #
  # TODO the tidier fix is for the start method to pass `-f`, which would keep
  # the config in the store where the rest of the configuration lives. That
  # means touching modules/services/networking/ssh/sshd.nix, which FreeBSD and
  # OpenBSD share, so it wants testing on those first.
  boot.illumos.bootArchive.symlinks = {
    "etc/ssh/sshd_config" = "${config.environment.etc."ssh/sshd_config".source}";
    "etc/ssh/moduli" = "${config.environment.etc."ssh/moduli".source}";
  };

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
