# rules_kconfig

Bazel rules for [Kconfig](https://www.kernel.org/doc/html/latest/kbuild/kconfig-language.html):
a Kconfig tree becomes a repository of build settings, `config_setting`s and
a `config.h`, parsed by the Linux kernel's own Kconfig parser.

```python
bazel_dep(name = "rules_kconfig", version = "...")

kconfig = use_extension("@rules_kconfig//kconfig:extensions.bzl", "kconfig")
kconfig.repo(
    name = "my_kconfig",
    kconfig = "//:Kconfig",
)
use_repo(kconfig, "my_kconfig")
```

## Documentation

<https://periareon.github.io/rules_kconfig/>
