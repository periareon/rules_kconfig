/// @file
/// Tests of what the launcher checks without a process: the arguments file
/// and the containment of `config`.
#include "kconfig/private/menuconfig/launcher.h"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

using rules_kconfig::menuconfig::Args;
using rules_kconfig::menuconfig::is_within_workspace;
using rules_kconfig::menuconfig::parse_args;

/// How many expectations failed so far.
int failures = 0;

/// Records a failed expectation with its location, and goes on.
#define EXPECT(condition)                                             \
    do {                                                              \
        if (!(condition)) {                                           \
            std::cerr << __FILE__ << ":" << __LINE__ << ": expected " \
                      << #condition << std::endl;                     \
            failures++;                                               \
        }                                                             \
    } while (0)

/// Whether the arguments file is rejected, with a complaint.
bool rejects(const std::string& content) {
    Args args;
    std::string error;
    return !parse_args(content, &args, &error) && !error.empty();
}

void parses_the_arguments_file() {
    Args args;
    std::string error;
    EXPECT(parse_args(
        "--kconfig\n_main/Kconfig\n--mconf\nk/mconf\n--config\n.config\n"
        "--env\nARCH=arm64\n--env-file\nCC=t/gcc\n",
        &args, &error));
    EXPECT(error.empty());
    EXPECT(args.kconfig == "_main/Kconfig");
    EXPECT(args.mconf == "k/mconf");
    EXPECT(args.config == ".config");
    EXPECT(args.env.size() == 1 && args.env[0].first == "ARCH" &&
           args.env[0].second == "arm64");
    EXPECT(args.env_files.size() == 1 && args.env_files[0].first == "CC" &&
           args.env_files[0].second == "t/gcc");
}

void rejects_what_it_does_not_know() {
    EXPECT(rejects("--kconfig\nK\n--mconf\nM\n--config\nc\n--what\nx\n"));
    EXPECT(rejects("--kconfig\nK\n--mconf\nM\n"));
    EXPECT(rejects("--kconfig\nK\n--mconf\nM\n--config\nc\n--env\nNOEQUALS\n"));
    EXPECT(rejects("--kconfig\n"));
}

void a_config_stays_in_the_workspace_lexically() {
    EXPECT(is_within_workspace(".config"));
    EXPECT(is_within_workspace("configs/./dev.config"));
    EXPECT(!is_within_workspace("../outside.config"));
    EXPECT(!is_within_workspace("configs/../../outside.config"));
    EXPECT(!is_within_workspace("/etc/config"));
    EXPECT(!is_within_workspace("C:/config"));
    EXPECT(!is_within_workspace("\\\\server\\share\\config"));
    EXPECT(!is_within_workspace(""));
}

}  // namespace

int main() {
    parses_the_arguments_file();
    rejects_what_it_does_not_know();
    a_config_stays_in_the_workspace_lexically();
    if (failures != 0) {
        std::cerr << failures << " failed" << std::endl;
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
