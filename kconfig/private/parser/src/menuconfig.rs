//! The launcher of the `menuconfig` rule, which `bazel run` runs as the
//! rule's executable (`kconfig_tool` under the target's name, without
//! arguments; `RULES_KCONFIG_MENUCONFIG_ARGS_FILE` in the environment tells
//! it so). It reads the arguments the rule wrote to the file that variable
//! names (a runfiles path), sets the environment the kernel's `mconf` reads
//! (`KCONFIG_CONFIG`, `srctree`, the tree's variables) and runs it on the
//! root Kconfig, in place on Unix and as a child whose exit code is
//! returned on Windows, so that the rule behaves the same on both.
//!
//! The arguments, one per line, as `ctx.actions.args()` writes them:
//!
//! ```text
//! --kconfig RLOCATIONPATH        the root Kconfig file; its directory is $(srctree)
//! --mconf RLOCATIONPATH          the mconf to run
//! --config PATH                  the .config, relative to the workspace root; must exist
//! --env NAME=VALUE               a variable the Kconfig files read
//! --env-file NAME=RLOCATIONPATH  a variable whose value is the file's path
//! ```

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use runfiles::{Runfiles, rlocation};

/// The environment variable naming the arguments file, set by the rule's
/// `RunEnvironmentInfo`.
pub const ARGS_FILE_ENV: &str = "RULES_KCONFIG_MENUCONFIG_ARGS_FILE";

#[derive(Default)]
struct Args {
    kconfig: String,
    mconf: String,
    config: String,
    env: Vec<(String, String)>,
    env_files: Vec<(String, String)>,
}

fn parse(content: &str) -> Result<Args, String> {
    let mut args = Args::default();
    let mut lines = content.lines();
    while let Some(flag) = lines.next() {
        if flag.is_empty() {
            continue;
        }
        let value = lines
            .next()
            .ok_or_else(|| format!("{flag} has no value"))?
            .to_string();
        let assignment = || {
            value
                .split_once('=')
                .map(|(name, value)| (name.to_string(), value.to_string()))
                .ok_or_else(|| format!("{flag} {value} is not NAME=VALUE"))
        };
        match flag {
            "--kconfig" => args.kconfig = value,
            "--mconf" => args.mconf = value,
            "--config" => args.config = value,
            "--env" => args.env.push(assignment()?),
            "--env-file" => args.env_files.push(assignment()?),
            _ => return Err(format!("unknown argument {flag}")),
        }
    }
    if args.kconfig.is_empty() || args.mconf.is_empty() || args.config.is_empty() {
        return Err("--kconfig, --mconf and --config are required".to_string());
    }
    Ok(args)
}

fn runfile(runfiles: &Runfiles, rlocationpath: &str) -> Result<PathBuf, String> {
    let path = rlocation!(runfiles, rlocationpath)
        .ok_or_else(|| format!("{rlocationpath} is not in the runfiles"))?;
    if !path.exists() {
        return Err(format!(
            "{rlocationpath} is not in the runfiles ({} does not exist)",
            path.display()
        ));
    }
    Ok(path)
}

/// A path without the `\\?\` prefix `canonicalize` gives on Windows, which
/// the C runtime `mconf` opens files with does not take.
#[cfg(windows)]
fn plain(path: PathBuf) -> PathBuf {
    let text = path.to_string_lossy();
    match text.strip_prefix(r"\\?\") {
        Some(rest) if !rest.starts_with("UNC\\") => PathBuf::from(rest),
        _ => path,
    }
}

#[cfg(not(windows))]
fn plain(path: PathBuf) -> PathBuf {
    path
}

/// The path with symlinks resolved, like Python's `os.path.realpath`: the
/// longest prefix that exists is canonicalized and the rest appended, so
/// that a `.config` that is yet to be written resolves too.
fn realpath(path: &Path) -> PathBuf {
    let mut existing = path.to_path_buf();
    let mut rest: Vec<OsString> = Vec::new();
    loop {
        if let Ok(real) = std::fs::canonicalize(&existing) {
            let mut out = real;
            for component in rest.iter().rev() {
                out.push(component);
            }
            return plain(out);
        }
        match (existing.file_name(), existing.parent()) {
            (Some(name), Some(parent)) => {
                rest.push(name.to_os_string());
                existing = parent.to_path_buf();
            }
            _ => return path.to_path_buf(),
        }
    }
}

#[cfg(unix)]
fn exec(mut command: Command) -> Result<ExitCode, String> {
    use std::os::unix::process::CommandExt;
    let error = command.exec();
    Err(format!("running {:?}: {error}", command.get_program()))
}

#[cfg(not(unix))]
fn exec(mut command: Command) -> Result<ExitCode, String> {
    let status = command
        .status()
        .map_err(|error| format!("running {:?}: {error}", command.get_program()))?;
    Ok(match status.code() {
        Some(0) => ExitCode::SUCCESS,
        Some(code) => ExitCode::from(u8::try_from(code).unwrap_or(1)),
        None => ExitCode::FAILURE,
    })
}

/// Run `mconf` as the arguments file says. Returns only on Windows, with
/// `mconf`'s exit code, or with an error.
pub fn run() -> Result<ExitCode, String> {
    let workspace = std::env::var_os("BUILD_WORKSPACE_DIRECTORY")
        .map(PathBuf::from)
        .ok_or("menuconfig must be run via `bazel run`")?;
    let runfiles =
        Runfiles::create().map_err(|error| format!("failed to find the runfiles: {error}"))?;
    let args_file = std::env::var(ARGS_FILE_ENV).map_err(|_| {
        format!("{ARGS_FILE_ENV} is not set; menuconfig must be run via `bazel run`")
    })?;
    let args_file = runfile(&runfiles, &args_file)?;
    let content = std::fs::read_to_string(&args_file)
        .map_err(|error| format!("reading {}: {error}", args_file.display()))?;
    let args = parse(&content).map_err(|error| format!("{}: {error}", args_file.display()))?;

    let config = realpath(&workspace.join(&args.config));
    let real_workspace = realpath(&workspace);
    if !config.starts_with(&real_workspace) {
        return Err(format!(
            "the config file must be within the root module's workspace directory.\n  config resolves to: {}\n  workspace root:     {}",
            config.display(),
            real_workspace.display()
        ));
    }
    // An existing file only: the rule edits a file of the workspace, and a
    // path that names none is a mistake, not a file to create.
    if !config.is_file() {
        return Err(format!(
            "the config file does not exist: {}\n  menuconfig edits an existing file of the root module's workspace",
            config.display()
        ));
    }

    let kconfig = runfile(&runfiles, &args.kconfig)?;
    let mconf = runfile(&runfiles, &args.mconf)?;
    let mut command = Command::new(&mconf);
    command.arg(&kconfig);
    for (name, value) in &args.env {
        command.env(name, value);
    }
    for (name, rlocationpath) in &args.env_files {
        command.env(name, runfile(&runfiles, rlocationpath)?);
    }
    command.env("KCONFIG_CONFIG", &config);
    // The directory of the root Kconfig, in the runfiles tree, where the
    // library's files are: what `source` and `$(shell,...)` run against.
    let srctree = kconfig
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| format!("{} has no directory", kconfig.display()))?;
    command.env("srctree", srctree);
    exec(command)
}

#[cfg(test)]
mod tests {
    use super::parse;

    #[test]
    fn parses_the_arguments_file() {
        let args = parse(
            "--kconfig\n_main/Kconfig\n--mconf\nk/mconf\n--config\n.config\n--env\nARCH=arm64\n--env-file\nCC=t/gcc\n",
        )
        .unwrap();
        assert_eq!(args.kconfig, "_main/Kconfig");
        assert_eq!(args.mconf, "k/mconf");
        assert_eq!(args.config, ".config");
        assert_eq!(args.env, vec![("ARCH".to_string(), "arm64".to_string())]);
        assert_eq!(
            args.env_files,
            vec![("CC".to_string(), "t/gcc".to_string())]
        );
    }

    #[test]
    fn rejects_what_it_does_not_know() {
        assert!(parse("--kconfig\nK\n--mconf\nM\n--what\nx\n").is_err());
        assert!(parse("--kconfig\nK\n--mconf\nM\n").is_err());
        assert!(parse("--kconfig\nK\n--mconf\nM\n--env\nNOEQUALS\n").is_err());
    }
}
