/// @file
/// The launcher of the `menuconfig` rule, which `bazel run` runs as the
/// rule's executable under the target's name. It reads the arguments the
/// rule wrote to the file `RULES_KCONFIG_MENUCONFIG_ARGS_FILE` names (a
/// runfiles path; see launcher.h for the arguments), sets the environment
/// the kernel's `mconf` reads (`KCONFIG_CONFIG`, `srctree`, the tree's
/// variables) and runs it on the root Kconfig: in place on Unix, and as a
/// child whose exit code is returned on Windows, so that the rule behaves the
/// same on both. Everything is found through the runfiles and
/// `BUILD_WORKSPACE_DIRECTORY`; no path is absolute or resolved through
/// symlinks.

#include <sys/stat.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>

#ifdef _WIN32
#include <direct.h>
#include <process.h>
#else
#include <unistd.h>
#endif

#include "kconfig/private/menuconfig/launcher.h"
#include "rules_cc/cc/runfiles/runfiles.h"

namespace {

using rules_cc::cc::runfiles::Runfiles;
using rules_kconfig::menuconfig::Args;
using rules_kconfig::menuconfig::is_within_workspace;
using rules_kconfig::menuconfig::parse_args;

/// The environment variable naming the arguments file, set by the rule's
/// `RunEnvironmentInfo`.
const char ARGS_FILE_ENV[] = "RULES_KCONFIG_MENUCONFIG_ARGS_FILE";

/// Whether a path names a regular file.
bool is_file(const std::string& path) {
    struct stat info;
    return stat(path.c_str(), &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG;
}

/// Whether a path names anything.
bool exists(const std::string& path) {
    struct stat info;
    return stat(path.c_str(), &info) == 0;
}

/// The directory of a path, with either separator; `.` for a bare name.
std::string dirname(const std::string& path) {
    std::string::size_type slash = path.find_last_of("/\\");
    return slash == std::string::npos ? "." : path.substr(0, slash);
}

/// Looks a runfile up, which must exist.
///
/// @param runfiles The runfiles.
/// @param rlocationpath The runfiles path.
/// @param path Receives the file's path.
/// @param error Receives the complaint when the file is not there.
/// @return Whether the file was found.
bool runfile(const Runfiles& runfiles, const std::string& rlocationpath,
             std::string* path, std::string* error) {
    *path = runfiles.Rlocation(rlocationpath);
    if (path->empty()) {
        *error = rlocationpath + " is not in the runfiles";
        return false;
    }
    if (!exists(*path)) {
        *error = rlocationpath + " is not in the runfiles (" + *path +
                 " does not exist)";
        return false;
    }
    return true;
}

/// Sets an environment variable for the child.
void set_env(const std::string& name, const std::string& value) {
#ifdef _WIN32
    _putenv_s(name.c_str(), value.c_str());
#else
    setenv(name.c_str(), value.c_str(), 1);
#endif
}

/// Runs `mconf` on the root Kconfig, in the tree's directory.
///
/// @param mconf The path of `mconf`.
/// @param kconfig The path of the root Kconfig.
/// @param srctree The tree's directory, the working directory.
/// @param error Receives the complaint when `mconf` could not be started.
/// @return Only on Windows, `mconf`'s exit code; on Unix the process is
///     replaced, and a return is a failure to start.
int exec_mconf(const std::string& mconf, const std::string& kconfig,
               const std::string& srctree, std::string* error) {
#ifdef _WIN32
    if (_chdir(srctree.c_str()) != 0) {
        *error = "cannot enter " + srctree;
        return 1;
    }
    const char* argv[] = {mconf.c_str(), kconfig.c_str(), nullptr};
    intptr_t status = _spawnv(_P_WAIT, mconf.c_str(), argv);
    if (status < 0) {
        *error = "running " + mconf + " failed";
        return 1;
    }
    return static_cast<int>(status);
#else
    if (chdir(srctree.c_str()) != 0) {
        *error = "cannot enter " + srctree;
        return 1;
    }
    char* const argv[] = {const_cast<char*>(mconf.c_str()),
                          const_cast<char*>(kconfig.c_str()), nullptr};
    execv(mconf.c_str(), argv);
    *error = "running " + mconf + " failed: " + std::strerror(errno);
    return 1;
#endif
}

/// Runs `mconf` as the arguments file says.
///
/// @param argv0 The program's `argv[0]`, which locates the runfiles.
/// @param error Receives the complaint, on failure.
/// @return The exit status: `mconf`'s on Windows, or a failure's.
int run(const char* argv0, std::string* error) {
    const char* workspace = std::getenv("BUILD_WORKSPACE_DIRECTORY");
    if (workspace == nullptr || *workspace == '\0') {
        *error = "menuconfig must be run via `bazel run`";
        return 1;
    }
    std::unique_ptr<Runfiles> runfiles(
        Runfiles::Create(argv0, BAZEL_CURRENT_REPOSITORY, error));
    if (runfiles == nullptr) {
        *error = "failed to find the runfiles: " + *error;
        return 1;
    }
    const char* args_rlocationpath = std::getenv(ARGS_FILE_ENV);
    if (args_rlocationpath == nullptr || *args_rlocationpath == '\0') {
        *error = std::string(ARGS_FILE_ENV) +
                 " is not set; menuconfig must be run via `bazel run`";
        return 1;
    }
    std::string args_path;
    if (!runfile(*runfiles, args_rlocationpath, &args_path, error)) {
        return 1;
    }
    std::ifstream args_file(args_path.c_str());
    if (!args_file) {
        *error = "reading " + args_path + " failed";
        return 1;
    }
    std::stringstream content;
    content << args_file.rdbuf();
    Args args;
    if (!parse_args(content.str(), &args, error)) {
        *error = args_path + ": " + *error;
        return 1;
    }

    if (!is_within_workspace(args.config)) {
        *error =
            "the config file must be a relative path inside the root module's "
            "workspace, without `..`: " +
            args.config;
        return 1;
    }
    std::string config = std::string(workspace) + "/" + args.config;
    // An existing file only: the rule edits a file of the workspace, and a
    // path that names none is a mistake, not a file to create.
    if (!is_file(config)) {
        *error = "the config file does not exist: " + config +
                 "\n  menuconfig edits an existing file of the root module's "
                 "workspace";
        return 1;
    }

    // The tree is the library's files in the runfiles, the root's directory
    // among them; a tree's scripts are there when the library lists them.
    std::string kconfig;
    std::string mconf;
    if (!runfile(*runfiles, args.kconfig, &kconfig, error) ||
        !runfile(*runfiles, args.mconf, &mconf, error)) {
        return 1;
    }
    std::string srctree = dirname(kconfig);

    for (const auto& variable : args.env) {
        set_env(variable.first, variable.second);
    }
    for (const auto& variable : args.env_files) {
        std::string path;
        if (!runfile(*runfiles, variable.second, &path, error)) {
            return 1;
        }
        set_env(variable.first, path);
    }
    set_env("KCONFIG_CONFIG", config);
    // The tree's directory is `$(srctree)`, and the working directory, as
    // the repository rule runs the tree's commands: a command may name a
    // script relative to it.
    set_env("srctree", srctree);
    return exec_mconf(mconf, kconfig, srctree, error);
}

}  // namespace

int main(int argc, char** argv) {
    (void)argc;
    std::string error;
    int status = run(argv[0], &error);
    if (!error.empty()) {
        std::cerr << "menuconfig: " << error << std::endl;
    }
    return status;
}
