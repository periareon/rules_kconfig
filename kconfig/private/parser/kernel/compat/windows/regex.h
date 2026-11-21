/* regex.h for the Windows CRT: the POSIX interface `sym_re_search` is
 * compiled against. The module never searches, so regex.c answers that no
 * pattern compiles. */
#ifndef RULES_KCONFIG_COMPAT_REGEX_H
#define RULES_KCONFIG_COMPAT_REGEX_H

#include <stddef.h>

typedef struct {
    int unused;
} regex_t;

typedef struct {
    ptrdiff_t rm_so;
    ptrdiff_t rm_eo;
} regmatch_t;

#define REG_EXTENDED 1
#define REG_ICASE 2
#define REG_NOMATCH 1

int regcomp(regex_t* preg, const char* pattern, int cflags);
int regexec(const regex_t* preg, const char* string, size_t nmatch,
            regmatch_t pmatch[], int eflags);
void regfree(regex_t* preg);

#endif
