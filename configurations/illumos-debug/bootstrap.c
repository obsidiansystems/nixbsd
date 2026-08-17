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

#include <errno.h>
#include <fcntl.h>
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

#ifndef	STORE_DIR
#define	STORE_DIR	"/mnt/store"
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
 *   /mnt, /mnt/store       the virtio-fs mountpoint. mount(2) does not create
 *                          its target; without this the mount fails ENOENT and
 *                          looks like a transport problem.
 */
static const char *const dirs[] = {
	"/etc",
	"/etc/svc",
	"/etc/svc/volatile",
	"/etc/svc/volatile/dev",
	"/etc/dladm",
	"/var",
	"/var/run",
	"/var/empty",
	"/mnt",
	STORE_DIR,
	NULL
};

static int failures = 0;

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

/*
 * mkdir -p, minus the -p. The list above is fully expanded -- every parent is
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

	say("bootstrap: starting\n");

	/* 1. The read-write root. Everything below needs it. */
	remount_root_rw();

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
		char *const av[] = { (char *)DEVFSADM, NULL };
		(void) run("devfsadm", DEVFSADM, av, environ);
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
	 * argv[0] gets a leading '-'. That is what makes bash a LOGIN shell,
	 * which is the convention a console shell is expected to follow. It no
	 * longer has any functional weight here -- the point of this program is
	 * that /etc/profile is gone -- but a shell that thinks it is a login
	 * shell is what anyone typing at this console will expect.
	 *
	 * Any arguments given to bootstrap are passed through, so a
	 * configuration can say `bootstrap -c 'something'` without a rebuild.
	 */
	{
		char **av;
		int i;

		if ((av = calloc((size_t)argc + 2, sizeof (char *))) == NULL) {
			say("bootstrap: out of memory handing over to %s\n",
			    NEXT_PROG);
			return (1);
		}

		av[0] = "-" NEXT_ARGV0;
		av[1] = "-i";
		for (i = 1; i < argc; i++)
			av[i + 1] = argv[i];

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
