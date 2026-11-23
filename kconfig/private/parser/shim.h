/* The surface of the kernel's parser the Rust module uses, and what the parser
 * asks of Rust in return. See shim.c for the C side and src/ffi.rs for the
 * Rust side. Every struct stays opaque to Rust: the accessors here are the
 * binding, so one declaration serves wasm32 and the 64-bit hosts alike. */
#ifndef RULES_KCONFIG_SHIM_H
#define RULES_KCONFIG_SHIM_H

#include <stddef.h>

struct symbol;
struct menu;

/* -- Provided by Rust --------------------------------------------------------
 *
 * The host of the round protocol: files, directories, the environment and
 * the shell as Starlark has provided them so far. What is not known yet is
 * answered with a placeholder and recorded. Strings returned are `malloc`ed
 * for the caller to `free`. */

/* The bytes of a file. `status` is 0 with the content (empty while unknown),
 * 1 when the file does not exist, 2 when it is a directory. */
char* kconfig_rust_read(const char* path, size_t* len, int* status);
int kconfig_rust_isdir(const char* path);
int kconfig_rust_exists(const char* path);
/* The variable's value, or NULL when unset or unknown. */
char* kconfig_rust_getenv(const char* name);
/* The output of a `$(shell,...)` command as the parser should read it. */
char* kconfig_rust_shell(const char* command, size_t* len);

/* -- The parsers ------------------------------------------------------------
 *
 * The parser of each kernel release is linked in once, every exported name
 * under the release's prefix (kernel/prefix_<id>.h), and reached through its
 * table: `kconfig_shim_vtable` of shim.c, which the prefix renames too, and
 * which `kconfig_parsers` (parsers.c, generated) lists newest first, ending
 * in NULL. A parser keeps its state in globals and cannot start over: one
 * parse per process, or per instance of the WebAssembly module. */
struct kconfig_shim {
    /* The kernel release, "6.12", as `kconfig_version` names it. */
    const char* version;

    /* Parse the tree rooted at `filename`. 0 on success; 1 when the root
     * cannot be opened, with `errno` set; 2 when the parse failed, with the
     * message in `diagnostics`; 3 when a tree was parsed already. */
    int (*parse)(const char* filename);

    /* What the parser wrote to stderr so far. */
    const char* (*diagnostics)(size_t* len);

    /* The Kconfig files read while parsing, in order, relative to `srctree`
     * where they are under it. */
    const char* const* (*filenames)(size_t* count);

    /* `conf_read` of a `.config` given as text; nonzero on failure. */
    int (*load_config)(const char* text, size_t len);

    /* The `.config` `conf_write` writes, without its heading; NULL on
     * failure. */
    const char* (*config_contents)(size_t* len);

    /* The symbol of every menu node, depth first in the order of the tree,
     * with repeats and without choices; `free` the array. */
    struct symbol** (*menu_symbols)(size_t* count);

    const char* (*symbol_name)(struct symbol* sym);
    /* The type: UNKNOWN 0, BOOL 1, TRISTATE 2, STRING 3, INT 4, HEX 5. */
    int (*symbol_type)(struct symbol* sym);
    /* The value as `conf` writes it, calculated (`sym_get_string_value`). */
    const char* (*symbol_str_value)(struct symbol* sym);
    /* Whether a `.config` set the symbol. */
    int (*symbol_has_user_value)(struct symbol* sym);
    /* Whether a `.config` can set the symbol: it has a prompt whose
     * condition holds (calculated). */
    int (*symbol_visible)(struct symbol* sym);
    /* Whether the Kconfig tools write the symbol to `.config` and
     * `autoconf.h`: it is visible or a default applies (calculated). A
     * symbol they do not write has no value, whatever
     * `symbol_str_value` returns. */
    int (*symbol_written)(struct symbol* sym);
    /* The user value of a bool or tristate: 0, 1 or 2. */
    int (*symbol_user_tri)(struct symbol* sym);
    /* The user value of any other type. */
    const char* (*symbol_user_str)(struct symbol* sym);
    /* The menu nodes defining the symbol; `free` the array. */
    struct menu** (*symbol_nodes)(struct symbol* sym, size_t* count);

    const char* (*menu_filename)(struct menu* menu);
    int (*menu_lineno)(struct menu* menu);
};

/* The table of the release shim.c is compiled for. */
extern const struct kconfig_shim kconfig_shim_vtable;

/* The tables of every release linked in, newest first, then NULL. */
extern const struct kconfig_shim* const kconfig_parsers[];

#endif
