# illumos on nixbsd

An illumos system built entirely by nixpkgs, cross-compiled from Linux — kernel, libc, link-editor, runtime linker and userland — and booted under qemu.
There is no illumos machine anywhere in the process.

## Try it

```sh
nix run github:nixbsd/nixbsd#nixosConfigurations.illumos-full-virtiofs.config.system.build.vm
```

or from a checkout:

```sh
nix run .#nixosConfigurations.illumos-full-virtiofs.config.system.build.vm
```

It boots to a login prompt on the serial console in about 10 seconds.
The two forwarded ports are printed on stderr twice:
once when they are chosen, and once just before qemu starts,
because the first pair scrolls away behind the boot log.
(But my scrollback still gets messed up once the VM comes up, so I can't see them.
You might face the same issue.)

```
illumos VM: guest ssh port 22 -> localhost:31337
illumos VM: guest http port 80 -> localhost:24242
```

The ports are random so that several VMs can run at once.
Pin them with `ILLUMOS_SSH_PORT` and `ILLUMOS_HTTP_PORT`.
The works around the scrollback issue.

The VM console should do something like

```
+ /nix/store/lw64c5gkbwz816vw2g1nlja5lvrccqz1-svccfg-x86_64-unknown-solaris2.11-2.11/bin/svccfg import /lib/svc/manifest/milestone/multi-user.xml /lib/svc/manifest/milestone/network.xml /lib/svc/manifest/milestone/single-user.xml /lib/svc/manifest/network/datalink-management.xml /lib/svc/manifest/network/ip-interface-management.xml /lib/svc/manifest/network/physical.xml /lib/svc/manifest/site/hello.xml /lib/svc/manifest/site/nginx.xml /lib/svc/manifest/site/nix-daemon.xml /lib/svc/manifest/site/sshd.xml /lib/svc/manifest/site/suid-sgid-wrappers.xml /lib/svc/manifest/site/tempfiles.xml /lib/svc/manifest/system/console-login.xml /lib/svc/manifest/system/identity.xml /lib/svc/manifest/system/filesystem/local.xml /lib/svc/manifest/system/filesystem/minimal.xml
+ exec /lib/svc/bin/svc.startd

```

and then appear to hang.
That's normal, you connect to the machine via SSH.

## Log in

No password and no key: root's `/etc/shadow` field is empty, which on illumos means "no password required".

```sh
ssh -p 31337 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@127.0.0.1
```

The two `-o` flags are not optional in practice.
The guest regenerates its host keys every boot, so a plain `ssh` refuses to reconnect.
Do not "fix" that by accepting the key into `known_hosts`; you will be back next boot.

**This is a scratch VM reachable only through a qemu forward bound to 127.0.0.1.**
Being trivially enterable is the point while the OS underneath is the thing being debugged.
None of it belongs on a machine with a real network path.

## Fetch a page from nginx

nginx runs as an SMF service, and its port 80 is forwarded too:

```sh
curl -i http://127.0.0.1:24242/
```

```
HTTP/1.1 200 OK
Server: nginx
...
<h1>nginx is serving from illumos</h1>
```

## Look around

```sh
nixos-version           # 26.11.<date>.<hash> (Zokor)
svcs -a                 # 17 services online, nothing in maintenance
svcs -xv                # explains anything that is not
ipadm show-addr         # vioif0 has 10.0.2.15/24
uname -a                # SunOS 5.11 SunOS_Development i86pc i386 i86pc Solaris
nix --version           # nix runs, and nix-daemon is an SMF service
```

The guest is deliberately minimal.
There is no `ps`, `netstat`, `telnet`, `mount(8)`, `modinfo` or `strings`.
`mountvfs` stands in for `mount`, and bash's `/dev/tcp` and `/proc` are often the only tools to hand.

## The configurations

Two independent axes: how much userland, and where the Nix store lives.

| | store in the boot archive | store over virtio-fs |
|---|---|---|
| minimal userland | `illumos-base` | `illumos-base-virtiofs` |
| plus debugging bits | `illumos-debug` | `illumos-debug-virtiofs` |
| full (nix, sshd, nginx) | `illumos-full` | `illumos-full-virtiofs` |

`illumos-full-virtiofs` is the one to try first.
There are two further variants:

- **`illumos-full-virtiofs-direct`** boots through qemu's own multiboot loader (`-kernel`/`-initrd`) instead of GRUB on a virtual disk.
  That is about 3 s faster.
  It needs a qemu carrying `multiboot-page-align-modules.patch`, which nixpkgs applies here.
  This is similar to how NixOS tests work.

- **`illumos-base-virtiofs-root`** makes the host share the *root* filesystem, not just the store.
  It boots to a shell.
  The full version of this does not work yet; `svc.startd` starts and goes quiet.

Note that the store-location axis is not the filesystem type: both families use UFS for the boot archive.
The virtio-fs ones need a hypervisor, so the **non**-virtiofs configurations are the ones that could eventually boot on real hardware.

The virtiofs kernel module is newly vibe-coded blind.
I would not trust it in production!
But especially in read-only mode, it seems fine for testing.

## When it does not work

`doc/illumos-ssh.md` is the debugging companion to this file.
It covers the failure modes that have actually bitten:
PTY allocation, missing name-service plumbing, `StrictModes`,
and the device-policy trap where an `EACCES` opening a device as a daemon — but not as root — means `/etc/security/device_policy` was never loaded.
