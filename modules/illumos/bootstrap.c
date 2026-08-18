/*
 * bootstrap -- the six things that have to happen between the kernel exec'ing
 * init and the system being usable, done in C so that each one can fail
 * loudly.
 *
 * This replaces a shell script. `illumos-debug` used to carry the same
 * sequence as an /etc/profile, read by the bash that `init-shell` execs as a
 * login shell, and that arrangement was wrong twice over:
 *
 *   * It made bash and coreutils BOOT dependencies. They are roots of the
 *     minimal boot archive, and their closures -- ncurses 12.3MB, libstdc++
 *     9.5MB (coreutils -> gmp-with-cxx), bash-interactive 6.3MB, libiconv
 *     3.4MB, coreutils 3.1MB, gmp 2.0MB, readline 2.1MB -- come to ~39MB of a
 *     105MB staged closure. The archive is a multiboot module, so GRUB copies
 *     every one of those bytes into RAM before unix is entered. Six commands
 *     are not worth 39MB and a C++ runtime.
 *
 *   * A non-interactive shell profile has no error handling at all, and
 *     `set -e` is not the fix -- it turns "continues silently" into "stops
 *     silently". Two bugs found in one day, both of which this file makes
 *     impossible rather than merely unlikely:
 *
 *       - `mkdir -p /mnt/store` never ran, because the profile called mkdir by
 *         bare name and exported PATH on its LAST line. Every plain command in
 *         the file was "command not found", printed nowhere, and the visible
 *         symptom was an empty /etc/mnttab -- which reads as a virtio-fs
 *         failure, on a machine where virtio-fs had never been asked to do
 *         anything. Here there is no PATH: mkdir is mkdir(2).
 *
 *       - failures in the middle of the sequence were invisible, so the first
 *         thing anyone knew about them was a symptom several steps downstream.
 *         Here every step names itself and prints strerror(errno).
 *
 * The policy on failure is per-step and deliberate, not uniform. Steps that
 * everything downstream depends on (the read-write remount) are fatal in the
 * sense that they are reported as fatal and the rest is attempted anyway;
 * steps that only some later thing needs (soconfig, the network) must NOT stop
 * the virtio-fs mount, because the mount is what makes the machine debuggable
 * and it needs no network and no sockets. What is never acceptable is silence:
 * a skipped step says so on stderr, with the reason.
 *
 * Paths are baked in at build time as -D defines (see bootstrap.nix). Nothing
 * here searches PATH, because there is no PATH worth searching this early and
 * because "which binary actually ran" is precisely the question that cost the
 * day described above.
 */

#include <sys/mount.h>
#include <sys/mntent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * The ramdisk the kernel booted from. ufs_mountroot() mounted it for
 * ROOT_INIT, which sets VFS_RDONLY, so / is read-only until step 1 runs. This
 * is a /devices path rather than a /dev one on purpose: /dev is populated by
 * devfsadm, and devfsadm is step 3.
 */
#ifndef	ROOT_SPECIAL
#define	ROOT_SPECIAL	"/devices/ramdisk:a"
#endif

#ifndef	STORE_TAG
#define	STORE_TAG	"store"
#endif

/*
 * Where the store lands.
 *
 * /nix/store, and the address is the whole point rather than a detail:
 * everything staged in the boot archive lives at its REAL store path, because
 * PT_INTERP and DT_RUNPATH are absolute. A store mounted anywhere else
 * resolves none of them -- it proves the transport works and runs nothing.
 * That is what /mnt/store, the first mountpoint this used, bought: a
 * `illumos-base-virtiofs` whose init started and then could not exec /sbin/sh,
 * because the shell it names is in /nix/store and /nix/store was the archive
 * copy with nothing in it.
 *
 * Mounting over the archive's own /nix/store is safe, and is not a trick: the
 * host directory is a SUPERSET of it. Everything the archive staged was built
 * on the host and is still there under the same path, and anything already
 * mapped -- ld.so.1 and libc, which this program is running out of -- keeps
 * the mapping it opened before the mount.
 *
 * STORE_PARENT is spelled separately because mkdir(2) creates one level; see
 * the dirs[] list.
 */
#ifndef	STORE_DIR
#define	STORE_DIR	"/nix/store"
#endif

#ifndef	STORE_PARENT
#define	STORE_PARENT	"/nix"
#endif

/*
 * The directories that must exist before anything else works, in the order
 * they are needed. Not a general-purpose list -- each entry is here because
 * something concrete failed without it:
 *
 *   /etc/svc/volatile/dev  devfsadm's state and lock directory. /etc/dev is a
 *                          SYMLINK to this (see the boot archive's `symlinks`),
 *                          because /etc is read-only in the image and devfsadm
 *                          refuses to run without somewhere to put its lock:
 *
 *                              devfsadm: mkdir failed for /etc/dev 0x1ed:
 *                                  Read-only file system
 *
 *                          THE TRAP: `mkdir -p /etc/dev` does not create this.
 *                          mkdir(2) on the symlink returns EEXIST -- the link
 *                          exists -- and the target is never made. The path
 *                          below is the target, spelled out, for that reason.
 *   /etc/dladm             dlmgmtd wants a writable datalink.conf here.
 *   /var/run               conventional, and several daemons assume it.
 *   /var/empty             sshd's privilege-separation chroot.
 *   /nix, /nix/store       the virtio-fs mountpoint. mount(2) does not create
 *                          its target; without this the mount fails ENOENT and
 *                          looks like a transport problem. Both exist in the
 *                          boot archive already -- the staged closure is at its
 *                          real store path -- so these two are almost always
 *                          EEXIST. They are named anyway because "almost" is
 *                          not a property to bet a boot on.
 */
#ifdef	ROOT_VIRTIOFS
/*
 * With a virtio-fs root there is no writable filesystem on the machine at all
 * except the tmpfs vfs_mountroot() puts on /etc/svc/volatile -- the host
 * exports the share read-only, virtiofs_mountroot() sets VFS_RDONLY, and
 * ROOT_REMOUNT is a deliberate no-op.  So the list above cannot be used as it
 * stands: every entry under /etc or /var would be EROFS, and the ones that
 * matter would be missing rather than merely noisy.
 *
 * What replaces it is: mount tmpfs on /var, /tmp and /run first (see
 * mount_tmpfs() and mount_run()), then make the directories INSIDE those.
 * /etc entries are not here at all -- anything under /etc that has to be
 * writable is a symlink into /etc/svc/volatile, staged into the exported root
 * tree the same way /etc/dev already is for devfsadm.
 *
 * /nix and /nix/store are NOT here, and their absence is the same reasoning
 * inverted.  mount(2) does not create its target, so on a ramdisk root they
 * are named defensively; on this one they cannot be created at all -- /nix is
 * on the read-only export -- so naming them buys two guaranteed EROFS
 * failures on every boot and no protection whatsoever.  The exported root
 * tree carries them instead (`system.build.illumosRootTree`), which is where
 * a mount point on a read-only root has to come from.
 */
static const char *const dirs[] = {
	"/etc/svc/volatile/dev",
	"/etc/svc/volatile/dladm",
	"/var/run",
	"/var/empty",
	"/var/adm",
	"/var/tmp",
	"/var/log",
	"/var/svc",
	"/var/svc/log",
	"/var/svc/manifest",
	"/var/svc/profile",
	NULL
};
#else
static const char *const dirs[] = {
	"/etc",
	"/etc/svc",
	"/etc/svc/volatile",
	"/etc/svc/volatile/dev",
	"/etc/dladm",
	"/var",
	"/var/run",
	"/var/empty",
	STORE_PARENT,
	STORE_DIR,
	NULL
};
#endif	/* ROOT_VIRTIOFS */

static int failures = 0;

/*
 * Consoles to try when this program is pid 1 and nobody has given it any file
 * descriptors -- the same list, in the same order, as init-shell.c's.
 *
 * The /dev names come first and will not exist yet (devfsadm is step 3, and
 * this runs before it), so in practice it is the /devices path that answers.
 * They are kept anyway: they are what a system that has already run devfsadm
 * would have, and trying them costs one open(2) that fails.
 */
static const char *const consoles[] = {
	"/dev/console",
	"/dev/msglog",
	"/devices/pci@0,0/isa@1/asy@1,3f8:a",
	"/devices/isa/asy@1,3f8:a",
	NULL
};

/*
 * Make sure this program can be heard.
 *
 * There are two ways in, and only one of them arrives with a console. When a
 * configuration puts a shell on the console, `init-shell` is /sbin/init: it
 * opens the console, pushes ldterm, makes it the controlling terminal and dups
 * it onto 0/1/2 before exec'ing this -- so there is nothing to do here, and
 * this function must not interfere.
 *
 * When a configuration runs a REAL init, this program IS /sbin/init: the
 * kernel execs it with no file descriptors open at all, so every say() below
 * writes to a closed fd 2, fails EBADF, and the entire boot sequence runs in
 * silence. That is not a theoretical loss. Silence at exactly this point is
 * what made a `bootArchive.minimal` configuration that mounted nothing at all
 * look like a kernel hang.
 *
 * O_NOCTTY, and no setsid()/TIOCSCTTY/I_PUSH: this process is about to become
 * the system's real init, and session leadership and line discipline are its
 * business, not ours. The cost is \n-only output on a raw asy(4D) stream, so a
 * terminal that does not translate will stair-step it -- legible in a log,
 * which is what this is for.
 */
static void
ensure_console(void)
{
	int i, fd;

	if (fcntl(2, F_GETFD) >= 0)
		return;

	for (i = 0; consoles[i] != NULL; i++) {
		if ((fd = open(consoles[i], O_RDWR | O_NOCTTY)) < 0)
			continue;

		(void) dup2(fd, 0);
		(void) dup2(fd, 1);
		(void) dup2(fd, 2);
		if (fd > 2)
			(void) close(fd);
		return;
	}

	/*
	 * Nothing to say anything on. Carry on regardless: the steps below are
	 * what makes the machine work, and none of them needs a console.
	 */
}

/*
 * Everything this program says goes to stderr, unbuffered by fprintf's usual
 * line discipline on a tty but flushed anyway: the console here is a bare
 * asy(4D) stream, and a boot that panics or hangs with a message still sitting
 * in a stdio buffer is a boot that told you nothing.
 */
static void
say(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	(void) vfprintf(stderr, fmt, ap);
	va_end(ap);
	(void) fflush(stderr);
}

static void
step_failed(const char *what, int err)
{
	failures++;
	say("bootstrap: FAILED: %s: %s\n", what, strerror(err));
}

#ifdef	ROOT_VIRTIOFS
/*
 * Mount a tmpfs.
 *
 * This is the whole answer to "where does writable state live" on a machine
 * whose root is a read-only virtio-fs share.  The SMF repository, /var/run,
 * /var/adm/utmpx, sshd's host keys, every service log and /tmp all need a
 * filesystem that can be written, and with the root on the host's export
 * there is exactly one such filesystem in the kernel already -- the tmpfs
 * vfs_mountroot() puts on /etc/svc/volatile -- and it is the wrong shape and
 * the wrong place for most of that.
 *
 * tmpfs rather than the ramdisk, and the ramdisk really is the alternative:
 * the boot archive is still loaded (it is still a multiboot module, it is
 * still `boot.illumos.rootfs`) and /devices/ramdisk:a is still a mountable
 * UFS filesystem sitting in memory.  Two reasons not to use it.  It is a
 * FIXED size, chosen at build time from the size of the staged tree, and
 * `boot.illumos.rootfsHeadroom` exists because guessing that size wrong is
 * how `illumos-full-virtiofs` met "NOTICE: alloc: /: file system full"
 * seconds into svc.startd's manifest import.  And it is the image the system
 * would have booted from, so writing to it destroys the one artifact worth
 * comparing against when the virtio-fs root misbehaves.  tmpfs grows on
 * demand out of the same memory and costs nothing when unused.
 *
 * The special is "swap", which is what tmpfs is conventionally given and what
 * mnttab will show; tmpfs itself ignores it.  MS_OPTIONSTR for the same
 * in/out-buffer reason as every other mount in this file -- the kernel writes
 * the canonical option string back, so the buffer must be writable and
 * MAX_MNTOPT_STR long or the call returns EOVERFLOW having done nothing.
 *
 * No size= option deliberately: tmpfs then bounds itself by available
 * memory, which on a VM with no swap is the honest limit.  Naming a number
 * here would reintroduce exactly the fixed-ceiling problem that the ramdisk
 * has.
 */
static void
mount_tmpfs(const char *dir)
{
	char optbuf[MAX_MNTOPT_STR];

	optbuf[0] = '\0';

	if (mount("swap", dir, MS_OPTIONSTR, "tmpfs", NULL, 0, optbuf,
	    sizeof (optbuf)) != 0) {
		step_failed("mount tmpfs on", errno);
		say("bootstrap:   (%s: nothing below can write there)\n", dir);
		return;
	}

	say("bootstrap: mounted tmpfs on %s [%s]\n", dir, optbuf);
}
#endif	/* ROOT_VIRTIOFS */

/*
 * Remount / read-write.
 *
 * ufs_mountroot() mounts the root for ROOT_INIT, which leaves VFS_RDONLY set,
 * and sdev's backing store IS the root filesystem -- so until this returns,
 * devfsadm cannot create a single node and /etc cannot be written. Every step
 * after this one depends on it, which is why it is first.
 *
 * The shell version shelled out to `mount-ufs`'s /lib/fs/ufs/mount, illumos'
 * per-filesystem mount helper. That is a whole package (and a whole exec) to
 * issue one mount(2), and the helper's own remount path is exactly this call:
 * see cmd/fs.d/ufs/mount/mount.c, which sets MS_REMOUNT from the `remount`
 * option at :430 and calls mount() with MS_DATA|MS_OPTIONSTR at :512,:550.
 *
 * Three flags, each load-bearing:
 *
 *   MS_REMOUNT    ufs_mount() turns this into `why = ROOT_REMOUNT`
 *                 (uts/common/fs/ufs/ufs_vfsops.c:382), which is what lets it
 *                 mount over a VROOT vnode at all -- without it the EBUSY
 *                 check at :285 rejects the call.
 *   MS_DATA       says "six-argument mount", and without it (or MS_FSS)
 *                 domount() reads `fstype` as an INDEX into vfssw[] rather
 *                 than as a name (uts/common/fs/vfs.c:1175-1200). We pass no
 *                 fs-specific data; ufs_mount() copies args only when
 *                 `data != NULL && datalen != 0` (:297), and treats a zero
 *                 datalen as "defaults" (:590), so NULL/0 is correct here.
 *   MS_OPTIONSTR  makes optptr an in/out buffer -- see below.
 *
 * The MS_OPTIONSTR contract is the one that bites (mountvfs.c says the same,
 * from the same scar): `optptr` is used for INPUT AND OUTPUT. The kernel
 * writes the filesystem's canonical option string back into it, so it must be
 * writable -- a string literal is a segfault -- and MAX_MNTOPT_STR long, or
 * the mount returns EOVERFLOW having done nothing.
 */
static void
remount_root_rw(void)
{
	char optbuf[MAX_MNTOPT_STR];

	(void) strlcpy(optbuf, "remount,rw", sizeof (optbuf));

	if (mount(ROOT_SPECIAL, "/", MS_REMOUNT | MS_DATA | MS_OPTIONSTR,
	    "ufs", NULL, 0, optbuf, sizeof (optbuf)) != 0) {
		step_failed("remount / read-write", errno);
		say("bootstrap:   (everything below needs a writable root; "
		    "expect it all to fail)\n");
		return;
	}

	say("bootstrap: / remounted read-write [%s]\n", optbuf);
}

#ifdef	ROOT_VIRTIOFS
/*
 * tmpfs on /run, with /run/current-system carried across it.
 *
 * /run is not merely conventional here: services write into it. nginx does
 * `mkdir -p /run/nginx` and then opens /run/nginx/nginx.pid; the suid-sgid
 * wrappers service builds its whole bin directory under /run/wrappers. On the
 * read-only export both fail, and the failures do not look like a read-only
 * root -- what reaches the log is
 *
 *     nginx: [emerg] open() "/run/nginx/nginx.pid" failed (2: No such file...)
 *     ln: failed to create symbolic link '/run/wrappers/bin' -> ''
 *
 * with nginx then restarting about once a second for ever. So /run gets the
 * same treatment as /var and /tmp.
 *
 * The complication is that /run is not empty on the export: the boot archive
 * stages /run/current-system pointing at the system closure (see
 * `bootArchive.symlinks` in illumos-boot-image.nix), and a tmpfs mounted over
 * /run would hide it. Rather than teach this program the toplevel path -- it
 * has no business knowing it -- read the link before the mount and write it
 * back afterwards. If it is not there, there is nothing to preserve and the
 * mount is all that happens.
 */
static void
mount_run(void)
{
	char target[PATH_MAX];
	ssize_t n;

	n = readlink("/run/current-system", target, sizeof (target) - 1);
	if (n > 0)
		target[n] = '\0';

	mount_tmpfs("/run");

	if (n > 0 && symlink(target, "/run/current-system") != 0 &&
	    errno != EEXIST)
		step_failed("symlink /run/current-system", errno);
}

/*
 * Give /dev a writable attribute store.
 *
 * This is the second half of the writability problem, and the half that is not
 * obvious. /dev is a `dev` filesystem, mounted by vfs_mountroot() long before
 * this program runs, so it looks like it should be writable whatever the root
 * is. It is not. sdev keeps the persistent half of every node -- the symlinks
 * devfsadm creates, and the modes and owners minor_perm asks for -- in a
 * BACKING DIRECTORY in the underlying filesystem, and sdev_mount() defaults
 * that directory to the mount point itself (`avp = mvp`, sdev_vfsops.c:260).
 * With the root on a read-only virtio-fs share the mount point is on that
 * share, so every link devfsadm tries to make fails:
 *
 *     devfsadm: symlink failed for /dev/tcp -> ../devices/pseudo/udp@0:tcp:
 *         Read-only file system
 *     devfsadm: devlink cache does not exist
 *
 * and the damage is not confined to /dev. soconfig(8) then cannot open
 * /dev/ticotsord, /dev/ticlts or /dev/udp, so the socket-to-transport
 * mappings never load, so socket(AF_INET, ...) fails at CREATION -- and every
 * networking symptom downstream points at a driver that is working fine.
 *
 * sdev has a mount option for exactly this: `sdev_attrdir`, a path to use as
 * the attribute store instead of the mount point (sdev_vfsops.c:242). Nothing
 * in userland passes it -- there is no /usr/lib/fs/dev/mount -- so this is
 * mount(2) with the private argument struct, which is one uint64_t holding a
 * pointer to the path. Declared here rather than included: <sys/fs/sdev_impl.h>
 * is a kernel-private header that is not shipped in the headers package, and
 * the struct is a single field pinned by the copyin's `datalen != sizeof`
 * check (sdev_subr.c:2268).
 *
 * MS_REMOUNT because /dev is already mounted, and the remount path is what
 * swaps the attribute vnode (sdev_vfsops.c:303-304) after marking the existing
 * nodes stale. devfsadm runs immediately after this and rebuilds them.
 *
 * The store goes on /etc/svc/volatile, the tmpfs vfs_mountroot() mounts before
 * any of this -- NOT on the /var tmpfs above, deliberately. /dev has to work
 * even if the /var mount failed, because a machine with no /dev/console has no
 * way to say that it did.
 */
struct bootstrap_sdev_mountargs {
	uint64_t sdev_attrdir;
};

#define	DEV_ATTRDIR	"/etc/svc/volatile/dev-attr"

static void
dev_attrdir(void)
{
	struct bootstrap_sdev_mountargs args;
	static char path[] = DEV_ATTRDIR;
	char optbuf[MAX_MNTOPT_STR];

	if (mkdir(DEV_ATTRDIR, 0755) != 0 && errno != EEXIST) {
		step_failed("mkdir " DEV_ATTRDIR, errno);
		return;
	}

	/*
	 * THE RELATIVE-SYMLINK TRAP, found the hard way and worth describing,
	 * because the symptom is a file that is visibly there and cannot be
	 * opened:
	 *
	 *     illumos# ls -l /dev/null
	 *     lrwxrwxrwx 1 root root 27 /dev/null -> ../devices/pseudo/mm@0:null
	 *     illumos# cat /devices/pseudo/mm@0:null
	 *     illumos# cat /dev/null
	 *     cat: /dev/null: No such file or directory
	 *
	 * Every /dev entry devfsadm makes is a RELATIVE symlink -- /dev/null is
	 * "../devices/pseudo/mm@0:null", /dev/sad/user is
	 * "../../devices/pseudo/sad@0:user" -- so all of them depend on ".."
	 * from /dev leading to "/".  After the remount above it does not:
	 *
	 *     illumos# ls -a /dev/..
	 *     allkmem  arp  conslog  console  cua  cua0  ...
	 *
	 * that is the content of /dev itself.  sdev's root is its own
	 * sdev_dotdot (sdev_vfsops.c:286), and crossing a VROOT on ".." is the
	 * VFS layer's job, done through vfs_vnodecovered -- which after this
	 * remount points at the previous /dev rather than at the directory
	 * underneath it.  It is not clear that a mount(2) can arrange
	 * otherwise: there is no unmount-and-remount available, because
	 * everything holding /dev open at this moment is this process.
	 *
	 * So make ".." right instead of fighting it.  With ".." meaning /dev,
	 * "../devices" means /dev/devices, and one symlink in the attribute
	 * store puts it there.  The same link serves the subdirectories:
	 * "../../devices" from /dev/sad walks to /dev twice and lands in the
	 * same place.
	 *
	 * It costs one visible entry, /dev/devices, which is a real cost and
	 * is written down here rather than hidden.  What it buys is
	 * /dev/null -- and svc.startd exits outright without that, taking SMF
	 * and the whole system with it.
	 */
	if (symlink("/devices", DEV_ATTRDIR "/devices") != 0 &&
	    errno != EEXIST)
		step_failed("symlink " DEV_ATTRDIR "/devices", errno);

	args.sdev_attrdir = (uint64_t)(uintptr_t)path;
	optbuf[0] = '\0';

	/*
	 * A FRESH MOUNT, NOT MS_REMOUNT, and this is the difference between a
	 * machine with a network and one without.
	 *
	 * /dev/net, /dev/ipnet and /dev/pts are not devfsadm symlinks. They are
	 * DYNAMIC directories synthesised by the kernel -- `vtab[]` in
	 * sdev_subr.c marks them SDEV_DYNAMIC, and their contents come from
	 * devnet_vnodeops and friends rather than from any backing store. The
	 * one and only thing that creates them is sdev_filldir_dynamic(), and
	 * sdev_mount() calls it from exactly one place: the initial-mount path,
	 * at sdev_vfsops.c:363.
	 *
	 * The MS_REMOUNT path never gets there. It does sdev_stale() on the
	 * root -- which deletes every entry, the dynamic directories included,
	 * and sets SDEV_BUILD -- swaps sdev_attrvp, and `goto cleanup`s out
	 * (sdev_vfsops.c:281-306). The rebuild that SDEV_BUILD then triggers is
	 * sdev_filldir(), which reads the ATTRIBUTE STORE. Nothing in the
	 * attribute store is named `net`, nothing ever will be, and devfsadm
	 * cannot help: it does not create these directories either.
	 *
	 * So a remounted /dev loses /dev/net permanently, and the symptom is a
	 * networking one with no networking in it. libdlpi's dlpi_open() opens
	 * /dev/net/<link>; without the directory it fails, and what reaches the
	 * console is
	 *
	 *     ifconfig: cannot plumb vioif0: Could not open DLPI link
	 *     ifconfig: error: vioif0: no such interface
	 *
	 * from an `svc:/network/physical:default` that then exits 0 and goes
	 * online. Everything else works -- svc.startd, svc.configd, sshd all
	 * come up, sshd really is listening on 22 -- and the machine is simply
	 * unreachable, because the NIC never got an address. `/dev/vioif0` is
	 * present the whole time (devfsadm makes that one), which is the detail
	 * that sends you looking at the driver.
	 *
	 * Mounting a second `dev` instance over /dev takes the initial-mount
	 * path instead: sdev_mkroot() sees the mount point spelled "/dev" and
	 * sets SDEV_GLOBAL (sdev_subr.c:473), so sdev_filldir_dynamic() runs
	 * and the dynamic directories exist. The old instance stays underneath,
	 * covered and unreferenced; nothing unmounts it, because everything
	 * holding /dev open at this moment is this process.
	 *
	 * The `..` trap described above is unchanged by this and is handled the
	 * same way -- vfs_vnodecovered points at the previous /dev either way,
	 * and the same DEV_ATTRDIR/devices symlink makes "../devices" land in
	 * the right place.
	 *
	 * MS_REMOUNT is kept as a fallback rather than deleted. It is what this
	 * code did before, it does produce a writable /dev, and a machine that
	 * boots without a network is worth more than one that does not boot.
	 */
	if (mount("/dev", "/dev", MS_DATA | MS_OPTIONSTR | MS_OVERLAY, "dev",
	    (char *)&args, sizeof (args), optbuf, sizeof (optbuf)) == 0) {
		say("bootstrap: /dev attribute store on %s [%s]\n",
		    DEV_ATTRDIR, optbuf);
		return;
	}

	say("bootstrap: /dev fresh mount failed (%s); falling back to "
	    "remount\n", strerror(errno));

	optbuf[0] = '\0';

	if (mount("/dev", "/dev", MS_REMOUNT | MS_DATA | MS_OPTIONSTR, "dev",
	    (char *)&args, sizeof (args), optbuf, sizeof (optbuf)) != 0) {
		step_failed("remount /dev with an attribute store", errno);
		say("bootstrap:   (devfsadm will create nothing: /dev's "
		    "backing store is the read-only root)\n");
		return;
	}

	say("bootstrap: /dev attribute store on %s [%s] -- REMOUNTED, so "
	    "/dev/net does not exist and the NIC cannot be plumbed\n",
	    DEV_ATTRDIR, optbuf);
}

/*
 * Make the freshly-repopulated /dev resolvable by name.
 *
 * The remount above calls sdev_stale() on every node under the /dev root
 * (sdev_vfsops.c:290), which is correct -- the old nodes were attributed
 * against the read-only root -- but it means that immediately afterwards a
 * plain open("/dev/null") can fail ENOENT even though devfsadm has just
 * created the link and a readdir of /dev shows it. Reading the directory is
 * what walks the stale list and revalidates it.
 *
 * This is not a cosmetic race. /dev/null in particular is opened by the very
 * next thing to run: smf-bootstrap redirects to it, and svc.startd exits
 * outright --
 *
 *     svc.startd: can't connect stdin to /dev/null: No such file or directory
 *
 * -- taking SMF, and therefore the whole system, with it. So sweep the
 * directory here, where the cost is one readdir and the failure is still
 * attributable, rather than leaving it to whichever consumer happens to be
 * first.
 *
 * The open() at the end is a check, not a fix: it names the one node whose
 * absence is fatal, so that if this ever stops being sufficient the log says
 * so at the point of the sweep instead of three programs later.
 */
static void
settle_dev(void)
{
	DIR *d;
	int n = 0, fd;

	if ((d = opendir("/dev")) == NULL) {
		step_failed("opendir /dev", errno);
		return;
	}
	while (readdir(d) != NULL)
		n++;
	(void) closedir(d);

	if ((fd = open("/dev/null", O_RDWR)) < 0) {
		step_failed("open /dev/null after devfsadm", errno);
		say("bootstrap:   (svc.startd will not start without it)\n");
		return;
	}
	(void) close(fd);

	say("bootstrap: /dev settled, %d entries, /dev/null opens\n", n);
}
#endif	/* ROOT_VIRTIOFS */

/*
 * mkdir -p, minus the -p.
 The list above is fully expanded -- every parent is
 * named -- so this is a plain mkdir(2) per entry with EEXIST accepted.
 *
 * Written this way rather than as a path-splitting mkdirp() because of the
 * /etc/dev trap in the comment on `dirs`: a real `mkdir -p` follows symlinks
 * in the path it walks, and the whole reason this list exists is that doing so
 * silently creates nothing. An explicit list cannot make that mistake, and it
 * documents itself.
 */
static void
make_dirs(void)
{
	int i;

	for (i = 0; dirs[i] != NULL; i++) {
		if (mkdir(dirs[i], 0755) == 0)
			continue;
		if (errno == EEXIST)
			continue;
		step_failed(dirs[i], errno);
	}
}

/*
 * fork/exec one of the compiled-in helpers and wait for it.
 *
 * `path` is an absolute store path from a -D define, never a PATH lookup: on
 * this system PATH is whatever init-shell compiled in, /bin and /usr/bin are
 * symlink farms that may not exist yet, and "which binary ran" is not a
 * question anyone should have to ask while debugging a boot.
 *
 * Returns 0 if the child exited 0. Anything else is reported here -- including
 * the distinction between "did not exec" and "exec'd and failed", which the
 * shell version erased by sending both to /dev/null.
 */
static int
run(const char *what, const char *path, char *const argv[],
    char *const envp[])
{
	pid_t pid, got;
	int status;

	if (access(path, X_OK) != 0) {
		/*
		 * Not fatal and not silent. Under `bootArchive.minimal` some of
		 * these packages are deliberately not staged -- they are meant
		 * to be reached over the very mount this program is on its way
		 * to performing -- so a missing helper is an expected state
		 * that must still be visible. The shell version printed
		 * nothing here, which is how a bootstrap loop hides.
		 */
		say("bootstrap: SKIPPED: %s: %s: %s\n", what, path,
		    strerror(errno));
		return (-1);
	}

	if ((pid = fork()) < 0) {
		step_failed(what, errno);
		return (-1);
	}

	if (pid == 0) {
		(void) execve(path, argv, envp);
		/*
		 * In the child, and stdio may not be in a state worth trusting
		 * after fork(), but this is the last thing this process will
		 * ever do, so say it anyway and get out with a status the
		 * parent can tell apart from the program's own exit codes.
		 */
		(void) fprintf(stderr, "bootstrap: exec %s failed: %s\n",
		    path, strerror(errno));
		_exit(127);
	}

	while ((got = waitpid(pid, &status, 0)) < 0 && errno == EINTR)
		continue;

	if (got < 0) {
		step_failed(what, errno);
		return (-1);
	}

	if (WIFSIGNALED(status)) {
		failures++;
		say("bootstrap: FAILED: %s: killed by signal %d\n", what,
		    WTERMSIG(status));
		return (-1);
	}

	if (WEXITSTATUS(status) != 0) {
		failures++;
		say("bootstrap: FAILED: %s: exit status %d\n", what,
		    WEXITSTATUS(status));
		return (-1);
	}

	say("bootstrap: %s ok\n", what);
	return (0);
}

/*
 * Mount the host's store over virtio-fs.
 *
 * Absorbed from mountvfs(1) rather than exec'd: it is one mount(2), and this
 * is the step whose failure matters most, so it should not be able to fail as
 * "could not run the helper".
 *
 * illumos' mount(8) is a dispatcher that execs /usr/lib/fs/<fstype>/mount, and
 * virtio-fs has no helper at all -- upstream illumos has never had this
 * filesystem -- so there is nothing to dispatch to and mount(2) is the only
 * way to issue it. virtiofs takes its tag as the *special* argument rather
 * than through fs-specific data, which is what makes a generic call like this
 * sufficient.
 *
 * MS_RDONLY because the host exports it read-only, and MS_OPTIONSTR for the
 * same in/out-buffer reason as the remount above. No MS_DATA: unlike ufs there
 * is no args struct, and the type name is resolved from the option-string path
 * -- see mountvfs.c, which has done exactly this successfully.
 *
 * Errors are NOT swallowed, and that is a deliberate reversal of the shell
 * version's `2>/dev/null` habit: both the vtfs transport driver and the
 * virtiofs filesystem were written here without ever being run, so the failure
 * IS the interesting output.
 */
static void
mount_store(void)
{
	char optbuf[MAX_MNTOPT_STR];

	optbuf[0] = '\0';

	if (mount(STORE_TAG, STORE_DIR, MS_OPTIONSTR | MS_RDONLY, "virtiofs",
	    NULL, 0, optbuf, sizeof (optbuf)) != 0) {
		step_failed("mount virtiofs " STORE_TAG " on " STORE_DIR,
		    errno);
		return;
	}

	/*
	 * Print what the kernel handed back, not what we asked for: it is the
	 * filesystem's own view of the mount, and the quickest way to see
	 * whether an option was accepted, ignored or rewritten.
	 */
	say("bootstrap: mounted %s (virtiofs) on %s [%s]\n", STORE_TAG,
	    STORE_DIR, optbuf);
}

#ifdef	DLMGMTD
/*
 * dlmgmtd needs a WRITABLE copy of its datalink database; the package ships
 * the seed under share/ and the store is read-only, so it has to be copied
 * rather than linked. The shell version used cp(1) -- one of the six commands
 * that cost 39MB of coreutils closure.
 */
static int
copy_file(const char *from, const char *to, mode_t mode)
{
	char buf[8192];
	int in, out;
	ssize_t n;

	if ((in = open(from, O_RDONLY)) < 0) {
		step_failed(from, errno);
		return (-1);
	}

	if ((out = open(to, O_WRONLY | O_CREAT | O_TRUNC, mode)) < 0) {
		step_failed(to, errno);
		(void) close(in);
		return (-1);
	}

	while ((n = read(in, buf, sizeof (buf))) > 0) {
		if (write(out, buf, (size_t)n) != n) {
			step_failed(to, errno);
			(void) close(in);
			(void) close(out);
			return (-1);
		}
	}

	if (n < 0)
		step_failed(from, errno);

	(void) close(in);

	/*
	 * The seed comes out of the store mode 444. dlmgmtd rewrites this file,
	 * so fix the mode explicitly -- open()'s mode argument only applies to
	 * a file that did not already exist.
	 */
	if (fchmod(out, mode) != 0)
		step_failed(to, errno);

	if (close(out) != 0) {
		step_failed(to, errno);
		return (-1);
	}

	return (n < 0 ? -1 : 0);
}
#endif	/* DLMGMTD */

int
main(int argc, char **argv)
{
	extern char **environ;

	ensure_console();

	say("bootstrap: starting\n");

	/*
	 * 1. Somewhere to write.
	 *
	 * With a ramdisk root that is the root itself, which the kernel
	 * mounted read-only for ROOT_INIT; with a virtio-fs root there is no
	 * making it writable at all, so /var and /tmp become tmpfs instead.
	 * Either way nothing below this line can write until it has run.
	 */
#ifdef	ROOT_VIRTIOFS
	mount_tmpfs("/var");
	mount_tmpfs("/tmp");
	mount_run();
	dev_attrdir();
#else
	remount_root_rw();
#endif

	/* 2. The directories the steps below write into. */
	make_dirs();

	/*
	 * 3. Populate /dev.
	 *
	 * Without this there is no /dev/dsk, no /dev/rdsk, no /dev/net/vioif0
	 * and no /dev/log -- so no device node for anything to open, which is
	 * why it has to precede everything that names one.
	 *
	 * devfsadm also reads /etc/devlink.tab by absolute path, and without it
	 * creates NOTHING while still exiting 0:
	 *
	 *     devfsadm: fopen failed for /etc/devlink.tab: No such file...
	 *
	 * so a zero exit status here is necessary and not sufficient. The file
	 * is staged as a symlink by the boot archive builder.
	 */
	{
		/*
		 * The `-P` pass first, and it is not optional.
		 *
		 * `-P` means "load minor_perm and device_policy" -- devfsadm's
		 * own comment on the flag -- and it is the ONLY thing that
		 * calls load_dev_acl(). A bare `devfsadm` does neither, so
		 * running it by hand to debug a permissions problem changes
		 * nothing and makes the data files look innocent.
		 *
		 * Both halves matter, and the policy half is the surprising
		 * one, because it is a privilege check entirely separate from
		 * the mode bits. Until /etc/security/device_policy is loaded
		 * the kernel's compiled-in default stands, and that default is
		 *
		 *	priv_fillset(&dfltpolicy->dp_rdp);
		 *	priv_fillset(&dfltpolicy->dp_wrp);
		 *
		 * (uts/common/os/devpolicy.c:148) -- *all* privileges required
		 * to open *any* device. Only a full-privilege process passes,
		 * so everything works when tested as root while every daemon
		 * that drops to its own user gets EACCES on a node whose
		 * `ls -l` shows `crw-rw-rw-`. That combination sends you
		 * looking for a permissions bug that was never one.
		 *
		 * nginx is how this was found: its worker setuids to `nginx`,
		 * cannot open /dev/poll -- the only event method it is built
		 * with on this platform -- and exits, while the master survives
		 * holding the listen socket. SMF reports the service `online`,
		 * port 80 accepts connections, and every one returns nothing.
		 *
		 * Before the populating run, necessarily: minor_perm is
		 * consulted as nodes are created, so loading it afterwards
		 * leaves everything already made at its default mode.
		 */
		char *const pav[] = { (char *)DEVFSADM, "-P", NULL };
		char *const av[] = { (char *)DEVFSADM, NULL };

		(void) run("devfsadm -P", DEVFSADM, pav, environ);
		(void) run("devfsadm", DEVFSADM, av, environ);
#ifdef	ROOT_VIRTIOFS
		settle_dev();
#endif
	}

	/*
	 * 4. Load the socket-to-transport mappings into sockfs.
	 *
	 * Without them socket(AF_INET, ...) fails at CREATION with
	 * EAFNOSUPPORT -- `ifconfig -a` cannot open one before naming any
	 * interface -- so every networking symptom downstream points at the
	 * driver and none of them are about the driver.
	 *
	 * After devfsadm, necessarily: some mappings name /dev entries that
	 * devfsadm creates.
	 *
	 * A failure here must not stop the mount below. virtio-fs is a PCI
	 * device and a virtqueue; it wants no sockets at all.
	 */
	{
		char *const av[] = {
			(char *)SOCONFIG, "-d", (char *)SOCONFIG_DIR, NULL
		};
		(void) run("soconfig", SOCONFIG, av, environ);
	}

	/*
	 * 5. The store.
	 *
	 * BEFORE the network, and the ordering is load-bearing rather than
	 * tidiness: under `bootArchive.minimal` everything the network steps
	 * need is deliberately absent from the archive on the grounds that it
	 * can be reached over this mount. With the mount last, a minimal boot
	 * died partway down the network bring-up and never reached it -- a
	 * bootstrap loop that looks from outside like a virtio-fs failure.
	 */
	mount_store();

#ifdef	DLMGMTD
	/*
	 * 6. The network, best effort.
	 *
	 * Compiled in only when the nix expression was given these packages;
	 * `bootArchive.minimal` does not stage them, and baking their store
	 * paths into this binary would drag their whole closures into the
	 * archive to do nothing. See bootstrap.nix.
	 *
	 * dlmgmtd will not start from a command line without help. dlmgmt_init()
	 * (cmd/dlmgmtd/dlmgmt_main.c) does:
	 *
	 *     if ((fmri = getenv("SMF_FMRI")) == NULL) {
	 *             dlmgmt_log(LOG_ERR, "dlmgmtd is an smf(7) managed
	 *                 service and should not be run from the command
	 *                 line.");
	 *             return (EINVAL);
	 *     }
	 *
	 * -- it derives its cache file name from the FMRI. Getting this wrong
	 * is expensive to notice: dlmgmt_log goes to syslog unless -d is given,
	 * nothing here reads syslog, and the daemon exits 1 with no output. It
	 * looks exactly like a daemon that started fine, and every downstream
	 * symptom ("Datalink does not exist", "Could not open DLPI link") is
	 * consistent with a running dlmgmtd that simply has no links.
	 */
	(void) copy_file(DLMGMTD_SEED, "/etc/dladm/datalink.conf", 0644);

	if (setenv("SMF_FMRI", "svc:/network/datalink-management:default", 1)
	    != 0)
		step_failed("setenv SMF_FMRI", errno);

	{
		char *const av[] = { (char *)DLMGMTD, NULL };
		(void) run("dlmgmtd", DLMGMTD, av, environ);
	}

	/*
	 * The NIC is already attached and held by net_dacf (see the
	 * ddi-forceattach in vioif.conf), so this only has to plumb it.
	 *
	 * `setaddr` rather than ifconfig for the address: ifconfig resolves
	 * even a literal dotted quad through the name service switch, and the
	 * hosts backend does not work here.
	 */
	{
		char *const av[] = {
			(char *)IFCONFIG, (char *)IFNAME, "plumb", NULL
		};
		(void) run("ifconfig plumb", IFCONFIG, av, environ);
	}
	{
		char *const av[] = {
			(char *)SETADDR, (char *)IFNAME, (char *)IFADDR,
			(char *)IFMASK, NULL
		};
		(void) run("setaddr", SETADDR, av, environ);
	}
#endif	/* DLMGMTD */

	if (failures == 0)
		say("bootstrap: all steps ok\n");
	else
		say("bootstrap: %d step(s) failed -- see above\n", failures);

#ifdef	NEXT_PROG
	/*
	 * Hand over. This process is what init exec'd, so exec'ing rather than
	 * forking keeps init's child count at one and keeps its respawn logic
	 * (init-shell.c) meaningful: when the shell exits, init sees it.
	 *
	 * WHAT we hand over to is not this program's business, and neither is
	 * how to call it. Both come from -D defines, because the two cases want
	 * opposite things and neither can be inferred here:
	 *
	 *   * bash, on a configuration that wants a shell as pid 1. argv[0] is
	 *     "-bash" -- the leading '-' is what makes it a LOGIN shell, the
	 *     convention a console shell is expected to follow -- and it gets
	 *     `-i`. NEXT_LOGIN is defined.
	 *
	 *   * the system's REAL /sbin/init, on a configuration where this
	 *     program is a pre-init shim that mounts the store and gets out of
	 *     the way. argv[0] is "init", with no dash and no `-i`: to init(8)
	 *     `-i` is not "interactive", it is a RUN LEVEL. NEXT_LOGIN is not
	 *     defined.
	 *
	 * Either way this exec keeps the process: whatever pid this program was
	 * given, its successor inherits. That is what lets a real init stay pid
	 * 1, and what keeps init-shell.c's respawn logic meaningful in the shell
	 * case -- when the shell exits, its init sees it.
	 *
	 * Any arguments given to bootstrap are passed through, so a
	 * configuration can say `bootstrap -c 'something'` without a rebuild,
	 * and so the boot arguments the kernel passes /sbin/init reach init.
	 */
	{
		char **av;
		int i, n = 0;

		if ((av = calloc((size_t)argc + 3, sizeof (char *))) == NULL) {
			say("bootstrap: out of memory handing over to %s\n",
			    NEXT_PROG);
			return (1);
		}

		av[n++] = NEXT_ARGV0;
#ifdef	NEXT_LOGIN
		av[n++] = "-i";
#endif
		for (i = 1; i < argc; i++)
			av[n++] = argv[i];
		av[n] = NULL;

		say("bootstrap: exec %s\n", NEXT_PROG);
		(void) execve(NEXT_PROG, av, environ);
		say("bootstrap: exec %s failed: %s\n", NEXT_PROG,
		    strerror(errno));
		return (1);
	}
#else
	/*
	 * Nothing to hand over to.
	 *
	 * Do NOT return: this program is exec'd by pid 1, and a pid 1 whose
	 * child exits restarts it -- forever, with a respawn cap that scrolls
	 * the console (init-shell.c, MAX_RESPAWNS). Parking here leaves the
	 * console showing what happened, which is the entire point.
	 */
	say("bootstrap: no shell configured; parking\n");
	for (;;)
		(void) pause();
	/* NOTREACHED */
#endif
}
