/* See regex.h: no pattern compiles, so `sym_re_search` finds nothing. */
#include "regex.h"

int regcomp(regex_t* preg, const char* pattern, int cflags) {
    (void)preg;
    (void)pattern;
    (void)cflags;
    return -1;
}

int regexec(const regex_t* preg, const char* string, size_t nmatch,
            regmatch_t pmatch[], int eflags) {
    (void)preg;
    (void)string;
    (void)nmatch;
    (void)pmatch;
    (void)eflags;
    return REG_NOMATCH;
}

void regfree(regex_t* preg) { (void)preg; }
