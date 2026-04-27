#include "config.h"

#if CONFIG_BASE_ADDR != 0x1000
#error "CONFIG_BASE_ADDR should be 0x1000"
#endif

#if CONFIG_COUNT != 3
#error "CONFIG_COUNT should be 3"
#endif

int main(void) { return 0; }
