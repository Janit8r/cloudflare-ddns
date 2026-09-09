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

