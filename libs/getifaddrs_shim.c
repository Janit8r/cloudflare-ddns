/*
 * getifaddrs / freeifaddrs shim for old Android firmwares whose bionic lacks
 * getifaddrs despite Rust's prebuilt std::net referencing it as a hard symbol.
 * Affected devices observed: "mangosteen" aarch64 box (kernel 3.10.x), AOW-PC
 * x86 ROM, and any Android < API 24 where bionic doesn't export getifaddrs.
 *
 * Why this exists:
 *   Rust's prebuilt std::net references getifaddrs (used for multicast /
 *   interface enumeration) as a hard undefined symbol. The dynamic linker must
 *   resolve it at LOAD time, even if the program never enumerates interfaces.
 *   On devices whose bionic doesn't export getifaddrs the binary fails with:
 *     CANNOT LINK EXECUTABLE: cannot locate symbol "getifaddrs"
 *
 * Fix:
 *   Link this tiny object into EVERY Android target so the symbol resolves. It
 *   returns an empty interface list (success, no addresses). cloudflare-ddns
 *   resolves its public IP via external providers, so it never enumerates
 *   local interfaces — returning empty is safe. (On devices that DO have a real
 *   getifaddrs this no-op overrides it, which is harmless for this app.)
 *
 * Compile (NDK clang per target, API 24+ so <ifaddrs.h> is present):
 *   aarch64-linux-android24-clang  getifaddrs_shim.c -c -o getifaddrs_shim_aarch64.o
 *   armv7a-linux-androideabi24-clang getifaddrs_shim.c -c -o getifaddrs_shim_armv7.o
 *   i686-linux-android24-clang      getifaddrs_shim.c -c -o getifaddrs_shim_i686.o
 */
#include <ifaddrs.h>
#include <stdlib.h>

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
