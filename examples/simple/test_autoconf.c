#include "config.h"

#if CONFIG_BASE_ADDR != 0x1000
#error "CONFIG_BASE_ADDR should be 0x1000"
#endif

#if CONFIG_COUNT != 3
#error "CONFIG_COUNT should be 3"
#endif

#ifdef CONFIG_TRISTATE
#error "CONFIG_TRISTATE should not be defined when defaulting to n"
#endif

int main(void) { return 0; }
