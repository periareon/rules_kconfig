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
 * answered with a placeholder and recorded, as entry.py's Host did. Strings
 * returned are `malloc`ed for the caller to `free`. */

/* The bytes of a file. `status` is 0 with the content (empty while unknown),
 * 1 when the file does not exist, 2 when it is a directory. */
char* kconfig_rust_read(const char* path, size_t* len, int* status);
int kconfig_rust_isdir(const char* path);
int kconfig_rust_exists(const char* path);
/* The variable's value, or NULL when unset or unknown. */
char* kconfig_rust_getenv(const char* name);
/* The output of a `$(shell,...)` command as the parser should read it. */
char* kconfig_rust_shell(const char* command, size_t* len);

/* -- The parser -------------------------------------------------------------
 *
 * The parser keeps its state in globals and cannot start over: one parse per
 * process, or per instance of the WebAssembly module. */

/* Parse the tree rooted at `filename`. 0 on success; 1 when the root cannot
 * be opened, with `errno` set; 2 when the parse failed, with the message in
 * `kconfig_shim_diagnostics`; 3 when a tree was parsed already. */
int kconfig_shim_parse(const char* filename);

/* What the parser wrote to stderr so far. */
const char* kconfig_shim_diagnostics(size_t* len);

/* The Kconfig files read while parsing, in order, relative to `srctree` where
 * they are under it, as kconfiglib's `kconfig_filenames`. */
const char* const* kconfig_shim_filenames(size_t* count);

/* `conf_read` of a `.config` given as text; nonzero on failure. */
int kconfig_shim_load_config(const char* text, size_t len);

/* The `.config` `conf_write` writes, without its heading; NULL on failure. */
const char* kconfig_shim_config_contents(size_t* len);

/* The symbol of every menu node, depth first in the order of the tree, with
 * repeats and without choices; `free` the array. */
struct symbol** kconfig_shim_menu_symbols(size_t* count);

const char* kconfig_shim_symbol_name(struct symbol* sym);
/* kconfiglib's type constant: UNKNOWN 0, BOOL 1, TRISTATE 2, STRING 3, INT 4,
 * HEX 5. */
int kconfig_shim_symbol_type(struct symbol* sym);
/* kconfiglib's `str_value`, calculated. */
const char* kconfig_shim_symbol_str_value(struct symbol* sym);
/* Whether a `.config` set the symbol. */
int kconfig_shim_symbol_has_user_value(struct symbol* sym);
/* Whether a `.config` can set the symbol: it has a prompt whose condition
 * holds (kconfiglib's `visibility`, calculated). */
int kconfig_shim_symbol_visible(struct symbol* sym);
/* The user value of a bool or tristate: 0, 1 or 2. */
int kconfig_shim_symbol_user_tri(struct symbol* sym);
/* The user value of any other type. */
const char* kconfig_shim_symbol_user_str(struct symbol* sym);
/* The menu nodes defining the symbol; `free` the array. */
struct menu** kconfig_shim_symbol_nodes(struct symbol* sym, size_t* count);

const char* kconfig_shim_menu_filename(struct menu* menu);
int kconfig_shim_menu_lineno(struct menu* menu);

#endif
