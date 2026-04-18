#include <stdio.h>

int main(void) {
    int failed = 0;

#ifndef FOO_MATCHED
    fprintf(stderr,
            "FAIL: config_setting CONFIG_FOO did not match; "
            "expected .bazelrc to set --@simple_kconfig//:CONFIG_FOO=true\n");
    failed = 1;
#endif

#ifndef COUNT_MATCHED
    fprintf(stderr,
            "FAIL: config_setting CONFIG_COUNT_3 did not match; "
            "expected CONFIG_COUNT to default to 3 (Kconfig default)\n");
    failed = 1;
#endif

#ifndef LABEL_MATCHED
    fprintf(
        stderr,
        "FAIL: config_setting CONFIG_LABEL_hello did not match; "
        "expected CONFIG_LABEL to default to \"hello\" (Kconfig default)\n");
    failed = 1;
#endif

    return failed;
}
