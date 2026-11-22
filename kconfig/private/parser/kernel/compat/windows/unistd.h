/* unistd.h for the Windows CRT: what the kernel's sources use of it. The
 * calls that reach files or the process are renamed to the shim's (host.h);
 * `open` and `close`, in two functions the module never calls, are the CRT's.
 */
#ifndef RULES_KCONFIG_COMPAT_UNISTD_H
#define RULES_KCONFIG_COMPAT_UNISTD_H

#include <direct.h>
#include <io.h>
#include <process.h>

#endif
