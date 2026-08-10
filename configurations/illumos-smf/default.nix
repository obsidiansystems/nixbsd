{
  config,
  lib,
  pkgs,
  ...
}:
{
  # `illumos-base`, not `illumos-full`: the point of this configuration is the
  # init system, and everything `illumos-full` adds beyond nix -- openssh,
  # curl, perl, the text utilities -- is another cross build between a change
  # and a boot. `pkgs.nix` is added back below because it is the payload.
  imports = [ ../illumos-base ];

  # See modules/system/boot/illumos-smf.nix. This is what turns the packaged
  # svc.startd and svc.configd from binaries in the image into a running init
  # system: it configures sockets, builds a writable repository under
  # /etc/svc/volatile, imports `system.build.smfManifests` and exec's startd.
  boot.illumos.smf.enable = true;

  # `nix.enable` is still off: that module is about the *distribution* story --
  # build users, sandboxing, a channel, a writable /nix -- none of which
  # applies to a read-only hsfs root running single-user. What is wanted here
  # is one daemon on one socket, so declare it directly through the portable
  # `init.services` layer, which modules/system/boot/init/portable/illumos.nix
  # renders into an SMF manifest.
  # `illumos-full` explains why this is `nixpkgs.overrideNix = false` rather
  # than the cppnix flake's build: that one forces oneTBB, which has no
  # Solaris support and refuses at *evaluation* time.
  nixpkgs.overrideNix = false;

  environment.systemPackages = [ pkgs.nix ];

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
