/// @file
/// The launcher of the `menuconfig` rule: what it checks without a process.
/// See main.cc for the program.
#ifndef RULES_KCONFIG_KCONFIG_PRIVATE_MENUCONFIG_LAUNCHER_H_
#define RULES_KCONFIG_KCONFIG_PRIVATE_MENUCONFIG_LAUNCHER_H_

#include <string>
#include <utility>
#include <vector>

namespace rules_kconfig {
namespace menuconfig {

/// A variable and its value, as `--env NAME=VALUE` gives them.
using Assignment = std::pair<std::string, std::string>;

/// The arguments file, one argument per line, as `ctx.actions.args()` writes
/// it:
///
/// ```text
/// --kconfig RLOCATIONPATH        the root Kconfig; its directory is $(srctree)
/// --mconf RLOCATIONPATH          the mconf to run
/// --config PATH                  the .config, relative to the workspace root
/// --env NAME=VALUE               a variable the Kconfig files read
/// --env-file NAME=RLOCATIONPATH  a variable whose value is the file's path
/// ```
struct Args {
    /// The runfiles path of the root Kconfig file.
    std::string kconfig;
    /// The runfiles path of the `mconf` to run.
    std::string mconf;
    /// The `.config`, relative to the root module's workspace.
    std::string config;
    /// The variables the Kconfig files read, by value.
    std::vector<Assignment> env;
    /// The variables whose value is a runfile's path, by runfiles path.
    std::vector<Assignment> env_files;
};

/// Parses the arguments file.
///
/// @param content The file's content.
/// @param args Receives the arguments; `kconfig`, `mconf` and `config` are
///     required.
/// @param error Receives what is wrong with the file, on failure.
/// @return Whether the file parsed.
bool parse_args(const std::string& content, Args* args, std::string* error);

/// Whether a workspace-relative path stays inside the workspace, lexically:
/// relative, and without `..`. Nothing is resolved through symlinks.
///
/// @param path The path, as the rule's `config` attribute gives it.
/// @return Whether the path can only name a file of the workspace.
bool is_within_workspace(const std::string& path);

}  // namespace menuconfig
}  // namespace rules_kconfig

#endif  // RULES_KCONFIG_KCONFIG_PRIVATE_MENUCONFIG_LAUNCHER_H_
