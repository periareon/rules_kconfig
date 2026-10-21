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

#ifdef CONFIG_TRISTATE_MODULE
#error "CONFIG_TRISTATE_MODULE should not be defined when defaulting to n"
#endif

/* A compile-time check for any C compiler: _Static_assert where the language
 * is C11 or newer (MSVC only with /std:c11, so its default mode takes the other
 * branch), else a typedef whose array size is negative when the condition
 * fails. The message is kept only where the compiler can show it. */
#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define KCONFIG_STATIC_ASSERT(cond, msg) _Static_assert(cond, msg)
#else
#define KCONFIG_STATIC_ASSERT_PASTE(a, b) a##b
#define KCONFIG_STATIC_ASSERT_NAME(line) \
    KCONFIG_STATIC_ASSERT_PASTE(kconfig_static_assertion_, line)
#define KCONFIG_STATIC_ASSERT(cond, msg) \
    typedef char KCONFIG_STATIC_ASSERT_NAME(__LINE__)[(cond) ? 1 : -1]
#endif

/* A string symbol is quoted even when it looks like a number: the literal
 * "42" has sizeof 3, where an unquoted 42 would be sizeof(int). */
KCONFIG_STATIC_ASSERT(sizeof(CONFIG_NUMERIC_STRING) == 3,
                      "CONFIG_NUMERIC_STRING should be the string \"42\"");

int main(void) { return 0; }
