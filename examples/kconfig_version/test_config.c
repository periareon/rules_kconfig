#include "config.h"

#if !defined(CONFIG_MODULES) || CONFIG_MODULES != 1
#error "CONFIG_MODULES should be 1: `option modules` is accepted"
#endif

#if !defined(CONFIG_FEATURE) || CONFIG_FEATURE != 1
#error "CONFIG_FEATURE should be 1: a symbol with ---help--- is parsed"
#endif

#ifdef CONFIG_BACKEND_A
#error \
    "CONFIG_BACKEND_A should be undefined: the choice is optional and nothing chose"
#endif

#ifdef CONFIG_BACKEND_B
#error \
    "CONFIG_BACKEND_B should be undefined: the choice is optional and nothing chose"
#endif

#ifndef CONFIG_NAME
#error "CONFIG_NAME should be defined"
#endif

int main(void) { return 0; }
