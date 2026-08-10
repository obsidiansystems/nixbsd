{ ... }:
{
  imports = [ ../illumos-smf ];

  # See `boot.illumos.smf.debugShell`. With the real init there is no console
  # prompt by design -- /etc/inittab holds one `sysinit` line -- so a boot that
  # reaches userland and a boot that hangs are indistinguishable. This
  # configuration puts a shell on the console instead and leaves the SMF
  # bootstrap to be run by hand, as /lib/svc/bin/smf-bootstrap.
  boot.illumos.smf.debugShell = true;
}
