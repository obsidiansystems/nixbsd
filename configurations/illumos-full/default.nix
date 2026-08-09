{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ../illumos-base ];

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
  ];

  # `coreutils-full` links openssl, whose target table used to lack
  # `x86_64-solaris2.11` and threw during evaluation. That is fixed, so the
  # reason `illumos-base` pins plain `coreutils` no longer applies here.
  environment.requiredPackages = lib.mkForce [
    pkgs.bashInteractive
    pkgs.coreutils
  ];
}
