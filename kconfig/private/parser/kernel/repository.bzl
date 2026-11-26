"""The kernel's Kconfig parser, fetched for the parser builds, per version,
and its `mconf`, for `menuconfig`.

The parser rules_kconfig ships is the C implementation from Linux
(`scripts/kconfig`, GPL-2.0), linked behind `kconfig/private/parser/shim.c`
and built natively and to WebAssembly. Kconfig has no version of its own, so
a version of the parser is a kernel release (see `//kconfig/private:versions.bzl`),
and this repository rule fetches the files of one release by hash, applies
the host patch for it and writes the BUILD file that compiles them.

The parsers of every version link into one program, each compiled with a
prefix header (`prefix_<id>.h`) that renames its exported names.

The host patch changes nothing in what the parser accepts or calculates: it
makes the places where `conf` would `exit(1)` report to the host instead
(`kconfig_host_fail`), with the message `conf` would print, so that the
module returns an error; it drops the heading `conf_write` puts at the top
of a `.config`, which the generators write themselves; and, when the host
asks (`write_invisible`), it has `conf_write` write the symbols it would
leave out as well, each in its place (`kconfig_host_write_unset`). The libc calls
the sources make for files, the environment and the shell are renamed to the
shim's by `host.h`, which every source is compiled with (see the BUILD
files).
"""

load("//kconfig/private:versions.bzl", "PARSER_VERSIONS", "version_id")

_URL = "https://raw.githubusercontent.com/torvalds/linux/{tag}/scripts/{path}"

# The files of `mconf`, the kernel's menuconfig (scripts/kconfig/mconf.c
# over the lxdialog widgets and the same parser), per version. They are
# fetched unpatched under `menuconfig/`, with a second copy of the parser's
# sources: the host patch is for the shim, and mconf is the program as
# released, run by `menuconfig` on the machine `bazel run` is on.
_MCONF = {
    "4.19": {
        "kconfig/lxdialog/checklist.c": "c7ef84cb4b8fa47bd70aa2e89f7b96b2487c7716e1b5b2f1cb1ba79217d70724",
        "kconfig/lxdialog/dialog.h": "026a00fb501f44746f56af7a56ddead4ea6eee6bcd3dc2f2390caa11f0beba53",
        "kconfig/lxdialog/inputbox.c": "8ef095a6b57a082d89d029c8da3fbdaa16e83a231ac0598623f67e07dc0895f4",
        "kconfig/lxdialog/menubox.c": "5e9ff7e9200872abc7390c5d297e274043d86885477a10f8844e968e78dad359",
        "kconfig/lxdialog/textbox.c": "8a665a7950e260d3e3207f0b792e6b99e8db28ecd3c0849653703c83ce995ab8",
        "kconfig/lxdialog/util.c": "1412c8d13ec9ef79f4acf9e35ea467ef3c383f1950bcf16e231e5263334df5ff",
        "kconfig/lxdialog/yesno.c": "5f1ca4233702a3badd507f56679c634cf4fb054ba662bd729712b2a68a705701",
        "kconfig/mconf.c": "aabe589ae17664e728ff79415eb3a0fc28a7fce5898eb67c98eab9799fc9b9be",
    },
    "6.12": {
        "kconfig/lxdialog/checklist.c": "a5fa74b3ccbbfe9e922f1826159df05a1cd1cc0530bfe2a952fb217b980339be",
        "kconfig/lxdialog/dialog.h": "39813ccd980e42dc910b8070294d65ef38b76326ee229bcd2563d75028263337",
        "kconfig/lxdialog/inputbox.c": "f89f112ae1222decf7507f2d038901374facb85120be740f7f9a97485d7d1afb",
        "kconfig/lxdialog/menubox.c": "1d23e00503e424372a38a3ccd7abd759e9b2c01fb94b99b37b3957df05de1bbe",
        "kconfig/lxdialog/textbox.c": "9d74ba950894702fec79e9c4462ec9c82c2e7f1f10e0b3d5bf93ea4a8c414806",
        "kconfig/lxdialog/util.c": "1350741095ce907cfb2da13765cc169f3321d4b915954c9ef0ac57084cc049b6",
        "kconfig/lxdialog/yesno.c": "4da4dec3cc1ee87b839ce3612c57e47976a658b3144d8b087b1e2621d5991134",
        "kconfig/mconf.c": "27307b1f4d0ca3717ad2e1391e9697d34d9b90e84026a61c0ece22e3f84f6727",
        "kconfig/mnconf-common.c": "0681901f2ccf1188d624407e0321952bff15989f34b6a583ba2fdee6128989a5",
        "kconfig/mnconf-common.h": "8f24b6108b76594bfb50079623885e1e2ab12183fc182a28f6de4c6a8c861d06",
    },
}

# Each version: the kernel tag, the files of the parser by path under
# `scripts/` with their SHA-256, the host patch and the BUILD file. 6.12
# compiles each source on its own and takes the headers of `scripts/include`;
# 4.19 is one translation unit, `zconf.y` including the rest.
_KERNELS = {
    "4.19": struct(
        tag = "v4.19",
        files = {
            "kconfig/confdata.c": "dd3bce7105b0a8219ef81e8ca02edfb439ffe6c08f08d42693898964d5638e77",
            "kconfig/expr.c": "20e2589713ebc6d0aa6fc2ba7844df9fe6ad491ce209d744faac156075948ca1",
            "kconfig/expr.h": "6f2db72e7384b187a64625e0c9bf01868fc67265686f170bb99bdf9b0b61a9d7",
            "kconfig/kconf_id.c": "a8fbd8e3855c7c81f69b35e278ade8df12c8a80cde9c8941b6e7ab0ec0914f0a",
            "kconfig/list.h": "fc686618be614e481ef6bfdce9d33f97dde4e94682ec57af1138122c48a2df3b",
            "kconfig/lkc.h": "c81fd8b4b4a705309b5c314f87bca7958a335cc4b230f313edd47466e5d855bf",
            "kconfig/lkc_proto.h": "1fc7cdbcc9bd6e482b708b89355bb471a66ad96a3d14e7f9399c5aa03e4ed74d",
            "kconfig/menu.c": "6c3ae3c066e7932c99eb98d6b2da07531dd4279d0a134eccb4342c21cb118be7",
            "kconfig/preprocess.c": "83b39497c37efcb399622be3dc4493c09071fb502c04684164120ab01479025f",
            "kconfig/symbol.c": "6d1b9a3f176eb3b3d771e76f53372aefa676653ec8e441843da358d7ea70cf49",
            "kconfig/util.c": "d5340d4d939671852b6c0e012ac69aa052df387761f20d0ed2ceaa64d905d682",
            "kconfig/zconf.l": "62413ba0b6b5a0972993a277c6b7045bc5764dc0b7b3dbaf3849fcb1dc842e0d",
            "kconfig/zconf.y": "c8681edf42e4b600ddb3fd98431a776cdd5a49bd2c455d4e0ee7b82c03704be0",
        },
        patch = Label("//kconfig/private/parser/kernel:host_4.19.patch"),
        build_file = Label("//kconfig/private/parser/kernel:BUILD.linux_kconfig_legacy.bazel"),
    ),
    "6.12": struct(
        tag = "v6.12",
        files = {
            "include/array_size.h": "90ea8c7000afb1f9ad8504dcc24c1ddcd3c08239787248b617fc632ed3577ce4",
            "include/hash.h": "036b553056d9b4728a27658ecdd33e23cd5174bf07b8cbb79a4a91a66c7fda60",
            "include/hashtable.h": "3f3b31f8490d515f62c7a65b69145f39aeae4f3cf7963267f6d697ffd08aa377",
            "include/list.h": "962c98d2e9cb30f559e4e53a450bacf073cf16f7e250f09073c5a3a3fd4f4f69",
            "include/list_types.h": "36df90fe1e5b16bff75afbbe2b0018f21eaeca9fe67f95e054cf645f28071356",
            "include/xalloc.h": "c69a8c5116bd0aac41088990401ddcfaffc1b28fe7d649117b7452b8fb5af7fa",
            "kconfig/confdata.c": "f01e3de68d2850285243d7494ee3df6011a6d9f077b09a1a5fa4d12f820537c4",
            "kconfig/expr.c": "e1db484d6011e0855ddad833a00ca90ac445e284e8a9cd4608114c51b2f622a2",
            "kconfig/expr.h": "e271e4be3df369416bc002d08b2735af31ae7afa6553b21f8b840406ae92c310",
            "kconfig/internal.h": "cadb1a49e558de332aef828b9f3e315d5e2f75c4da61e0321655c3b8ecaa29ff",
            "kconfig/lexer.l": "6280524938851a0792b003fccd6e677f0bf83530d403d561e6469065bdc08e7a",
            "kconfig/lkc.h": "73df35430339b649563bc1d03d7bda5183f62352d8bf9d2318f5d243434ef27b",
            "kconfig/lkc_proto.h": "cdddc5302734086ee4dddfeb98d3a4759dfb00167aaa53ceac1f06b869c19397",
            "kconfig/menu.c": "306c13254ea55454c6b2205024012e86d69db714dd097787b8c860b606268420",
            "kconfig/parser.y": "c6b97276a318f31d8213306857091de4f09fcbd801aa0a12bd307fa9191a47bc",
            "kconfig/preprocess.c": "93c62d8634e3d30d71ae5092a6e49212c980837789693643f15434e74717104e",
            "kconfig/preprocess.h": "f7e9581e1d92804acadca02ffdbd298e681cb4d1fb1e04bacb59e0e2a7fe6f9b",
            "kconfig/symbol.c": "7cb233b6e41943d8a014c4cd6d40f405ae0c4c39fc86fb7532025b8efd9e4a8b",
            "kconfig/util.c": "8b9f8fe2c2abe57462c9bff27da9a50faaa6be1fea2d7eed59f5a7f989bcb38e",
        },
        patch = Label("//kconfig/private/parser/kernel:host_6.12.patch"),
        build_file = Label("//kconfig/private/parser/kernel:BUILD.linux_kconfig.bazel"),
    ),
}

def kernel_kconfig_repository_name(version):
    """The name of the repository holding the parser of a version.

    Args:
        version: One of `PARSER_VERSIONS`.

    Returns:
        str: `kernel_kconfig_6_12` for `6.12`.
    """
    return "kernel_kconfig_" + version_id(version)

def _kernel_kconfig_repository_impl(repository_ctx):
    version = repository_ctx.attr.version
    kernel = _KERNELS[version]
    for path, sha256 in kernel.files.items():
        output = path[len("kconfig/"):] if path.startswith("kconfig/") else path
        repository_ctx.download(
            url = _URL.format(tag = kernel.tag, path = path),
            output = output,
            sha256 = sha256,
        )
    repository_ctx.patch(kernel.patch, strip = 1)

    # mconf: its own files, and the parser's as released, under menuconfig/.
    # lxdialog includes <ncurses.h>, the name ncurses installs as an alias of
    # curses.h; the registry's ncurses provides curses.h alone.
    repository_ctx.file("menuconfig/ncurses.h", "#include <curses.h>\n")
    for path, sha256 in list(_MCONF[version].items()) + list(kernel.files.items()):
        output = path[len("kconfig/"):] if path.startswith("kconfig/") else path
        repository_ctx.download(
            url = _URL.format(tag = kernel.tag, path = path),
            output = "menuconfig/" + output,
            sha256 = sha256,
        )
    major, minor = version.split(".")
    repository_ctx.template(
        "BUILD.bazel",
        kernel.build_file,
        substitutions = {
            "{id}": version_id(version),
            "{major}": major,
            "{minor}": minor,
            "{tag}": kernel.tag,
            "{version}": version,
        },
    )
    repository_ctx.file("WORKSPACE.bazel", "workspace(name = \"{}\")\n".format(repository_ctx.name))
    if hasattr(repository_ctx, "repo_metadata"):
        return repository_ctx.repo_metadata(reproducible = True)
    return None

kernel_kconfig_repository = repository_rule(
    doc = "The Kconfig parser of one Linux release, fetched file by file by hash, with a BUILD file that compiles it for the parser builds.",
    implementation = _kernel_kconfig_repository_impl,
    attrs = {
        "version": attr.string(
            doc = "The kernel release, one of {}.".format(", ".join(PARSER_VERSIONS)),
            mandatory = True,
            values = PARSER_VERSIONS,
        ),
    },
)
