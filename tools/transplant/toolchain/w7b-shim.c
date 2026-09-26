/*
 * w7b-shim.c — LD_PRELOAD shim for the termux-native / w7b libopentui build.
 *
 * Android SELinux denies hardlink()/linkat() between files under /data, which
 * breaks Zig 0.16's cache materialization ("failed to link temporary file into
 * <cache>/...: AccessDenied"). This shim intercepts link()/linkat() and, when
 * the real call fails with EPERM/EXDEV/EACCES, falls back to a byte copy
 * (preserving mode) — semantically equivalent for Zig's content-addressed
 * cache files, which are write-once.
 *
 * Also provides pthread_tryjoin_np (glibc-only) for the bionic compat path,
 * since some host-side tooling expects it.
 *
 * Build: clang -shared -fPIC -O2 -o w7b-shim.so w7b-shim.c
 * Use:   LD_PRELOAD=/path/w7b-shim.so <zig> build ...
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* ---- link/linkat -> copy fallback -------------------------------------- */

static int copy_fallback_at(int olddirfd, const char *oldpath, int newdirfd, const char *newpath) {
    int in = openat(olddirfd, oldpath, O_RDONLY | O_CLOEXEC);
    if (in < 0) return -1;

    struct stat st;
    if (fstat(in, &st) != 0) {
        int e = errno;
        close(in);
        errno = e;
        return -1;
    }

    int out = openat(newdirfd, newpath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, st.st_mode);
    if (out < 0) {
        /* Destination may already exist (idempotent cache write): treat as ok. */
        if (errno == EEXIST) {
            close(in);
            return 0;
        }
        int e = errno;
        close(in);
        errno = e;
        return -1;
    }

    char buf[65536];
    for (;;) {
        ssize_t r = read(in, buf, sizeof buf);
        if (r < 0) {
            if (errno == EINTR) continue;
            int e = errno;
            close(in);
            close(out);
            return -1;
        }
        if (r == 0) break;
        ssize_t off = 0;
        while (off < r) {
            ssize_t w = write(out, buf + off, (size_t)(r - off));
            if (w < 0) {
                if (errno == EINTR) continue;
                int e = errno;
                close(in);
                close(out);
                return -1;
            }
            off += w;
        }
    }

    close(in);
    close(out);
    return 0;
}

typedef int (*linkat_fn)(int, const char *, int, const char *, int);
typedef int (*link_fn)(const char *, const char *);

int linkat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, int flags) {
    static linkat_fn real;
    if (!real) real = (linkat_fn)dlsym(RTLD_NEXT, "linkat");

    int r = real ? real(olddirfd, oldpath, newdirfd, newpath, flags) : -1;
    if (r == 0) return 0;
    if (errno != EPERM && errno != EACCES && errno != EXDEV && errno != EMLINK) return r;
    if (flags & AT_SYMLINK_FOLLOW) { /* best effort: copy the target */ }
    return copy_fallback_at(olddirfd, oldpath, newdirfd, newpath);
}

int link(const char *oldpath, const char *newpath) {
    static link_fn real;
    if (!real) real = (link_fn)dlsym(RTLD_NEXT, "link");

    int r = real ? real(oldpath, newpath) : -1;
    if (r == 0) return 0;
    if (errno != EPERM && errno != EACCES && errno != EXDEV && errno != EMLINK) return r;
    return copy_fallback_at(AT_FDCWD, oldpath, AT_FDCWD, newpath);
}

/* ---- bionic compat: glibc-only pthread_tryjoin_np ----------------------- */
int pthread_tryjoin_np(pthread_t t, void **retval) {
    int st = pthread_kill(t, 0);
    if (st == 0) return EBUSY;
    if (st == ESRCH) return pthread_join(t, retval);
    return st;
}
