# NixBSD
NixBSD is an attempt to make a reproducible and declarable BSD, based on [NixOS](https://nixos.org/).
Although theoretically much of this work could be copied to build other BSDs,
all work thus far has been focused on building a FreeBSD distribution.

## Structure
NixBSD has three main components

### Nix
Native FreeBSD Nix support is already upstream, and a fork is no longer necessary as of 2026.

### [Nixpkgs](https://github.com/rhelmot/nixpkgs/tree/freebsd-staging)
Most of the necessary Nixpkgs changes have already merged into upstream,
but a few changes are often needed during development of features.

### [NixBSD](https://github.com/nix-community/nixbsd)
This repository contains modules for building a system, like the `nixos` directory in nixpkgs.
When possible, modules are taken directly from nixpkgs without copying
(see references to `extPath` in [module-list](modules/module-list.nix).

Some modules are copied with modification from nixpkgs. The original files remain under the [MIT License](https://github.com/NixOS/nixpkgs/blob/master/COPYING) and copyright the original contributors.

Unfortunately, upstreaming NixBSD into NixOS would require a fair amount of reorganization and changes to init systems,
so is unlikely to happen anytime soon.

### freebsd-src
You may notice that there is no fork of [freebsd-src](https://cgit.freebsd.org/src/about/).
The changes required to FreeBSD code are minimal and concern mostly the build system,
so are included as [patches](https://github.com/rhelmot/nixpkgs/tree/freebsd-staging/pkgs/os-specific/bsd/freebsd/patches) in nixpkgs, or as calls to `sed` in package files.

## Building
The easiest way to test module changes is to build a virtual machine from Linux.

You can build sample configurations (directories in [configurations](configurations))
easily with the flake output `.#<configName>.<outputName>`.
The `base` configuration provides a simple starting point with a user account and default services.

All outputs from `system.build` are available, plus a few more. When developing you may want:

* `toplevel`: Top-level derivation, containing the kernel, etc, software, activation script, and more.
  You'll find it linked in the VM image at `/run/current-system` after activation.
* `vm`: A script that runs a virtual machine containing the `toplevel`, booted with UEFI. The system is booted from a writable CoW copy, so activation will run and you can edit files
* `closureInfo`: The closure-info of `toplevel.drvPath`.
* `vmClosureInfo`: the closure-info of `vm.drvPath`.

The `closureInfo` and `vmClosureInfo` outputs include metadata about the [build closure](https://zero-to-nix.com/concepts/closures), including a list of all packages. Keeping a copy of this around will prevent nix from garbage-collecting all of your builds.

### Subtituter
There is a substituter (binary cache) in the flake.
If Artemis remembers, this should contain everything in `.#base.vmClosureInfo` and
could save you a few hours.

Note, however, that trusted substituters can maliciously modify outputs, so only use it if you trust Artemis.

### Tips
* Building `vmImageRunner` for a minimal configuration can take over 8 hours on a fast machine, so keeping around `vmClosureInfo` is highly recommended. Just `base.vmClosureInfo` takes over 30GiB though, so you may want to delete it if you're low on space.
* Some package checks may fail intermittently under heavy load. If that happens you may want to build with `--max-jobs 4` or lower so fewer packages are competing for the CPU at the same time.
* To see what is happening, you might want to use [nix-output-monitor](https://github.com/maralorn/nix-output-monitor). For flake commands you can replace `nix` with `nom` to use it.

### Amazon Machine Images
Importing [`modules/virtualisation/amazon-image.nix`](modules/virtualisation/amazon-image.nix)
(see the [`amazon`](configurations/amazon) configuration) gives you a system that
boots on EC2 with UEFI, the ENA network driver, and a serial console. Amazon's
metadata service is consumed by [cloud-init](https://cloud-init.io/), which puts
the SSH key chosen at launch on `root`, grows the root filesystem to the EBS
volume, and runs any user-data scripts.

```shell
# Raw GPT disk image with the ESP and a UFS root
nix build .#amazon.amazonImage
# Upload to S3, import as an EBS snapshot, and register a UEFI AMI.
# The account needs the `vmimport` service role.
nix run .#amazon.uploadAmazonImage -- --bucket my-bucket --region us-east-1
```

## Contributing
We'd be happy to review any pull requests! If you have any problems please open an issue on this repo, we're using this issue tracker for nix and nixpkgs issues as well.

Contributions should be formatted with [nixfmt](https://github.com/serokell/nixfmt). While you can use `nix fmt`,
that will rebuild the universe. You may want to run `nix-shell -p nixfmt --run "nixfmt ."` instead.

## tldr
In your nixbsd checkout:
```shell
# Build the VM and all dependencies, make sure Nix doesn't delete them
# Will likely take several hours
nix build .#base.vmClosureInfo --out-link .gcroots/vm
# Build the VM (actual build happened last step, should only take a few seconds)
nix build .#base.vm
# Run a VM
result/bin/run-nixbsd-base-vm
# login as root:toor or bestie:toor
```

or to just build and try a VM to play with without a local checkout:
```shell
nix run 'github:nixos-bsd/nixbsd#extra.vm'
```
but see the above warning about substituter trust before accepting the requested substituter.
This will put VM state files in the current directory.
