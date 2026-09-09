/*
 * Bionic-compat shim for OLD Android firmwares (kernel 3.10.x / Android < 5.0 /
 * API < 21). NDK r27's prebuilt Rust std references symbols that such old bionic
 * hides (doesn't export), so the dynamic linker fails at LOAD time with
 * "CANNOT LINK EXECUTABLE: cannot locate symbol \"XXX\"". We provide no-op or
 * delegating implementations and link this object into EVERY Android target.
 *
 * Symbols covered (observed on real devices):
 *   - getifaddrs / freeifaddrs  : "mangosteen" aarch64 (kernel 3.10.x),
 *                                 AOW-PC x86 ROM, any Android < API 24 where
 *                                 bionic doesn't export getifaddrs. Rust's
 *                                 prebuilt std::net references it as a hard
 *                                 symbol for multicast/interface enumeration.
 *   - __register_atfork         : Hi3798MV310 (32-bit ARM, armeabi-v7a). Old
 *                                 bionic only exports pthread_atfork (public),
 *                                 keeping __register_atfork hidden; NDK r27 std
 *                                 references the hidden one directly.
 *   - epoll_create1             : same old bionic (Android < 5.0 / API < 21)
 *                                 only exports epoll_create(int); NDK r27 std
 *                                 references epoll_create1.
 *   - signal                    : old bionic defines signal as a macro
 *                                 (bsd_signal/sigset); NDK crt / std reference
 *                                 a real `signal` function symbol that's hidden.
 *   - dl_iterate_phdr           : Hi3798MV310 again. Added in bionic at API 21;
 *                                 referenced by Rust's unwinder / backtrace
 *                                 capture (std::backtrace, anyhow Backtrace).
 *                                 Old bionic doesn't export it.
 *   - sigemptyset / sigfillset  : Hi3798MV310 (armv7a, kernel 3.10) — the
 *                                 device's bionic doesn't export these sigset
 *                                 ops as real function symbols (they're inline/
 *                                 macro in newer NDK headers, but std / crt emit
 *                                 a call), so load fails with "cannot locate
 *                                 symbol sigemptyset". Implemented via memset
 *                                 (layout-independent, correct empty/full sets).
 *   - getrandom                : Hi3798MV310 (armv7a, kernel 3.10). Old bionic
 *                                 doesn't export getrandom, and the getrandom()
 *                                 syscall only exists on kernel >= 3.17 — this
 *                                 box runs 3.10, so a raw syscall would fail
 *                                 ENOSYS. Implemented by reading /dev/urandom,
 *                                 which is always available and never blocks.
 *   - dl_unwind_find_exidx     : 32-bit ARM unwinder symbol referenced by
 *                                 libgcc's unwind-dw2; old bionic doesn't export
 *                                 it. Provided as a best-effort stub returning
 *                                 no unwind table (panics abort instead of
 *                                 unwinding — acceptable for a daemon).
 *
 * Notes:
 *   - cloudflare-ddns resolves its public IP via external providers, so a no-op
 *     getifaddrs (empty list) is harmless.
 *   - __register_atfork delegates to pthread_atfork, which exists on all
 *     Android versions (no recursion; we call the public wrapper, not the
 *     hidden symbol). For devices that DO export the real __register_atfork,
 *     our definition shadows it but is behaviorally equivalent.
 *
 * Compile (NDK clang per target, API 24+ so <ifaddrs.h> / <pthread.h> present):
 *   aarch64-linux-android24-clang  getifaddrs_shim.c -c -o getifaddrs_shim_aarch64.o
 *   armv7a-linux-androideabi24-clang getifaddrs_shim.c -c -o getifaddrs_shim_armv7.o
 *   i686-linux-android24-clang      getifaddrs_shim.c -c -o getifaddrs_shim_i686.o
 */
#include <ifaddrs.h>
#include <stdlib.h>
#include <pthread.h>
#include <sys/epoll.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

/* Keep the symbols even if the linker's --gc-sections thinks they're unused. */
#define USED __attribute__((used, visibility("default")))

int USED getifaddrs(struct ifaddrs **ifap) {
    if (ifap) {
        *ifap = NULL;
    }
    return 0; /* success, no addresses */
}

void USED freeifaddrs(struct ifaddrs *ifa) {
    (void)ifa; /* nothing allocated */
}

/* __register_atfork shim for old bionic (Android < ~5.0 / API < 21).
 *
 * Why: NDK r27's prebuilt Rust std references __register_atfork directly, but
 * old bionic only exports the public pthread_atfork and keeps __register_atfork
 * hidden, so load fails with:
 *   CANNOT LINK EXECUTABLE: cannot locate symbol "__register_atfork"
 *
 * Fix: delegate to pthread_atfork, which is present on every Android version.
 * The extra dso_handle argument (glibc-style) is unused by our callers. Return
 * value normalized to 0/-1 to match __register_atfork's convention. */
int USED __register_atfork(void (*prepare)(void),
                           void (*parent)(void),
                           void (*child)(void),
                           void *dso_handle) {
    (void)dso_handle;
    int r = pthread_atfork(prepare, parent, child);
    return r == 0 ? 0 : -1;
}

/* epoll_create1 shim for old bionic (Android < 5.0 / API < 21).
 *
 * Why: NDK r27's prebuilt Rust std references epoll_create1 directly, but old
 * bionic only exports the older epoll_create(int size) and doesn't export
 * epoll_create1, so load fails with:
 *   CANNOT LINK EXECUTABLE: cannot locate symbol "epoll_create1"
 *
 * Fix: delegate to epoll_create (size argument is ignored by the kernel since
 * 2.6.x). If EPOLL_CLOEXEC is requested, set FD_CLOEXEC via fcntl so behavior
 * matches the real epoll_create1. For devices that DO export the real
 * epoll_create1, our definition shadows it but is behaviorally equivalent. */
int USED epoll_create1(int flags) {
    int fd = epoll_create(1);
    if (fd >= 0 && (flags & EPOLL_CLOEXEC)) {
        int fl = fcntl(fd, F_GETFD, 0);
        if (fl >= 0) {
            fcntl(fd, F_SETFD, fl | FD_CLOEXEC);
        }
    }
    return fd;
}

/* signal shim for old bionic.
 *
 * Why: on some old firmwares bionic either lacks a real `signal` function symbol
 * (historically it was a macro expanding to bsd_signal / sigset) or NDK crt / std
 * references `signal` directly, so load fails with:
 *   CANNOT LINK EXECUTABLE: cannot locate symbol "signal"
 *
 * Fix: provide a genuine `signal` implemented on top of sigaction, which exists
 * on every Android version. We #undef signal first because <signal.h> on old
 * bionic may define it as a macro; our definition must be a true function
 * symbol that the dynamic linker can resolve. */
#undef signal
typedef void (*shim_sighandler_t)(int);
shim_sighandler_t USED signal(int signum, shim_sighandler_t handler) {
    struct sigaction act, old;
    act.sa_handler = handler;
    sigemptyset(&act.sa_mask);
    act.sa_flags = 0;
    if (sigaction(signum, &act, &old) != 0) {
        return (shim_sighandler_t)SIG_ERR;
    }
    return old.sa_handler;
}

/* dl_iterate_phdr shim for old bionic (Android < 5.0 / API < 21).
 *
 * Why: dl_iterate_phdr was added to bionic at API 21. Rust's unwinder and
 * backtrace capture (std::backtrace / anyhow's Backtrace) reference it as a hard
 * symbol, so on older firmwares load fails with:
 *   CANNOT LINK EXECUTABLE: cannot locate symbol "dl_iterate_phdr"
 *
 * Fix: provide a no-op that reports ZERO modules (calls the callback zero times
 * and returns 0, the count of modules visited). cloudflare-ddns's actual
 * functionality (resolving public IP, updating DNS records) never depends on
 * dl_iterate_phdr; it's only used to build panic/error backtraces, which are
 * purely diagnostic. Returning an empty module list just yields empty
 * backtraces on these old devices — harmless for a production daemon. On devices
 * that DO export the real dl_iterate_phdr, our definition shadows it but is
 * behaviorally a strict subset (no backtrace info), which does not affect
 * runtime behavior. */
int USED dl_iterate_phdr(int (*callback)(struct dl_phdr_info *, size_t, void *),
                         void *data) {
    (void)callback;
    (void)data;
    return 0; /* visited 0 modules */
}

/* sigemptyset / sigfillset shim for old bionic.
 *
 * Why: reported on Hi3798MV310 (armv7a, kernel 3.10). The device's bionic
 * doesn't export these as real `sigemptyset` / `sigfillset` function symbols —
 * in newer NDK headers they're inline/macro, yet std and the crt still emit a
 * call, so load fails with:
 *   CANNOT LINK EXECUTABLE: cannot locate symbol "sigemptyset"
 * (and typically "sigfillset" too, same family).
 *
 * Fix: provide genuine functions implemented with memset. Semantics are simple
 * and layout-independent:
 *   - empty set  = all-zero bits  (no signal blocked)
 *   - full set   = all-ones bits  (every signal blocked)
 * which is correct for every bionic sigset_t layout. On devices whose bionic
 * DOES export the real sigemptyset/sigfillset, our definition is behaviorally
 * equivalent (and shadows it, as with the other shims in this file). */
int USED sigemptyset(sigset_t *set) {
    if (set) {
        memset(set, 0, sizeof(*set));
    }
    return 0;
}

int USED sigfillset(sigset_t *set) {
    if (set) {
        memset(set, 0xff, sizeof(*set));
    }
    return 0;
}

/* getrandom shim for old bionic (kernel < 3.17 / API < 26).
 *
 * Why: Rust's getrandom crate (and libc::getrandom) bind to the libc function,
 * which old bionic doesn't export. The getrandom() syscall itself only exists
 * on kernel >= 3.17, but this device runs kernel 3.10, so even a raw syscall
 * would return ENOSYS. We fall back to reading /dev/urandom, which is always
 * present and never blocks — exactly what callers want (e.g. TLS / DoH
 * randomness). flags (GRND_NONBLOCK / GRND_RANDOM) are ignored because
 * /dev/urandom semantics match our needs regardless. */
ssize_t USED getrandom(void *buf, size_t buflen, unsigned int flags) {
    (void)flags;
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) {
        return -1;
    }
    char *p = (char *)buf;
    size_t remaining = buflen;
    while (remaining > 0) {
        ssize_t n = read(fd, p, remaining);
        if (n > 0) {
            p += n;
            remaining -= (size_t)n;
        } else if (n == 0) {
            break; /* shouldn't happen on /dev/urandom */
        } else {
            if (errno == EINTR) {
                continue;
            }
            close(fd);
            return -1;
        }
    }
    close(fd);
    return (ssize_t)(buflen - remaining);
}

/* dl_unwind_find_exidx shim for old bionic (32-bit ARM, kernel 3.10).
 *
 * Why: the ARM C++/Rust unwinder (libgcc unwind-dw2) references
 * dl_unwind_find_exidx to locate a module's EXIDX unwind table. This old
 * bionic doesn't export it, so load fails with:
 *   CANNOT LINK EXECUTABLE: cannot locate symbol "dl_unwind_find_exidx"
 *
 * Fix: provide a best-effort stub that reports no unwind table for any PC.
 * Consequence: C++ exceptions / Rust panics on ARM won't unwind through the
 * main executable (they abort), which is acceptable for a production daemon
 * whose normal code path never throws. On devices whose bionic DOES export the
 * real symbol, our definition shadows it but only degrades backtraces. */
void *USED dl_unwind_find_exidx(void *pc, int *pcount) {
    (void)pc;
    if (pcount) {
        *pcount = 0;
    }
    return 0;
}

