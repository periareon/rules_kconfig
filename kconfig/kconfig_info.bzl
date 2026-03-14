"""KConfigInfo"""

KConfigInfo = provider(
    doc = "Encapsulates a Kconfig source tree: an optional root file and all source files (direct and transitive).",
    fields = {
        "root": "Optional[File]: The top-level Kconfig file that kconfiglib should parse. May be None when a library contributes sources but is not itself a root.",
        "srcs": "depset[File]: All Kconfig source files (direct and transitive) reachable from this library.",
    },
)
