{ lib, ... }:
{
  imports = [ ../illumos-base/default.nix ];

  # ../illumos-base/default.nix turns sshd off because nothing in the userland
  # is cross-compiled yet; mkForce it back on so that `svc:/site/sshd` gets
  # rendered to a service manifest. As with illumos-nginx this evaluates and
  # generates XML but cannot run: openssh is not built for illumos and the
  # kernel has no network stack.
  #
  # Compare usr/src/cmd/ssh/etc/ssh.xml in illumos-gate, which is what a
  # hand-written manifest for this service looks like; the generated one is
  # deliberately in the `site/` namespace rather than `network/ssh`, since it
  # is not the OS-delivered service.
  services.sshd.enable = lib.mkForce true;
}
