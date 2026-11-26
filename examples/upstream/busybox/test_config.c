/* The config.h of a BusyBox repository: the configuration the defaults file
 * selects, and a symbol it leaves invisible, which `write_invisible` defines
 * with the empty value of its type, as BusyBox's autoconf.h does. */

#include <string.h>

#include "config.h"

#if defined(EXPECT_DEFCONFIG)
#if !defined(CONFIG_DESKTOP) || !defined(CONFIG_SH_IS_ASH) || \
    defined(CONFIG_NOMMU)
#error "not the defconfig configuration"
#endif
/* FEATURE_KILL_DELAY has no prompt that applies here: an int, so 0. */
#if CONFIG_FEATURE_KILL_DELAY != 0
#error "an invisible int is not 0"
#endif
#elif defined(EXPECT_NOMMU)
#if !defined(CONFIG_NOMMU) || !defined(CONFIG_SH_IS_HUSH) || \
    defined(CONFIG_SH_IS_ASH)
#error "not the TEST_nommu_defconfig configuration"
#endif
#else
#error "define EXPECT_DEFCONFIG or EXPECT_NOMMU"
#endif

/* FEATURE_CALL_TELINIT is off in both, which hides TELINIT_PATH; BusyBox's
 * init.c reads CONFIG_TELINIT_PATH all the same, so it is defined, empty. */
#if defined(CONFIG_FEATURE_CALL_TELINIT)
#error "FEATURE_CALL_TELINIT is on"
#endif
#if !defined(CONFIG_TELINIT_PATH)
#error "an invisible string is not defined"
#endif

int main(void) {
    /* A string symbol is quoted in config.h; an invisible one is empty. */
    return strcmp(CONFIG_BUSYBOX_EXEC_PATH, "/proc/self/exe") != 0 ||
           strcmp(CONFIG_TELINIT_PATH, "") != 0;
}
