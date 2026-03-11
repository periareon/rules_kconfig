"""kconfiglib repository info"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(":kconfiglib_version.bzl", "VERSION_INFO")

_BUILD_FILE_TEMPLATE = """\
VERSION = "{version}"
"""

def kconfiglib_repository(*, name):
    http_archive(
        name = name,
        urls = VERSION_INFO["urls"],
        integrity = VERSION_INFO["integrity"],
        strip_prefix = VERSION_INFO["strip_prefix"],
        type = "zip",
        build_file_content = _BUILD_FILE_TEMPLATE.format(
            version = VERSION_INFO["version"],
        ),
    )
