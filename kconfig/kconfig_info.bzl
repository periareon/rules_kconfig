"""KConfigInfo"""

KConfigInfo = provider(
    doc = "A Kconfig source tree: its root file, every source file (direct and transitive), the release it is written for and the variables it reads.",
    fields = {
        "env": "dict[str, str]: The environment variables the tree's Kconfig files read (`$(NAME)`, `option env`), by name.",
        "env_files": "dict[str, File]: Variables whose value is a file's path (a compiler the tree's `$(shell,...)` runs), by name.",
        "kconfig_version": "str: The kernel release the tree is written for (`kconfig_version` of `kconfig_library`); empty for the default.",
        "root": "Optional[File]: The top-level Kconfig file that the parser reads. May be None when a library contributes sources but is not itself a root.",
        "srcs": "depset[File]: All Kconfig source files (direct and transitive) reachable from this library.",
    },
)
