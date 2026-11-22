/* The config.h of a Linux repository: what the defconfig decides, and what
 * the compiler probes decided with the dummy tools. */

#include "config.h"

#if defined(EXPECT_X86_64)
#if !defined(CONFIG_X86_64) || !defined(CONFIG_64BIT) || defined(CONFIG_ARM64)
#error "not the x86_64 configuration"
#endif
#elif defined(EXPECT_ARM64)
#if !defined(CONFIG_ARM64) || !defined(CONFIG_64BIT) || defined(CONFIG_X86)
#error "not the arm64 configuration"
#endif
#else
#error "define EXPECT_X86_64 or EXPECT_ARM64"
#endif

/* Both defconfigs build modules; the tristate of a module comes through as
 * CONFIG_<name>_MODULE. */
#if !defined(CONFIG_MODULES) || !defined(CONFIG_EXT4_FS)
#error "the defconfig's symbols are missing"
#endif

/* scripts/dummy-tools/gcc answers as gcc 20.0.0; the symbols that depend on
 * the compiler are calculated, not left at n. */
#if !defined(CONFIG_CC_IS_GCC) || CONFIG_GCC_VERSION != 200000
#error "the compiler probes did not run with the dummy tools"
#endif
#if defined(CONFIG_CC_IS_CLANG) || CONFIG_CLANG_VERSION != 0
#error "the compiler was taken for clang"
#endif

#include <string.h>

static const char dummy_version[] = "gcc (scripts/dummy-tools/gcc)";

int main(void) {
#if defined(EXPECT_X86_64)
    /* @linux_x86_64 takes CONFIG_CC_VERSION_TEXT from the build's C++
     * toolchain through settings_labels: the compiler's path, not the text
     * the repository rule was given. */
    return CONFIG_CC_VERSION_TEXT[0] == 0 ||
           strcmp(CONFIG_CC_VERSION_TEXT, dummy_version) == 0;
#else
    return strcmp(CONFIG_CC_VERSION_TEXT, dummy_version) != 0;
#endif
}
