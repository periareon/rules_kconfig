# rules_kconfig

Bazel rules for [Kconfig](https://www.kernel.org/doc/html/latest/kbuild/kconfig-language.html).

## Documentation

Additional documentation can be found at <https://periareon.github.io/rules_kconfig/>

## Backends

Kconfig trees are parsed by [kconfiglib](https://github.com/ulfalizer/Kconfiglib),
either inside the WebAssembly module each release publishes (Bazel 9.3 or newer with
`--experimental_repository_ctx_execute_wasm`; no Python interpreter needed) or on
a Python interpreter named by the `interpreter` attribute. See the documentation
for details.
