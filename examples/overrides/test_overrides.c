#include <stdio.h>

#include "config.h"

int main(void) {
    int failed = 0;

#if !CONFIG_FOO
    fprintf(stderr, "FAIL: CONFIG_FOO should be 1 (overridden to y)\n");
    failed = 1;
#endif

#if CONFIG_COUNT != 42
    fprintf(stderr, "FAIL: CONFIG_COUNT should be 42, got %d\n", CONFIG_COUNT);
    failed = 1;
#endif

    /* A tristate overridden to m defines CONFIG_X_MODULE, not CONFIG_X. */
#ifndef CONFIG_TRISTATE_MODULE
    fprintf(
        stderr,
        "FAIL: CONFIG_TRISTATE_MODULE should be defined (overridden to m)\n");
    failed = 1;
#endif
#ifdef CONFIG_TRISTATE
    fprintf(
        stderr,
        "FAIL: CONFIG_TRISTATE should not be defined when the value is m\n");
    failed = 1;
#endif

    return failed;
}
