#include <stdio.h>

#include "config.h"

int main(void) {
    int failed = 0;

    /* CONFIG_VERSION still comes from the setting_labels rule (42),
       not from the .config override.  The override only affects
       regular flags like CONFIG_ENABLED. */
#if CONFIG_VERSION != 42
    fprintf(stderr, "FAIL: CONFIG_VERSION should be 42, got %d\n",
            CONFIG_VERSION);
    failed = 1;
#endif

#if !CONFIG_ENABLED
    fprintf(stderr, "FAIL: CONFIG_ENABLED should be 1 (overridden to y)\n");
    failed = 1;
#endif

    return failed;
}
