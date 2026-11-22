/* The C side of the module: the kernel's parser of one release behind the
 * entry points of shim.h, and the host functions its libc calls are renamed
 * to (see host.h and the BUILD file of the `kernel_kconfig_<id>` repository),
 * served from Rust. The parsers of every release link into one program: this
 * file and the kernel's sources are compiled once per release, with the
 * release's prefix header (kernel/prefix_<id>.h) renaming every exported
 * name, and parsers.c lists the releases' tables for the Rust side.
 *
 * Files the parser opens come from Rust as bytes and are read as in-memory
 * streams; what it writes, the `.config` of `kconfig_shim_config_contents`,
 * stays in memory too, and so does what it prints to stderr, which is the
 * message a failed parse ends in. The patched exit sites report through
 * `kconfig_host_fail` rather than ending the process.
 *
 * The values are the kernel's at the release the parser was built from
 * (RULES_KCONFIG_KERNEL_MAJOR and _MINOR, from the BUILD file of the
 * `kernel_kconfig_<version>` repository); nothing here decides a value. The
 * internals the shim reads changed between the releases: before 5.x a menu
 * node knows its `struct file` and a symbol's nodes are its P_SYMBOL
 * properties; later a node has a `filename` and a symbol a list of menus. */
/* wasi-libc declares `mmap` only as emulated, and the parser's stub is its
 * stand-in. The shim keeps the libc's names: host.h renames them for the
 * parser's sources only. */
#define _WASI_EMULATED_MMAN
#define KCONFIG_HOST_IMPLEMENTATION
#include "shim.h"

#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "expr.h"
#include "host.h"
#include "list.h"
#include "lkc.h"

#if RULES_KCONFIG_KERNEL_MAJOR < 5
#define KCONFIG_LEGACY_MENUS 1
#endif

#define KCONFIG_STRINGIFY_(x) #x
#define KCONFIG_STRINGIFY(x) KCONFIG_STRINGIFY_(x)

/* The type constants of shim.h. */
enum {
    KL_UNKNOWN = 0,
    KL_BOOL = 1,
    KL_TRISTATE = 2,
    KL_STRING = 3,
    KL_INT = 4,
    KL_HEX = 5
};

static int g_parsing;
static int g_parsed;
static int g_failed; /* a patched exit site was reached */

/* The name every `.config` is read through and the one `conf_write` writes
 * to, and what the parser prints to stderr. */
static const char CONFIG_NAME[] = "<kconfig>/.config";
static const char OUTPUT_NAME[] = "<kconfig>/output.config";
static const char STDERR_NAME[] = "<kconfig>/stderr";

/* -- Growable arrays of strings ---------------------------------------------
 */

struct strings {
    char** items;
    size_t len;
    size_t cap;
};

static void strings_push(struct strings* s, char* item) {
    if (s->len == s->cap) {
        s->cap = s->cap ? s->cap * 2 : 16;
        s->items = realloc(s->items, s->cap * sizeof(*s->items));
    }
    s->items[s->len++] = item;
}

static bool strings_contains(const struct strings* s, const char* item) {
    for (size_t i = 0; i < s->len; i++) {
        if (strcmp(s->items[i], item) == 0) {
            return true;
        }
    }
    return false;
}

/* The Kconfig files opened while parsing. */
static struct strings g_filenames;

/* -- In-memory files --------------------------------------------------------
 */

struct memfile {
    char* name;
    char* data;
    size_t len;
    size_t cap;
    struct memfile* next;
};

static struct memfile* g_memfiles;

static struct memfile* memfile_find(const char* name) {
    for (struct memfile* f = g_memfiles; f; f = f->next) {
        if (strcmp(f->name, name) == 0) {
            return f;
        }
    }
    return NULL;
}

static struct memfile* memfile_create(const char* name) {
    struct memfile* f = memfile_find(name);
    if (f == NULL) {
        f = calloc(1, sizeof(*f));
        f->name = strdup(name);
        f->next = g_memfiles;
        g_memfiles = f;
    }
    f->len = 0;
    return f;
}

static void memfile_set(struct memfile* f, const char* data, size_t len) {
    free(f->data);
    f->data = malloc(len + 1);
    memcpy(f->data, data, len);
    f->data[len] = 0;
    f->len = len;
    f->cap = len + 1;
}

static void memfile_remove(const char* name) {
    for (struct memfile** p = &g_memfiles; *p; p = &(*p)->next) {
        if (strcmp((*p)->name, name) == 0) {
            struct memfile* f = *p;
            *p = f->next;
            free(f->name);
            free(f->data);
            free(f);
            return;
        }
    }
}

static void memfile_append(struct memfile* f, const char* buf, size_t size) {
    if (f->len + size + 1 > f->cap) {
        size_t cap = f->cap ? f->cap : 4096;
        while (cap < f->len + size + 1) {
            cap *= 2;
        }
        f->data = realloc(f->data, cap);
        f->cap = cap;
    }
    memcpy(f->data + f->len, buf, size);
    f->len += size;
    f->data[f->len] = 0;
}

/* -- Streams ---------------------------------------------------------------
 *
 * What the parser gets as a `FILE *`: a reader over bytes the stream owns,
 * or a writer appending to a memfile. The parser's stdio calls are renamed
 * to the functions below (host.h), which are the only ones that see these;
 * the libc's stdio never does, so nothing here depends on `fopencookie` or
 * `funopen`. `stderr` and `stdout` are the libc's, and go to the
 * diagnostics. */

struct stream {
    char* data; /* a reader's bytes, owned */
    size_t len;
    size_t pos;
    struct memfile* file; /* a writer's memfile */
    int error;
};

static struct stream* as_stream(FILE* f) { return (struct stream*)f; }

static bool is_console(FILE* f) { return f == stderr || f == stdout; }

/* Takes ownership of `data`, which has `len` bytes and a NUL after them. */
static FILE* open_reader_owned(char* data, size_t len) {
    struct stream* s = calloc(1, sizeof(*s));
    s->data = data;
    s->len = len;
    return (FILE*)s;
}

static FILE* open_reader(const char* data, size_t len) {
    char* copy = malloc(len + 1);
    memcpy(copy, data, len);
    copy[len] = 0;
    return open_reader_owned(copy, len);
}

static FILE* open_writer(struct memfile* f) {
    struct stream* s = calloc(1, sizeof(*s));
    s->file = f;
    return (FILE*)s;
}

static void diagnostic(const char* text, size_t len);

/* Append to a writer, or to the diagnostics for the console. */
static size_t stream_write(FILE* f, const char* buf, size_t size) {
    if (is_console(f)) {
        diagnostic(buf, size);
        return size;
    }
    struct stream* s = as_stream(f);
    if (s->file == NULL) {
        s->error = 1;
        return 0;
    }
    memfile_append(s->file, buf, size);
    return size;
}

int kconfig_host_fclose(FILE* f) {
    if (f == NULL || is_console(f)) {
        return 0;
    }
    struct stream* s = as_stream(f);
    free(s->data);
    free(s);
    return 0;
}

size_t kconfig_host_fread(void* ptr, size_t size, size_t nmemb, FILE* f) {
    if (is_console(f) || size == 0) {
        return 0;
    }
    struct stream* s = as_stream(f);
    if (s->data == NULL) {
        s->error = 1;
        return 0;
    }
    size_t want = size * nmemb;
    size_t left = s->len - s->pos;
    size_t take = want < left ? want : left;
    take -= take % size;
    memcpy(ptr, s->data + s->pos, take);
    s->pos += take;
    return take / size;
}

int kconfig_host_fgetc(FILE* f) {
    if (is_console(f)) {
        return EOF;
    }
    struct stream* s = as_stream(f);
    if (s->data == NULL || s->pos >= s->len) {
        return EOF;
    }
    return (unsigned char)s->data[s->pos++];
}

ssize_t kconfig_host_getline(char** lineptr, size_t* n, FILE* f) {
    if (is_console(f)) {
        return -1;
    }
    struct stream* s = as_stream(f);
    if (s->data == NULL || s->pos >= s->len) {
        return -1;
    }
    const char* start = s->data + s->pos;
    const char* newline = memchr(start, '\n', s->len - s->pos);
    size_t take = newline ? (size_t)(newline - start) + 1 : s->len - s->pos;
    if (*lineptr == NULL || *n < take + 1) {
        *n = take + 1;
        *lineptr = realloc(*lineptr, *n);
    }
    memcpy(*lineptr, start, take);
    (*lineptr)[take] = 0;
    s->pos += take;
    return (ssize_t)take;
}

size_t kconfig_host_fwrite(const void* ptr, size_t size, size_t nmemb,
                           FILE* f) {
    if (size == 0) {
        return 0;
    }
    return stream_write(f, ptr, size * nmemb) / size;
}

int kconfig_host_fputs(const char* text, FILE* f) {
    size_t len = strlen(text);
    return stream_write(f, text, len) == len ? 0 : EOF;
}

int kconfig_host_fputc(int c, FILE* f) {
    char byte = (char)c;
    return stream_write(f, &byte, 1) == 1 ? (unsigned char)c : EOF;
}

int kconfig_host_vfprintf(FILE* f, const char* format, va_list ap) {
    va_list copy;
    va_copy(copy, ap);
    int len = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (len < 0) {
        return len;
    }
    char* text = malloc((size_t)len + 1);
    vsnprintf(text, (size_t)len + 1, format, ap);
    stream_write(f, text, (size_t)len);
    free(text);
    return len;
}

int kconfig_host_fprintf(FILE* f, const char* format, ...) {
    va_list ap;
    va_start(ap, format);
    int len = kconfig_host_vfprintf(f, format, ap);
    va_end(ap);
    return len;
}

int kconfig_host_printf(const char* format, ...) {
    va_list ap;
    va_start(ap, format);
    int len = kconfig_host_vfprintf(stdout, format, ap);
    va_end(ap);
    return len;
}

int kconfig_host_fflush(FILE* f) {
    (void)f;
    return 0;
}

int kconfig_host_ferror(FILE* f) {
    return is_console(f) ? 0 : as_stream(f)->error;
}

void kconfig_host_clearerr(FILE* f) {
    if (!is_console(f)) {
        as_stream(f)->error = 0;
    }
}

char* kconfig_host_strndup(const char* s, size_t n) {
    size_t len = 0;
    while (len < n && s[len] != 0) {
        len++;
    }
    char* copy = malloc(len + 1);
    memcpy(copy, s, len);
    copy[len] = 0;
    return copy;
}

/* -- The host ---------------------------------------------------------------
 */

/* `\r\n` read as `\n`, so that a tree checked out with CRLF line endings
 * (Windows) parses as the same tree with LF; the kernel's lexer would keep
 * the `\r` in a variable's value (`VERSION := $(shell,...)`). */
static size_t strip_carriage_returns(char* data, size_t len) {
    size_t out = 0;
    for (size_t i = 0; i < len; i++) {
        if (data[i] == '\r' && i + 1 < len && data[i + 1] == '\n') {
            continue;
        }
        data[out++] = data[i];
    }
    if (out < len) {
        data[out] = 0;
    }
    return out;
}

FILE* kconfig_host_fopen(const char* path, const char* mode) {
    if (strchr(mode, 'w') || strchr(mode, 'a')) {
        return open_writer(memfile_create(path));
    }
    struct memfile* f = memfile_find(path);
    if (f != NULL) {
        return open_reader(f->data ? f->data : "", f->len);
    }
    /* The module has no working directory: a relative name is not a file,
     * and the parser then tries it under `srctree`. */
    if (path[0] != '/') {
        errno = ENOENT;
        return NULL;
    }
    size_t len = 0;
    int status = 0;
    char* data = kconfig_rust_read(path, &len, &status);
    if (status != 0 || data == NULL) {
        free(data);
        errno = ENOENT;
        return NULL;
    }
    if (g_parsing) {
        /* Relative to `srctree`, where the parser found the file under it. */
        const char* srctree = kconfig_host_getenv("srctree");
        size_t prefix = srctree != NULL ? strlen(srctree) : 0;
        const char* listed = path;
        if (prefix > 0 && strncmp(path, srctree, prefix) == 0 &&
            path[prefix] == '/') {
            listed = path + prefix + 1;
        }
        if (!strings_contains(&g_filenames, listed)) {
            strings_push(&g_filenames, strdup(listed));
        }
    }
    len = strip_carriage_returns(data, len);
    return open_reader_owned(data, len);
}

/* The values handed out, kept alive: the parser holds on to what `getenv`
 * returns. */
struct env_value {
    char* name;
    char* value;
    struct env_value* next;
};

static struct env_value* g_env_values;

char* kconfig_host_getenv(const char* name) {
    /* `conf_write` writes in place with this set, instead of through a
     * temporary file it would rename. */
    if (strcmp(name, "KCONFIG_OVERWRITECONFIG") == 0) {
        return "1";
    }
    /* The kernel's own knobs: the lexer's debug output, and warnings (or
     * errors, with KCONFIG_WERROR) for symbols a `.config` names that the
     * tree does not. The repository is generated the same whatever the
     * host's environment, so neither is read from it. */
    if (strcmp(name, "ZCONF_DEBUG") == 0 ||
        strcmp(name, "KCONFIG_WARN_UNKNOWN_SYMBOLS") == 0 ||
        strcmp(name, "KCONFIG_WERROR") == 0) {
        return NULL;
    }
    char* value = kconfig_rust_getenv(name);
    if (value == NULL) {
        return NULL;
    }
    for (struct env_value* e = g_env_values; e; e = e->next) {
        if (strcmp(e->name, name) == 0 && strcmp(e->value, value) == 0) {
            free(value);
            return e->value;
        }
    }
    struct env_value* e = malloc(sizeof(*e));
    e->name = strdup(name);
    e->value = value;
    e->next = g_env_values;
    g_env_values = e;
    return value;
}

FILE* kconfig_host_popen(const char* command, const char* mode) {
    (void)mode;
    size_t len = 0;
    char* output = kconfig_rust_shell(command, &len);
    if (output == NULL) {
        return open_reader("", 0);
    }
    return open_reader_owned(output, len);
}

int kconfig_host_pclose(FILE* stream) { return kconfig_host_fclose(stream); }

/* What the parser prints to stderr: its warnings, and the errors it then
 * fails on. */
static void diagnostic(const char* text, size_t len) {
    struct memfile* f = memfile_find(STDERR_NAME);
    if (f == NULL) {
        f = memfile_create(STDERR_NAME);
    }
    memfile_append(f, text, len);
}

void kconfig_host_perror(const char* prefix) {
    kconfig_host_fprintf(stderr, "%s: %s\n", prefix, strerror(errno));
}

void kconfig_host_fail(void) { g_failed = 1; }

/* Out of memory, or the root file missing, which `kconfig_shim_parse` rules
 * out first: nothing to return to. */
void kconfig_host_exit(int code) {
    (void)code;
    __builtin_trap();
}

int kconfig_host_stat(const char* path, struct stat* buf) {
    memset(buf, 0, sizeof(*buf));
    struct memfile* f = memfile_find(path);
    if (f != NULL) {
        buf->st_mode = S_IFREG | 0644;
        buf->st_size = (off_t)f->len;
        return 0;
    }
    /* The in-memory names are never the host's to answer for. */
    if (strncmp(path, "<kconfig>", strlen("<kconfig>")) == 0) {
        errno = ENOENT;
        return -1;
    }
    if (kconfig_rust_isdir(path)) {
        buf->st_mode = S_IFDIR | 0755;
        return 0;
    }
    if (kconfig_rust_exists(path)) {
        buf->st_mode = S_IFREG | 0644;
        return 0;
    }
    errno = ENOENT;
    return -1;
}

int kconfig_host_mkdir(const char* path, mode_t mode) {
    (void)path;
    (void)mode;
    return 0;
}

int kconfig_host_rename(const char* from, const char* to) {
    struct memfile* f = memfile_find(from);
    if (f == NULL) {
        errno = ENOENT;
        return -1;
    }
    memfile_remove(to);
    free(f->name);
    f->name = strdup(to);
    return 0;
}

int kconfig_host_unlink(const char* path) {
    memfile_remove(path);
    return 0;
}

pid_t kconfig_host_getpid(void) { return 1; }

void* kconfig_host_mmap(void* addr, size_t length, int prot, int flags, int fd,
                        off_t offset) {
    (void)addr;
    (void)length;
    (void)prot;
    (void)flags;
    (void)fd;
    (void)offset;
    errno = ENODEV;
    return MAP_FAILED;
}

int kconfig_host_munmap(void* addr, size_t length) {
    (void)addr;
    (void)length;
    return 0;
}

/* -- The parser -------------------------------------------------------------
 */

static struct menu* next_menu(struct menu* menu) {
    if (menu->list != NULL) {
        return menu->list;
    }
    while (menu != &rootmenu && menu->next == NULL) {
        menu = menu->parent;
    }
    return menu == &rootmenu ? NULL : menu->next;
}

static int kconfig_shim_parse(const char* filename) {
    if (g_parsed) {
        return 3;
    }
    g_parsed = 1;
    /* `conf_write` would print "configuration written to" on stdout. */
    conf_set_message_callback(NULL);
    /* The parser exits for a root file it cannot open; it is ruled out here. */
    FILE* root = kconfig_host_fopen(filename, "r");
    if (root == NULL) {
        return 1;
    }
    kconfig_host_fclose(root);
    g_parsing = 1;
    conf_parse(filename);
    g_parsing = 0;
    if (g_failed) {
        return 2;
    }
    sym_clear_all_valid();
    return 0;
}

static const char* kconfig_shim_diagnostics(size_t* len) {
    struct memfile* f = memfile_find(STDERR_NAME);
    *len = f ? f->len : 0;
    return f && f->data ? f->data : "";
}

static const char* const* kconfig_shim_filenames(size_t* count) {
    *count = g_filenames.len;
    return (const char* const*)g_filenames.items;
}

static int kconfig_shim_load_config(const char* text, size_t len) {
    memfile_set(memfile_create(CONFIG_NAME), text, len);
    return conf_read(CONFIG_NAME);
}

static const char* kconfig_shim_config_contents(size_t* len) {
    if (conf_write(OUTPUT_NAME) != 0) {
        return NULL;
    }
    struct memfile* f = memfile_find(OUTPUT_NAME);
    *len = f ? f->len : 0;
    return f && f->data ? f->data : "";
}

static struct symbol** kconfig_shim_menu_symbols(size_t* count) {
    size_t cap = 256;
    size_t len = 0;
    struct symbol** syms = malloc(cap * sizeof(*syms));
    for (struct menu* menu = rootmenu.list; menu != NULL;
         menu = next_menu(menu)) {
        struct symbol* sym = menu->sym;
        /* A choice is not a symbol of the repository, named or not. */
        if (sym == NULL || sym->name == NULL || sym_is_choice(sym)) {
            continue;
        }
        if (len == cap) {
            cap *= 2;
            syms = realloc(syms, cap * sizeof(*syms));
        }
        syms[len++] = sym;
    }
    *count = len;
    return syms;
}

static const char* kconfig_shim_symbol_name(struct symbol* sym) {
    return sym->name ? sym->name : "";
}

static int kconfig_shim_symbol_type(struct symbol* sym) {
    switch (sym->type) {
        case S_BOOLEAN:
            return KL_BOOL;
        case S_TRISTATE:
            return KL_TRISTATE;
        case S_INT:
            return KL_INT;
        case S_HEX:
            return KL_HEX;
        case S_STRING:
            return KL_STRING;
        default:
            return KL_UNKNOWN;
    }
}

static const char* kconfig_shim_symbol_str_value(struct symbol* sym) {
    sym_calc_value(sym);
    return sym_get_string_value(sym);
}

static int kconfig_shim_symbol_has_user_value(struct symbol* sym) {
    return sym_has_value(sym);
}

static int kconfig_shim_symbol_visible(struct symbol* sym) {
    sym_calc_value(sym);
    return sym->visible != no;
}

static int kconfig_shim_symbol_user_tri(struct symbol* sym) {
    return (int)sym->def[S_DEF_USER].tri;
}

static const char* kconfig_shim_symbol_user_str(struct symbol* sym) {
    const char* val = sym->def[S_DEF_USER].val;
    return val ? val : "";
}

static struct menu** push_node(struct menu** nodes, size_t* len, size_t* cap,
                               struct menu* menu) {
    if (*len == *cap) {
        *cap *= 2;
        nodes = realloc(nodes, *cap * sizeof(*nodes));
    }
    nodes[(*len)++] = menu;
    return nodes;
}

static struct menu** kconfig_shim_symbol_nodes(struct symbol* sym,
                                               size_t* count) {
    size_t cap = 4;
    size_t len = 0;
    struct menu** nodes = malloc(cap * sizeof(*nodes));
#ifdef KCONFIG_LEGACY_MENUS
    struct property* prop;
    for_all_properties(sym, prop, P_SYMBOL) {
        nodes = push_node(nodes, &len, &cap, prop->menu);
    }
#else
    struct menu* menu;
    list_for_each_entry(menu, &sym->menus, link) {
        nodes = push_node(nodes, &len, &cap, menu);
    }
#endif
    *count = len;
    return nodes;
}

static const char* kconfig_shim_menu_filename(struct menu* menu) {
#ifdef KCONFIG_LEGACY_MENUS
    return menu->file && menu->file->name ? menu->file->name : "";
#else
    return menu->filename ? menu->filename : "";
#endif
}

static int kconfig_shim_menu_lineno(struct menu* menu) { return menu->lineno; }

/* The entry points, as the Rust side reaches them (shim.h); under the prefix
 * of the release (kernel/prefix_<id>.h), and listed by parsers.c. */
const struct kconfig_shim kconfig_shim_vtable = {
    .version =
        KCONFIG_STRINGIFY(RULES_KCONFIG_KERNEL_MAJOR) "." KCONFIG_STRINGIFY(
            RULES_KCONFIG_KERNEL_MINOR),
    .parse = kconfig_shim_parse,
    .diagnostics = kconfig_shim_diagnostics,
    .filenames = kconfig_shim_filenames,
    .load_config = kconfig_shim_load_config,
    .config_contents = kconfig_shim_config_contents,
    .menu_symbols = kconfig_shim_menu_symbols,
    .symbol_name = kconfig_shim_symbol_name,
    .symbol_type = kconfig_shim_symbol_type,
    .symbol_str_value = kconfig_shim_symbol_str_value,
    .symbol_has_user_value = kconfig_shim_symbol_has_user_value,
    .symbol_visible = kconfig_shim_symbol_visible,
    .symbol_user_tri = kconfig_shim_symbol_user_tri,
    .symbol_user_str = kconfig_shim_symbol_user_str,
    .symbol_nodes = kconfig_shim_symbol_nodes,
    .menu_filename = kconfig_shim_menu_filename,
    .menu_lineno = kconfig_shim_menu_lineno,
};
