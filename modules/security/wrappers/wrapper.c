#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdnoreturn.h>
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>
#include <stdint.h>

#ifndef SOURCE_PROG
#error SOURCE_PROG should be defined via preprocessor commandline
#endif

// aborts when false, printing the failed expression
#define ASSERT(expr) ((expr) ? (void) 0 : assert_failure(#expr))

extern char **environ;

// Wrapper debug variable name
static char *wrapper_debug = "WRAPPER_DEBUG";

static noreturn void assert_failure(const char *assertion) {
    fprintf(stderr, "Assertion `%s` in NixBSD's wrapper.c failed.\n", assertion);
    fflush(stderr);
    abort();
}

// this list generated by grep secure_getenv in libc
#define UNSECURE_ENVVARS \
    "HES_DOMAIN\0" \
    "HESIOD_CONFIG\0" \
    "HOME\0" \
    "HOSTALIASES\0" \
    "ICONV_MAX_REUSE\0" \
    "LOCALDOMAIN\0" \
    "MAC_CONFFILE\0" \
    "NLSPATH\0" \
    "PATH_FSTAB\0" \
    "PATH_I18NMODULE\0" \
    "PATH_LOCALE\0" \
    "RSH\0" \
    "TMPDIR\0"


int main(int argc, char **argv) {
    ASSERT(argc >= 1);

    int debug = getenv(wrapper_debug) != NULL;

    // Drop insecure environment variables explicitly
    // If we don't explicitly unset them, it's quite easy to just set LD_PRELOAD,
    // have it passed through to the wrapped program, and gain privileges.
    for (char *unsec = UNSECURE_ENVVARS; *unsec; unsec = strchr(unsec, 0) + 1) {
        if (debug) {
            fprintf(stderr, "unsetting %s\n", unsec);
        }
        unsetenv(unsec);
    }

    // TODO: some freebsd equivialent to capabilities that need to be messed with

    execve(SOURCE_PROG, argv, environ);
    
    fprintf(stderr, "%s: cannot run `%s': %s\n",
        argv[0], SOURCE_PROG, strerror(errno));

    return 1;
}