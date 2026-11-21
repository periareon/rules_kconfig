"""The kernel's Kconfig parser, fetched for the WebAssembly module.

`kconfig.wasm` parses with the C implementation from Linux (`scripts/kconfig`,
GPL-2.0), compiled to WebAssembly and linked into the Rust module behind
`kconfig/private/parser/shim.c`. This repository rule fetches the files
of one kernel release by hash, applies `kconfiglib_dialect.patch` and writes
the BUILD file that compiles them, from `BUILD.linux_kconfig.bazel`. The host
calls the sources make are renamed to the functions of the shim, which serve
them from the module's host (see `host.h`).

The release is 6.9, the last with `optional` choices, which kconfiglib
supports and trees such as U-Boot's use. The patch restores more of what
kconfiglib accepts and later kernels dropped: `---help---`, `/` and `.` in
unquoted words, as in `source lib/mbedtls/Kconfig`, and the `option`
statement; and a value kconfiglib and the kernels U-Boot's kconfig comes
from calculate differently: an int or hex symbol nothing sets is "", not
"0" or "0x0", so that `default 0x5fa0 if SUNXI_SRAM_ADDRESS = 0x0` does not
apply to a board without the symbol (U-Boot's `SPL_MAX_SIZE`).
"""

_TAG = "v6.9"

_URL = "https://raw.githubusercontent.com/torvalds/linux/{tag}/scripts/{path}"

# The files of the parser, by path under `scripts/`, and their SHA-256.
_FILES = {
    "kconfig/array_size.h": "90ea8c7000afb1f9ad8504dcc24c1ddcd3c08239787248b617fc632ed3577ce4",
    "kconfig/confdata.c": "cf9d9fd85667739ec793e621d0e929e586367ce13b609268bcfbf434f3914cc9",
    "kconfig/expr.c": "bc5b386694072f56348cd6d2c0fbe91cdf0dbd31809bf815a6c075bae03c7cb5",
    "kconfig/expr.h": "4f0fda1f44089fe865e4af181d81a18f00d7c6660b4badee3f2e27609ed49dc6",
    "kconfig/hashtable.h": "91232a3bb29efe1c6a443f602bdea9ce69f6e38f77fc631742a095c2e86b3e26",
    "kconfig/internal.h": "4686ba223ea1f6512f3379b8fe5ef338cc1afd1f6ed5d045f4fb4cfd1ba81a17",
    "kconfig/lexer.l": "5e99b9cf56574a3b4a6e5a62fee4456e678da1aa9c91c1e6691b1a1819355180",
    "kconfig/list.h": "17ab845857ce614e5ae8aa89c8e66d40c97df12156a680a83f9b6fc435398eb1",
    "kconfig/list_types.h": "36df90fe1e5b16bff75afbbe2b0018f21eaeca9fe67f95e054cf645f28071356",
    "kconfig/lkc.h": "d15335c45a666cf617a157f2efb766caa7427f26d87ba7eba38e9d1f04e33f7d",
    "kconfig/lkc_proto.h": "448a0f9dc3daa7ada69d9c3b8aa8e1699a61a805df9c711cad7cab86e343e3d4",
    "kconfig/menu.c": "6008b5f96e6c801c3985f6fafd2a4c2e47d89fb08738ec0c0b2082c282608a15",
    "kconfig/parser.y": "b1960ed6f78ab21c1ef6b66142d38960f45887cfc03443304e8994035ada4830",
    "kconfig/preprocess.c": "3f084c125c2cbc56024d01d4c5d52e7cf1d92f5b776f734c17c362d880dc56fe",
    "kconfig/preprocess.h": "f7e9581e1d92804acadca02ffdbd298e681cb4d1fb1e04bacb59e0e2a7fe6f9b",
    "kconfig/symbol.c": "af2eee55d351f781a049f1f0c97f98c6e34879d8f8b9a1d953d45080b5e69cd3",
    "kconfig/util.c": "31472e70138bb50b3f918bda3325d5f00258e95d3e9e0f8155a38f73eeea7788",
}

def _kernel_kconfig_repository_impl(repository_ctx):
    for path, sha256 in _FILES.items():
        output = path[len("kconfig/"):] if path.startswith("kconfig/") else path
        repository_ctx.download(
            url = _URL.format(tag = _TAG, path = path),
            output = output,
            sha256 = sha256,
        )
    repository_ctx.patch(Label("//kconfig/private/parser/kernel:kconfiglib_dialect.patch"), strip = 1)
    repository_ctx.template(
        "BUILD.bazel",
        Label("//kconfig/private/parser/kernel:BUILD.linux_kconfig.bazel"),
        substitutions = {"{tag}": _TAG},
    )
    repository_ctx.file("WORKSPACE.bazel", "workspace(name = \"{}\")\n".format(repository_ctx.name))
    if hasattr(repository_ctx, "repo_metadata"):
        return repository_ctx.repo_metadata(reproducible = True)
    return None

kernel_kconfig_repository = repository_rule(
    doc = "The Kconfig parser of Linux {}, fetched file by file by hash, with a BUILD file that compiles it for the WebAssembly module.".format(_TAG),
    implementation = _kernel_kconfig_repository_impl,
)
