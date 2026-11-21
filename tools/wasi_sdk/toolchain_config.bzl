"""The configuration of the wasi-sdk `cc_toolchain` (see repository.bzl).

The toolchain is clang with `--target=wasm32-wasip1` and the SDK's sysroot,
and otherwise Bazel's legacy features, which supply the `-c`, `-o`, `-I`,
`-D` and dependency file handling. It declares neither `supports_pic` nor
`supports_dynamic_linker`: everything is compiled as non-PIC objects and
linked statically, as WebAssembly modules are, so that a `cc_library` built
for the platform is only its archive and nothing attempts a shared `.wasm`.
"""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load(
    "@rules_cc//cc:cc_toolchain_config_lib.bzl",
    "feature",
    "flag_group",
    "flag_set",
    "tool_path",
    "with_feature_set",
)
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")

_COMPILE_ACTIONS = [
    ACTION_NAMES.assemble,
    ACTION_NAMES.preprocess_assemble,
    ACTION_NAMES.c_compile,
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.cpp_header_parsing,
    ACTION_NAMES.cpp_module_compile,
    ACTION_NAMES.cpp_module_codegen,
    ACTION_NAMES.linkstamp_compile,
    ACTION_NAMES.clif_match,
]

_LINK_ACTIONS = [
    ACTION_NAMES.cpp_link_executable,
    ACTION_NAMES.cpp_link_dynamic_library,
    ACTION_NAMES.cpp_link_nodeps_dynamic_library,
]

_TARGET_FLAGS = [
    "--target=wasm32-wasip1",
    "-no-canonical-prefixes",
]

# The tools of the SDK's `bin`, by the names Bazel asks for.
_TOOLS = {
    "ar": "llvm-ar",
    "cpp": "clang-cpp",
    "gcc": "clang",
    "ld": "wasm-ld",
    "nm": "llvm-nm",
    "objcopy": "llvm-objcopy",
    "objdump": "llvm-objdump",
    "strip": "llvm-strip",
}

def _wasi_sdk_cc_toolchain_config_impl(ctx):
    sdk = ctx.attr.sdk
    sysroot = sdk + "/share/wasi-sysroot"

    features = [
        # Bazel requests the feature named after the compilation mode; a
        # toolchain has to declare them for the request to reach `with_features`.
        feature(name = "dbg"),
        feature(name = "fastbuild"),
        feature(name = "opt"),
        feature(
            name = "default_compile_flags",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = _COMPILE_ACTIONS,
                    flag_groups = [flag_group(flags = _TARGET_FLAGS)],
                ),
                flag_set(
                    actions = _COMPILE_ACTIONS,
                    flag_groups = [flag_group(flags = ["-g"])],
                    with_features = [with_feature_set(features = ["dbg"])],
                ),
                flag_set(
                    actions = _COMPILE_ACTIONS,
                    flag_groups = [flag_group(flags = [
                        "-O2",
                        "-DNDEBUG",
                        "-ffunction-sections",
                        "-fdata-sections",
                    ])],
                    with_features = [with_feature_set(features = ["opt"])],
                ),
            ],
        ),
        # Replaces the legacy feature of the same name, which only expands the
        # variable; the macros keep the output independent of when it is built.
        feature(
            name = "unfiltered_compile_flags",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = _COMPILE_ACTIONS,
                    flag_groups = [
                        flag_group(flags = [
                            "-Wno-builtin-macro-redefined",
                            "-D__DATE__=\"redacted\"",
                            "-D__TIMESTAMP__=\"redacted\"",
                            "-D__TIME__=\"redacted\"",
                        ]),
                        flag_group(
                            flags = ["%{unfiltered_compile_flags}"],
                            iterate_over = "unfiltered_compile_flags",
                            expand_if_available = "unfiltered_compile_flags",
                        ),
                    ],
                ),
            ],
        ),
        feature(
            name = "default_link_flags",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = _LINK_ACTIONS,
                    flag_groups = [flag_group(flags = _TARGET_FLAGS)],
                ),
                flag_set(
                    actions = _LINK_ACTIONS,
                    flag_groups = [flag_group(flags = ["-Wl,--gc-sections"])],
                    with_features = [with_feature_set(features = ["opt"])],
                ),
            ],
        ),
    ]

    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        abi_libc_version = "unknown",
        abi_version = "unknown",
        builtin_sysroot = sysroot,
        compiler = "clang",
        # Where the headers that are not inputs of an action come from: the
        # sysroot and clang's own. Execroot-relative, as the compiler is run.
        cxx_builtin_include_directories = [
            "%sysroot%/include/wasm32-wasip1",
            "%sysroot%/include",
            "{}/lib/clang/{}/include".format(sdk, ctx.attr.clang_major),
        ],
        features = features,
        host_system_name = "local",
        target_cpu = "wasm32",
        target_libc = "wasi-libc",
        target_system_name = "wasm32-wasip1",
        tool_paths = [
            tool_path(name = name, path = "bin/{}{}".format(tool, ctx.attr.exe))
            for name, tool in _TOOLS.items()
        ],
        toolchain_identifier = "wasi-sdk-{}-wasm32-wasip1".format(ctx.attr.version),
    )

wasi_sdk_cc_toolchain_config = rule(
    doc = "The `CcToolchainConfigInfo` of a wasi-sdk `cc_toolchain` for `wasm32-wasip1`.",
    implementation = _wasi_sdk_cc_toolchain_config_impl,
    attrs = {
        "clang_major": attr.string(
            doc = "The major version of the SDK's clang, which names its resource directory under `lib/clang`.",
            mandatory = True,
        ),
        "exe": attr.string(
            doc = "The suffix of the SDK's executables: `.exe` on Windows, empty elsewhere.",
        ),
        "sdk": attr.string(
            doc = "The execroot-relative path of the SDK, `external/<repository>`.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The wasi-sdk release, for the toolchain's identifier.",
            mandatory = True,
        ),
    },
    provides = [CcToolchainConfigInfo],
)
