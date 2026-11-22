/* sys/mman.h for the Windows CRT: the names the kernel's sources use. `mmap`
 * and `munmap` are renamed to the shim's stubs (host.h), which fail. */
#ifndef RULES_KCONFIG_COMPAT_SYS_MMAN_H
#define RULES_KCONFIG_COMPAT_SYS_MMAN_H

#include <stddef.h>
#include <sys/types.h>

#define PROT_READ 0x1
#define PROT_WRITE 0x2
#define MAP_PRIVATE 0x02
#define MAP_FAILED ((void*)-1)

void* mmap(void* addr, size_t length, int prot, int flags, int fd,
           off_t offset);
int munmap(void* addr, size_t length);

#endif
