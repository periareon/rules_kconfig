"""kconfiglib repository info"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(":kconfiglib_version.bzl", "VERSION_INFO")

_BUILD_FILE_TEMPLATE = """\
load("@rules_venv//python:py_library.bzl", "py_library")

VERSION = "{version}"

exports_files(["menuconfig.py", "kconfiglib.py"])

py_library(
    name = "kconfiglib",
    srcs = ["kconfiglib.py", "menuconfig.py"],
    visibility = ["//visibility:public"],
)
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
