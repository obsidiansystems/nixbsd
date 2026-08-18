# Getting a shell in an illumos VM

```sh
cd ~/src/nixbsd
ILLUMOS_SSH_PORT=2222 nix run \
  --extra-experimental-features 'nix-command flakes' \
  --substituters 'https://cache.nixos.org' \
  --override-input nixpkgs git+file:/home/jcericson/src/nixpkgs-5 \
  -L '.#nixosConfigurations.illumos-full-virtiofs.config.system.build.vm' \
  -j20 --cores 20

# in another terminal
ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@127.0.0.1
```

No key, no password — root's `/etc/shadow` field is empty, which on illumos
means "no password required", and sshd is configured with
`PermitEmptyPasswords`. You get a real interactive shell; `tty` reports
`/dev/pts/N`.

`illumos-full-virtiofs` is the configuration with sshd. `illumos-base` has
almost no userland.

## Why it is open like this

It is a scratch VM reachable only through a qemu user-mode forward bound to
127.0.0.1, and the whole point is to be trivially enterable while the OS
underneath is the thing being debugged. **None of this belongs on a machine
with a real network path.**

A *real* password would need a hash illumos can verify, which is more work than
it sounds: `crypt(3C)` resolves a `$5$`/`$6$` prefix through
`/etc/security/crypt.conf` and the matching `/usr/lib/security/crypt_sha256.so.1`,
and the image ships neither. That leaves the built-in traditional DES
algorithm, which modern libxcrypt will not even generate. Empty sidesteps all
of it. Shipping `crypt_sha256` is a real option if a password is ever wanted —
it is `usr/src/lib/crypt_modules/sha256` plus the stock
`cmd/initpkg/security/crypt.conf`.

## The port

Random per run, 20000–39999, announced on stderr:

```
illumos VM: guest ssh port 22 -> localhost:29123
```

printed twice — once when chosen, once immediately before qemu starts, because
the first one scrolls away behind the boot log. `ILLUMOS_SSH_PORT` pins it.

It is random so several VMs can run at once. A fixed 2222 made the second VM
die with `Could not set up host forwarding rule 'tcp::2222-:22'`, which
produces a ~100-byte log that looks exactly like a boot failure — it cost three
debugging runs before anyone recognised it. If all 50 candidates look busy the
runner exits with a message rather than silently falling back to 2222.

To find the port of a VM already running: `ss -lntp | grep qemu`.

## Host keys change every boot

The guest regenerates its host keys each boot, so a plain `ssh` refuses to
reconnect with a host-key mismatch. Hence `-o StrictHostKeyChecking=no
-o UserKnownHostsFile=/dev/null`. Do not "fix" this by accepting the key into
`known_hosts`; you will be back here next boot.

## Keys, if you want them instead

`configurations/illumos-full/default.nix` also authorises one hard-coded key.
If it is not your machine's, key auth will simply fail — but password auth
still lets you in, so this is no longer a lockout.

## When it does not work

Each of these has actually been the cause:

1. **`PTY allocation request failed on channel 0`**, while `ssh host command`
   still works. OpenSSH's `configure` skips its `/dev/ptmx` test when cross
   compiling and silently compiles the BSD `/dev/ptyXX` path, which no illumos
   system has. Fixed in nixpkgs by defining `HAVE_DEV_PTMX` for `isSunOS`; if
   it returns, check with `strings $(command -v sshd) | grep /dev/pt` — you
   want `/dev/ptmx`, not `/dev/ptyp%d`.
2. **Is sshd online?** `svcs -a | grep ssh`, and `svcs -xv` for anything in
   maintenance.
3. **Has the guest got an address?** `ipadm show-addr` should show `vioif0/v4`.
   If not, look at `svcs network/physical` — the interface is plumbed by
   `dlmgmtd` and `ipmgmtd`, and *neither libdladm nor libipadm reads kernel
   state*; both ask over a door. A missing daemon looks exactly like a missing
   driver.
4. **Key rejected that looks correct?** `StrictModes`. sshd checks ownership
   and permissions of every directory on the path to `authorized_keys`, and the
   store here is a virtio-fs export of the host's `/nix/store`, mode
   `drwxrwxr-t root nixbld` — group-writable, which sshd rejects. That is why
   the key is staged as a real file in the boot archive rather than a store
   symlink.
5. **Console instead.** `console-login` runs on the serial console via
   `co::sysinit:` in `/etc/inittab`. If that line is ever `mkForce`d away, a
   working boot and a wedged boot produce identical (empty) output, because
   `svc.startd` logs to `/var/svc/log` rather than the console.

## What is not in the guest

Deliberately minimal, and it surprises people debugging: there is no `ps`,
`netstat`, `telnet`, `mount(8)`, `modinfo` or `strings`. `mountvfs` stands in
for `mount`. bash's `/dev/tcp` and `/proc` are often the only tools to hand.

## Device opens that fail as a daemon and work as root

If something opens a device node, works when you test it by hand, and fails
with `EACCES` once it runs as its own user — while `ls -l` shows the node
world-readable and world-writable — it is almost certainly the device
**policy**, not the permissions.

illumos checks two independent things on a device open. The mode bits are the
familiar one. The other is a privilege set from `/etc/security/device_policy`,
and until that file is loaded the kernel keeps its compiled-in default of *all
privileges required to open any device* (`uts/common/os/devpolicy.c:148`). Root
has all privileges, so root never notices.

Both that file and `/etc/minor_perm` are loaded by **`devfsadm -P`**, which is
the only caller of `load_dev_acl()`. A bare `devfsadm` loads neither — so
re-running `devfsadm` to test a theory proves nothing, and the data files look
correct while having no effect. The bootstrap runs the `-P` pass before the
populating run (`minor_perm` is consulted as nodes are created, so loading it
afterwards is too late for everything already made).

To check it is working: `grep 'devfsadm -P' <boot log>` should show
`bootstrap: devfsadm -P ok`, and a node with a `minor_perm` entry should show
that entry's mode — e.g. `ls -lL /dev/poll` → `crw-rw-rw- root sys`.

nginx is the worked example. It uses `/dev/poll` and nothing else — `use poll;`
and `use select;` are both rejected as `invalid event type`, so there is no
config workaround — and its worker setuids to `nginx`. The failure mode is
nasty: the worker dies, the master survives holding the listen socket, so SMF
reports `online`, `svcs -p` shows a process, port 80 accepts connections, and
every request returns nothing at all. The reason appears only in nginx's own
`error_log stderr`, which the service log does not capture; run it in the
foreground to see it. A healthy `svcs -p nginx` shows **two** processes.
