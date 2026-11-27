#include "kconfig/private/menuconfig/launcher.h"

#include <string>
#include <vector>

namespace rules_kconfig {
namespace menuconfig {

namespace {

/// Splits text into lines, without their line endings (`\n` or `\r\n`).
///
/// @param content The text.
/// @return The lines, in order; a trailing newline ends the last one.
std::vector<std::string> split_lines(const std::string& content) {
    std::vector<std::string> lines;
    std::string::size_type start = 0;
    while (start < content.size()) {
        std::string::size_type end = content.find('\n', start);
        if (end == std::string::npos) {
            end = content.size();
        }
        std::string line = content.substr(start, end - start);
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        lines.push_back(line);
        start = end + 1;
    }
    return lines;
}

/// Reads `NAME=VALUE`.
///
/// @param flag The flag the value belongs to, for the error.
/// @param value The value given.
/// @param assignment Receives the name and the value.
/// @param error Receives the complaint when there is no `=`.
/// @return Whether the value was an assignment.
bool parse_assignment(const std::string& flag, const std::string& value,
                      Assignment* assignment, std::string* error) {
    std::string::size_type equals = value.find('=');
    if (equals == std::string::npos) {
        *error = flag + " " + value + " is not NAME=VALUE";
        return false;
    }
    *assignment = {value.substr(0, equals), value.substr(equals + 1)};
    return true;
}

}  // namespace

bool parse_args(const std::string& content, Args* args, std::string* error) {
    std::vector<std::string> lines = split_lines(content);
    for (std::string::size_type i = 0; i < lines.size(); i++) {
        const std::string& flag = lines[i];
        if (flag.empty()) {
            continue;
        }
        if (i + 1 >= lines.size()) {
            *error = flag + " has no value";
            return false;
        }
        const std::string& value = lines[++i];
        Assignment assignment;
        if (flag == "--kconfig") {
            args->kconfig = value;
        } else if (flag == "--mconf") {
            args->mconf = value;
        } else if (flag == "--config") {
            args->config = value;
        } else if (flag == "--env") {
            if (!parse_assignment(flag, value, &assignment, error)) {
                return false;
            }
            args->env.push_back(assignment);
        } else if (flag == "--env-file") {
            if (!parse_assignment(flag, value, &assignment, error)) {
                return false;
            }
            args->env_files.push_back(assignment);
        } else {
            *error = "unknown argument " + flag;
            return false;
        }
    }
    if (args->kconfig.empty() || args->mconf.empty() || args->config.empty()) {
        *error = "--kconfig, --mconf and --config are required";
        return false;
    }
    return true;
}

bool is_within_workspace(const std::string& path) {
    if (path.empty()) {
        return false;
    }
    // Absolute on POSIX, or on Windows: a drive (`C:`) or a UNC path.
    if (path[0] == '/' || path[0] == '\\' ||
        (path.size() >= 2 && path[1] == ':')) {
        return false;
    }
    std::string::size_type start = 0;
    while (start <= path.size()) {
        std::string::size_type end = path.find_first_of("/\\", start);
        if (end == std::string::npos) {
            end = path.size();
        }
        if (path.compare(start, end - start, "..") == 0) {
            return false;
        }
        start = end + 1;
    }
    return true;
}

}  // namespace menuconfig
}  // namespace rules_kconfig
