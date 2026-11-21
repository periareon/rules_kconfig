/* The config.h of a U-Boot repository: the board the defconfig selects. */

#include <string.h>

#include "config.h"

#if defined(EXPECT_QEMU_ARM64)
#if !defined(CONFIG_ARM64) || !defined(CONFIG_TARGET_QEMU_ARM_64BIT)
#error "not the qemu_arm64 configuration"
#endif
#define EXPECTED_SYS_ARCH "arm"
#elif defined(EXPECT_QEMU_X86_64)
#if !defined(CONFIG_X86) || !defined(CONFIG_TARGET_QEMU_X86_64)
#error "not the qemu-x86_64 configuration"
#endif
#define EXPECTED_SYS_ARCH "x86"
#else
#error "define EXPECT_QEMU_ARM64 or EXPECT_QEMU_X86_64"
#endif

/* The compiler probes ran: the host's gcc or clang answered, not n. */
#if !defined(CONFIG_CC_IS_GCC) && !defined(CONFIG_CC_IS_CLANG)
#error "the compiler probes did not run"
#endif

int main(void) {
    /* A string symbol is quoted in config.h. */
    return strcmp(CONFIG_SYS_ARCH, EXPECTED_SYS_ARCH) != 0;
}
