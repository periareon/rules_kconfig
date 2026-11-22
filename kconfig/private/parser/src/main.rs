//! The parser as a native program: `kconfig_tool REQUEST RESPONSE` reads the
//! request from the first file and writes the response to the second, which
//! is how the repository rules run it (`repository_ctx.execute` has no
//! standard input, and its output is not byte-safe); without arguments it
//! reads standard input and writes standard output, for the tests. The
//! parser parses one tree per process, so each round is a run.

use std::io::{Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
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
        _ => Err("usage: kconfig_tool [REQUEST RESPONSE]".to_string()),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("kconfig_tool: {}", message);
            ExitCode::FAILURE
        }
    }
}
