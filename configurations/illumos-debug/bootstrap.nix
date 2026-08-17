{
  lib,
  mkDerivation,

  headers,
  devfsadm,
  soconfig,

  # The program to hand the console to when the sequence is done. A package;
  # `lib.getExe` picks the binary. Null means "park after the last step",
  # which is what an unattended configuration wants -- and, more to the point,
  # it is what makes the shell OPTIONAL: pass null and no shell appears in
  # this derivation's references, so none appears in the boot archive either.
  shell ? null,

  # Optional network bring-up, as
  #
  #   { dlmgmtd = ...; ifconfig = ...; setaddr = ...;
  #     interface = "vioif0"; address = "10.0.2.15"; netmask = "255.255.255.0"; }
  #
  # Null by default, and that default is the interesting case. These paths are
  # baked into the binary, so nix's reference scanner makes every one of them
  # -- and its whole closure, libdladm and friends -- a dependency of this
  # package, and therefore of any boot archive that stages it. Under
  # `bootArchive.minimal` those packages are deliberately NOT staged (they are
  # meant to be reached over the virtio-fs store), so compiling them in would
  # cost the archive their closures in exchange for nothing.
  network ? null,
}:

# bootstrap(1) -- the boot sequence, as a program rather than a shell script.
#
# In nixbsd rather than in nixpkgs' `pkgs/os-specific/illumos`, and that line
# is worth drawing carefully, because the neighbouring `mountvfs`, `setaddr`,
# `klog` and `ditree` are all over there.
#
# Those are MECHANISM: general-purpose tools that any illumos system might use,
# in any order, for any purpose. "mount(2) with an explicit fstype" is a tool.
#
# This is POLICY. It encodes the boot sequence of THIS system: which
# directories to create, that devfsadm runs before soconfig, that the virtio-fs
# tag is `store` and that it mounts on /mnt/store. Those are configuration
# decisions, and they are exactly the decisions the /etc/profile in
# ./default.nix used to encode -- so its replacement belongs where that script
# lived, beside the configuration it serves, and nixpkgs' illumos set stays
# general-purpose tools.
#
# Built with `pkgs.illumos.callPackage`, so `mkDerivation` and `headers` are
# the illumos set's own -- the same cross compiler and the same gate headers
# every tool above is built with. No new machinery, just a different home.
#
# What it replaces: `illumos-debug` used to carry this sequence as an
# /etc/profile, read by the bash that `init-shell` execs. Two costs, and the
# second is the one that mattered.
#
# The size. bash and coreutils were BOOT dependencies -- roots of the minimal
# boot archive, which GRUB copies into RAM in full before unix is entered:
#
#   bash-interactive  6.3MB  -> readline 2.1MB -> ncurses 12.3MB
#   coreutils         3.1MB  -> libiconv 3.4MB
#                            -> gmp-with-cxx 2.0MB -> libstdc++ 9.5MB
#
# ~39MB of a 105MB staged closure, to run six commands, one of which is
# `mkdir`. None of it is needed here: mount(2), mkdir(2), fork/exec and
# open/read/write are libc, and libc and ld.so.1 are already mandatory because
# `PT_INTERP` and `DT_RUNPATH` are absolute store paths.
#
# The silence. A non-interactive shell profile continues past every failure
# without a word, and both bugs found on the day this was written were that
# and only that: `mkdir -p /mnt/store` never ran (PATH was exported on the
# LAST line, so every plain command was "command not found"), and the visible
# symptom was an empty /etc/mnttab -- which reads as a virtio-fs failure on a
# machine where virtio-fs had never been asked to do anything. `set -e` is not
# the fix; it converts "continues silently" into "stops silently". C checks
# each return and names the step.
#
# bash does not disappear from the system -- it moves from
# `bootArchive.minimalStorePaths` to `bootArchive.debugTools`, which is exactly
# the distinction that option exists to express: a failed mount must still
# leave a usable shell, but debugging must not be load-bearing for boot.
mkDerivation {
  pname = "illumos-bootstrap";
  noLibc = false;

  # No illumos source subtree; the C is here. `path` still has to name
  # something in the gate for the shared mkDerivation plumbing.
  path = "usr/src/lib/libc";

  buildInputs = [
    headers
  ];

  dontConfigure = true;

  # Every path this program will ever exec is fixed here, at build time. There
  # is no PATH lookup anywhere in the C, on purpose: the profile this replaces
  # had a PATH bug that took a day to find, and "which binary actually ran" is
  # not a question anybody should have to ask while debugging a boot.
  #
  # No -l flags: mount(2), fork(2) and the rest are all in libc.
  buildPhase = ''
    runHook preBuild
    $CC -O2 -o bootstrap \
        -DDEVFSADM='"${lib.getExe devfsadm}"' \
        -DSOCONFIG='"${lib.getExe soconfig}"' \
        -DSOCONFIG_DIR='"${soconfig}/etc/sock2path.d"' \
        ${lib.optionalString (shell != null) ''
          -DNEXT_PROG='"${lib.getExe shell}"' \
          -DNEXT_ARGV0='"${baseNameOf (lib.getExe shell)}"' \
        ''} \
        ${lib.optionalString (network != null) ''
          -DDLMGMTD='"${lib.getExe network.dlmgmtd}"' \
          -DDLMGMTD_SEED='"${network.dlmgmtd}/share/dlmgmtd/datalink.conf"' \
          -DIFCONFIG='"${lib.getExe network.ifconfig}"' \
          -DSETADDR='"${lib.getExe network.setaddr}"' \
          -DIFNAME='"${network.interface}"' \
          -DIFADDR='"${network.address}"' \
          -DIFMASK='"${network.netmask}"' \
        ''} \
        ${./bootstrap.c}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp bootstrap $out/bin/bootstrap
    chmod 755 $out/bin/bootstrap
    runHook postInstall
  '';

  meta = {
    description = "illumos boot sequence (remount, devfsadm, soconfig, virtio-fs) as a C program";
    mainProgram = "bootstrap";
  };
}
