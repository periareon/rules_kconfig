# rules_kconfig

Bazel rules for [Kconfig](https://www.kernel.org/doc/html/latest/kbuild/kconfig-language.html).

## Documentation

Additional documentation can be found at <https://periareon.github.io/rules_kconfig/>

## Backends

Kconfig trees are parsed by the Linux kernel's own parser, which each release
publishes as a WebAssembly module (Bazel 9.3 or newer with
`--experimental_repository_ctx_execute_wasm`) and as a native build per
platform; no Python interpreter is needed. Both generate the same repository,
and the same one [kconfiglib](https://github.com/ulfalizer/Kconfiglib)
generated before the parser replaced it. See the documentation for details.
