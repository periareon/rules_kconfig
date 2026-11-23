//! Publishes a release asset: copies the file it was given into a directory.
//!
//! The `release_artifact` rule of defs.bzl names the asset through the
//! environment: `RULES_KCONFIG_RELEASE_ARTIFACT` is its runfiles path and
//! `RULES_KCONFIG_RELEASE_EXECUTABLE` is `1` for a program. The one argument
//! is the destination directory, by default the one `bazel run` was invoked
//! from (`BUILD_WORKING_DIRECTORY`); a relative one is taken from there. The
//! asset keeps its name, and the path it was published at is printed.

use std::env;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use runfiles::{Runfiles, rlocation};

const ARTIFACT: &str = "RULES_KCONFIG_RELEASE_ARTIFACT";
const EXECUTABLE: &str = "RULES_KCONFIG_RELEASE_EXECUTABLE";

fn run() -> Result<PathBuf, String> {
    let artifact = env::var(ARTIFACT).map_err(|_| {
        format!("{ARTIFACT} is not set; run this through a release_artifact target")
    })?;
    let executable = env::var(EXECUTABLE).is_ok_and(|value| value == "1");
    let name = Path::new(&artifact)
        .file_name()
        .ok_or_else(|| format!("{ARTIFACT}={artifact} has no file name"))?
        .to_owned();

    let runfiles =
        Runfiles::create().map_err(|error| format!("failed to find the runfiles: {error}"))?;
    let source = rlocation!(runfiles, &artifact)
        .ok_or_else(|| format!("{artifact} is not in the runfiles"))?;

    let invoked_from = env::var_os("BUILD_WORKING_DIRECTORY")
        .map(PathBuf::from)
        .or_else(|| env::current_dir().ok())
        .ok_or_else(|| "neither BUILD_WORKING_DIRECTORY nor a current directory".to_string())?;
    let mut args = env::args_os().skip(1);
    let destination = match (args.next(), args.next()) {
        (None, _) => invoked_from,
        // `join` replaces the base when given an absolute path.
        (Some(directory), None) => invoked_from.join(directory),
        (Some(_), Some(_)) => return Err("usage: [destination directory]".to_string()),
    };
    fs::create_dir_all(&destination)
        .map_err(|error| format!("failed to create {}: {error}", destination.display()))?;

    let published = destination.join(name);
    match fs::remove_file(&published) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => {
            return Err(format!(
                "failed to replace {}: {error}",
                published.display()
            ));
        }
    }
    fs::copy(&source, &published).map_err(|error| {
        format!(
            "failed to copy {} to {}: {error}",
            source.display(),
            published.display()
        )
    })?;
    set_permissions(&published, executable).map_err(|error| {
        format!(
            "failed to set the permissions of {}: {error}",
            published.display()
        )
    })?;
    Ok(published)
}

/// A program is `0755` and anything else `0644`: Bazel's outputs are read-only
/// and `copy` keeps that, which is not how a release asset should land.
#[cfg(unix)]
fn set_permissions(path: &Path, executable: bool) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mode = if executable { 0o755 } else { 0o644 };
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

/// Windows has only the read-only attribute, which `copy` carries over.
#[cfg(not(unix))]
fn set_permissions(path: &Path, _executable: bool) -> std::io::Result<()> {
    let mut permissions = fs::metadata(path)?.permissions();
    #[allow(clippy::permissions_set_readonly_false)]
    permissions.set_readonly(false);
    fs::set_permissions(path, permissions)
}

fn main() -> ExitCode {
    match run() {
        Ok(published) => {
            println!("{}", published.display());
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("error: {message}");
            ExitCode::FAILURE
        }
    }
}
