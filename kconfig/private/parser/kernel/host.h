/* What the kernel's parser asks of its host, served by the module's shim
 * (kconfig/private/parser/shim.c). Every kernel source is compiled with this
 * header included first (see the BUILD file of the `kernel_kconfig`
 * repository), and the macros at its end rename the libc calls the parser
 * makes for files, streams, the environment and the shell to the functions
 * declared here, so that all of it comes from the module's host: a stream the
 * parser reads or writes is the shim's own, never the libc's, what it prints
 * to stderr is kept for the error it may end in, and the patched exit sites
 * report through `kconfig_host_fail` instead of ending the process. The
 * renames are macros here rather than `-D` flags so that a libc's own macro
 * for, say, `putc` cannot take them back. */
#ifndef RULES_KCONFIG_HOST_H
#define RULES_KCONFIG_HOST_H

#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

#ifdef _WIN32
/* The POSIX types the declarations below use, which the Windows CRT lacks. */
typedef intptr_t ssize_t;
typedef unsigned short mode_t;
typedef int pid_t;
/* The CRT's declarations of calls renamed at the end of this header, read
 * before the renames; compat/windows/unistd.h includes these again, after
 * them, to no effect. */
#include <direct.h>
#include <io.h>
#include <process.h>
/* What the sources use of <limits.h>, <sys/stat.h> and <strings.h> and the
 * CRT lacks. */
#ifndef PATH_MAX
#define PATH_MAX _MAX_PATH
#endif
#ifndef S_ISDIR
#define S_ISDIR(mode) (((mode)&_S_IFMT) == _S_IFDIR)
#endif
#define bcmp memcmp
#else
#include <unistd.h>
#endif

/* The scanner is built `never-interactive`, for which flex reads its input
 * with `read(fileno(yyin))`; the parser's files are streams with no
 * descriptor behind them, so it reads them as streams instead. The generated
 * scanner takes this definition over its own. */
#define YY_INPUT(buf, result, max_size)                                        \
    do {                                                                       \
        errno = 0;                                                             \
        while ((result = (int)fread(buf, 1, (size_t)(max_size), yyin)) == 0 && \
               ferror(yyin)) {                                                 \
            if (errno != EINTR) {                                              \
                YY_FATAL_ERROR("input in flex scanner failed");                \
                break;                                                         \
            }                                                                  \
            errno = 0;                                                         \
            clearerr(yyin);                                                    \
        }                                                                      \
    } while (0)

struct symbol;

/* Files and streams. A `FILE *` from these is the shim's stream, which only
 * these functions understand; `stderr` and `stdout` are the diagnostics. */
FILE* kconfig_host_fopen(const char* path, const char* mode);
int kconfig_host_fclose(FILE* stream);
size_t kconfig_host_fread(void* ptr, size_t size, size_t nmemb, FILE* stream);
ssize_t kconfig_host_getline(char** lineptr, size_t* n, FILE* stream);
size_t kconfig_host_fwrite(const void* ptr, size_t size, size_t nmemb,
                           FILE* stream);
int kconfig_host_fputs(const char* text, FILE* stream);
int kconfig_host_fputc(int c, FILE* stream);
int kconfig_host_fprintf(FILE* stream, const char* format, ...);
int kconfig_host_vfprintf(FILE* stream, const char* format, va_list ap);
int kconfig_host_printf(const char* format, ...);
int kconfig_host_fflush(FILE* stream);
int kconfig_host_ferror(FILE* stream);
void kconfig_host_clearerr(FILE* stream);
void kconfig_host_perror(const char* prefix);
FILE* kconfig_host_popen(const char* command, const char* mode);
int kconfig_host_pclose(FILE* stream);

/* The filesystem, the environment and the process. */
int kconfig_host_stat(const char* path, struct stat* buf);
int kconfig_host_mkdir(const char* path, mode_t mode);
int kconfig_host_rename(const char* from, const char* to);
int kconfig_host_unlink(const char* path);
char* kconfig_host_getenv(const char* name);
pid_t kconfig_host_getpid(void);
void* kconfig_host_mmap(void* addr, size_t length, int prot, int flags, int fd,
                        off_t offset);
int kconfig_host_munmap(void* addr, size_t length);
void kconfig_host_exit(int code) __attribute__((noreturn));
char* kconfig_host_strndup(const char* s, size_t n);

/* The patch to the parser (kconfiglib_dialect.patch) calls these where the
 * kernel's would exit, or decide alone. */
void kconfig_host_fail(void);
bool kconfig_host_should_write(struct symbol* sym);
const char* kconfig_host_string_value(struct symbol* sym);
/* An `option` of a symbol, `name` or `name=value`, as kconfiglib takes it;
 * NULL, or the message of the error it is. */
const char* kconfig_host_option(struct symbol* sym, const char* name,
                                const char* value);

/* The renames, for the parser's sources; the shim defines
 * KCONFIG_HOST_IMPLEMENTATION and keeps the libc's names. `struct stat` is
 * not a call, so `stat` is renamed as a function-like macro. */
#ifndef KCONFIG_HOST_IMPLEMENTATION
#undef fopen
#undef fclose
#undef fread
#undef getline
#undef fwrite
#undef fputs
#undef fputc
#undef putc
#undef fprintf
#undef vfprintf
#undef printf
#undef fflush
#undef ferror
#undef clearerr
#undef perror
#undef popen
#undef pclose
#undef stat
#undef mkdir
#undef rename
#undef unlink
#undef getenv
#undef getpid
#undef mmap
#undef munmap
#undef exit
#undef strndup
#define fopen kconfig_host_fopen
#define fclose kconfig_host_fclose
#define fread kconfig_host_fread
#define getline kconfig_host_getline
#define fwrite kconfig_host_fwrite
#define fputs kconfig_host_fputs
#define fputc kconfig_host_fputc
#define putc kconfig_host_fputc
#define fprintf kconfig_host_fprintf
#define vfprintf kconfig_host_vfprintf
/* Function-like, so that `format(printf, ...)` attributes keep their name. */
#define printf(...) kconfig_host_printf(__VA_ARGS__)
#define fflush kconfig_host_fflush
#define ferror kconfig_host_ferror
#define clearerr kconfig_host_clearerr
#define perror kconfig_host_perror
#define popen kconfig_host_popen
#define pclose kconfig_host_pclose
#define stat(path, buf) kconfig_host_stat(path, buf)
#define mkdir kconfig_host_mkdir
#define rename kconfig_host_rename
#define unlink kconfig_host_unlink
#define getenv kconfig_host_getenv
#define getpid kconfig_host_getpid
#define mmap kconfig_host_mmap
#define munmap kconfig_host_munmap
#define exit kconfig_host_exit
#define strndup kconfig_host_strndup
#endif

#endif
