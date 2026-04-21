#include <stdio.h>

#include "config.h"

int main(void) {
    int failed = 0;

#if CONFIG_VERSION != 42
    fprintf(stderr, "FAIL: CONFIG_VERSION should be 42, got %d\n",
            CONFIG_VERSION);
    failed = 1;
#endif

#if CONFIG_ENABLED
    fprintf(stderr, "FAIL: CONFIG_ENABLED should be undefined (default n)\n");
    failed = 1;
#endif

    return failed;
}
