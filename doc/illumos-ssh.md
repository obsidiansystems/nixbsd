# Getting a shell in an illumos VM

Two ways in: the serial console (always works, no setup) and SSH (needs your
key in the config first). SSH is the one worth setting up — the console is a
single non-resizable terminal with no scrollback.

## The short version

OLD OF DATE just ssh root no password!

```sh
# 1. put your public key in the config (see "Authorising your key" below)
# 2. run the VM, pinning the port so you know where to connect
cd ~/src/nixbsd
ILLUMOS_SSH_PORT=2222 nix run \
  --extra-experimental-features 'nix-command flakes' \
  --substituters 'https://cache.nixos.org' \
  --override-input nixpkgs git+file:/home/jcericson/src/nixpkgs-5 \
  -L '.#nixosConfigurations.illumos-full-virtiofs.config.system.build.vm' \
  -j20 --cores 20

# 3. in another terminal
ssh -p 2222 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    root@127.0.0.1
```

`illumos-full-virtiofs` is the configuration with sshd; `illumos-base` has no
userland to speak of.

## Authorising your key

`configurations/illumos-full/default.nix` carries a single hard-coded key:

```nix
users.users.root.openssh.authorizedKeys.keys = [
  "ssh-ed25519 AAAAC3Nza...X92k jcericson@jcericson-2023-nixos"
];
```

If that is not your machine's key, **you will be refused and it will look like
sshd is broken**. Add yours to that list — `cat ~/.ssh/id_ed25519.pub`, or
generate a throwaway pair:

```sh
ssh-keygen -t ed25519 -N "" -f /tmp/vmkey -C "illumos-vm"
cat /tmp/vmkey.pub          # paste into authorizedKeys.keys
ssh -i /tmp/vmkey -p 2222 ... root@127.0.0.1
```

There is no password fallback. `/etc/shadow` is a literal in
`modules/system/boot/illumos-boot-image.nix` and gives root `NP` — "no
password, not locked" — so password authentication cannot succeed by design,
and `PermitRootLogin` is `prohibit-password`. `users.users.root.initialPassword`
does nothing here: nothing on the illumos boot path runs
`system.activationScripts`, because illumos boots straight into SMF.

## The port

The forwarded port is **random per run**, 20000–39999, and announced on stderr:

```
illumos VM: guest ssh port 22 -> localhost:29123
```

printed twice — once when chosen, once immediately before qemu starts, because
the first one scrolls away behind the boot log. Set `ILLUMOS_SSH_PORT` to pin
it.

It is random so several VMs can run at once. A fixed 2222 made the second VM die
with `Could not set up host forwarding rule 'tcp::2222-:22'`, which produces a
~100-byte log that looks exactly like a boot failure — it cost three debugging
runs before anyone recognised it. If all 50 candidate ports look busy the runner
now exits with a message rather than silently falling back.

To find the port of an already-running VM:

```sh
ss -lntp | grep qemu
```

## Host keys change every boot

The guest regenerates its host keys on each boot, so a plain `ssh` will refuse
to connect the second time with a host-key mismatch. Hence
`-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` above. Do not
"fix" this by accepting the key into `~/.ssh/known_hosts`; you will just be back
here next boot.

## When it does not work

Check these in order — each has actually been the cause at some point:

1. **Is sshd online?** On the console: `svcs -a | grep ssh`, and `svcs -xv` for
   anything in maintenance.
2. **Does the guest have an address?** `ipadm show-addr` should show
   `vioif0/v4` with `10.0.0.15/24` or similar. If not, look at
   `svcs network/physical` — the interface is plumbed by `dlmgmtd` and
   `ipmgmtd`, and *neither libdladm nor libipadm reads kernel state*; both ask
   over a door. A missing daemon looks exactly like a missing driver.
3. **Is it StrictModes?** sshd checks the ownership and permissions of every
   directory on the path to `authorized_keys`. The store here is a virtio-fs
   export of the host's `/nix/store`, mode `drwxrwxr-t root nixbld` — 
   group-writable, which sshd rejects. This is why the key is staged as a real
   file in the boot archive rather than as a store symlink. If you change how
   that file is delivered, expect this to come back, and the symptom is a
   rejected login with a correct-looking key.
4. **Console instead.** `console-login` runs on the serial console via
   `co::sysinit:` in `/etc/inittab`. If that line is ever `mkForce`d away, a
   working boot and a wedged boot produce identical (empty) output, because
   `svc.startd` logs to `/var/svc/log` rather than the console.
