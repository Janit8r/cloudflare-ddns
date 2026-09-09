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
