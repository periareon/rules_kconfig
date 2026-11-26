//! The parser as a native program: `kconfig_tool REQUEST RESPONSE` reads the
//! request from the first file and writes the response to the second, which
//! is how the repository rules run it (`repository_ctx.execute` has no
//! standard input, and its output is not byte-safe); without arguments it
//! reads standard input and writes standard output, for the tests. The
//! parser parses one tree per process, so each round is a run.
//!
//! Run by the `menuconfig` rule, the program is the rule's launcher instead
//! (see menuconfig.rs): `bazel run` starts it without arguments, so it is
//! told apart by `RULES_KCONFIG_MENUCONFIG_ARGS_FILE` in the environment,
//! which the rule sets; `kconfig_tool menuconfig` asks for the same by hand.
//! The native build is what a release ships for every platform, so the rule
//! runs it without a toolchain of its own.
#![forbid(unsafe_code)]

mod menuconfig;

use std::io::{Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
    let launcher = match args.as_slice() {
        [] => std::env::var_os(menuconfig::ARGS_FILE_ENV).is_some(),
        [arg] => arg == "menuconfig",
        _ => false,
    };
    if launcher {
        return match menuconfig::run() {
            Ok(code) => code,
            Err(message) => {
                eprintln!("kconfig_tool menuconfig: {}", message);
                ExitCode::FAILURE
            }
        };
    }
    let result = match args.as_slice() {
        [] => {
            let mut payload = Vec::new();
            std::io::stdin()
                .read_to_end(&mut payload)
                .map_err(|e| format!("reading the request: {}", e))
                .and_then(|_| {
                    std::io::stdout()
                        .write_all(&kconfig::entry::run(&payload))
                        .map_err(|e| format!("writing the response: {}", e))
                })
        }
        [request, response] => std::fs::read(request)
            .map_err(|e| format!("reading {}: {}", request.to_string_lossy(), e))
            .and_then(|payload| {
                std::fs::write(response, kconfig::entry::run(&payload))
                    .map_err(|e| format!("writing {}: {}", response.to_string_lossy(), e))
            }),
        _ => Err("usage: kconfig_tool [REQUEST RESPONSE | menuconfig]".to_string()),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("kconfig_tool: {}", message);
            ExitCode::FAILURE
        }
    }
}
