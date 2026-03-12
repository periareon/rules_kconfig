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

    return failed;
}
