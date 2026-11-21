//! POSIX paths as bytes, with the operations of `os.path` and `pathlib` the
//! Python backend used.
//!
//! Paths follow POSIX rules whatever the host: the module has no filesystem,
//! and a Windows drive path (`C:/...`) is handled by giving it a leading
//! slash on the way in, `/C:/...`, and taking it off again on the way out,
//! as entry.py did for its POSIX interpreter.

/// Whether `path` starts with a drive, `X:/`.
fn has_drive(path: &[u8]) -> bool {
    path.len() >= 3 && path[0].is_ascii_alphabetic() && path[1] == b':' && path[2] == b'/'
}

/// A host path in the module's form.
pub fn internal(host_path: &[u8]) -> Vec<u8> {
    if has_drive(host_path) {
        let mut path = Vec::with_capacity(host_path.len() + 1);
        path.push(b'/');
        path.extend_from_slice(host_path);
        return path;
    }
    host_path.to_vec()
}

/// The host's form of a path `internal` produced.
pub fn host(internal_path: &[u8]) -> Vec<u8> {
    if internal_path.first() == Some(&b'/') && has_drive(&internal_path[1..]) {
        return internal_path[1..].to_vec();
    }
    internal_path.to_vec()
}

pub fn is_absolute(path: &[u8]) -> bool {
    path.first() == Some(&b'/')
}

/// `os.path.split(path)`: the head, without its trailing slashes unless it
/// is all slashes, and the tail.
pub fn split(path: &[u8]) -> (&[u8], &[u8]) {
    let i = path.iter().rposition(|&b| b == b'/').map_or(0, |i| i + 1);
    let (head, tail) = path.split_at(i);
    let mut end = head.len();
    while end > 0 && head[end - 1] == b'/' {
        end -= 1;
    }
    let head = if end == 0 { head } else { &head[..end] };
    (head, tail)
}

/// `os.path.join(a, b)`.
pub fn join(a: &[u8], b: &[u8]) -> Vec<u8> {
    if is_absolute(b) || a.is_empty() {
        return b.to_vec();
    }
    let mut path = a.to_vec();
    if !path.ends_with(b"/") {
        path.push(b'/');
    }
    path.extend_from_slice(b);
    path
}

/// The components of a path as `pathlib.PurePosixPath` keeps them: the root,
/// and the names with `.` and empty ones dropped.
fn components(path: &[u8]) -> (&'static [u8], Vec<&[u8]>) {
    let root: &'static [u8] = if path.starts_with(b"//") && !path.starts_with(b"///") {
        b"//"
    } else if path.starts_with(b"/") {
        b"/"
    } else {
        b""
    };
    let names = path
        .split(|&b| b == b'/')
        .filter(|name| !name.is_empty() && *name != b".")
        .collect();
    (root, names)
}

fn assemble(root: &[u8], names: &[&[u8]]) -> Vec<u8> {
    let mut path = root.to_vec();
    for (i, name) in names.iter().enumerate() {
        if i > 0 {
            path.push(b'/');
        }
        path.extend_from_slice(name);
    }
    if path.is_empty() {
        path.push(b'.');
    }
    path
}

/// `str(PurePosixPath(path))`.
pub fn normalize(path: &[u8]) -> Vec<u8> {
    let (root, names) = components(path);
    assemble(root, &names)
}

/// `str(Path(path).absolute())`. The module has no working directory, so a
/// relative path is taken from the root, as its POSIX interpreter would.
pub fn absolute(path: &[u8]) -> Vec<u8> {
    let normalized = normalize(path);
    if is_absolute(&normalized) {
        return normalized;
    }
    if normalized == b"." {
        return b"/".to_vec();
    }
    let mut absolute = b"/".to_vec();
    absolute.extend_from_slice(&normalized);
    absolute
}

/// `str(PurePosixPath(path).parent)`.
pub fn parent(path: &[u8]) -> Vec<u8> {
    let (root, mut names) = components(path);
    if names.pop().is_none() {
        return assemble(root, &names);
    }
    assemble(root, &names)
}

/// `str(PurePosixPath(path).relative_to(base))`, or the error's message.
pub fn relative_to(path: &[u8], base: &[u8]) -> Result<Vec<u8>, String> {
    let (root, names) = components(path);
    let (base_root, base_names) = components(base);
    if root != base_root || !names.starts_with(&base_names) {
        return Err(format!(
            "'{}' is not in the subpath of '{}'",
            String::from_utf8_lossy(path),
            String::from_utf8_lossy(base)
        ));
    }
    Ok(assemble(b"", &names[base_names.len()..]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits() {
        assert_eq!(split(b"/a/b"), (&b"/a"[..], &b"b"[..]));
        assert_eq!(split(b"/a"), (&b"/"[..], &b"a"[..]));
        assert_eq!(split(b"a"), (&b""[..], &b"a"[..]));
        assert_eq!(split(b"/a/b/"), (&b"/a/b"[..], &b""[..]));
    }

    #[test]
    fn normalizes() {
        assert_eq!(normalize(b"/a//b/./c/"), b"/a/b/c".to_vec());
        assert_eq!(normalize(b"./x"), b"x".to_vec());
        assert_eq!(normalize(b""), b".".to_vec());
        assert_eq!(parent(b"/a/b"), b"/a".to_vec());
        assert_eq!(parent(b"/"), b"/".to_vec());
        assert_eq!(parent(b"a"), b".".to_vec());
        assert_eq!(
            relative_to(b"/t/x/Kconfig", b"/t/x/").unwrap(),
            b"Kconfig".to_vec()
        );
        assert!(relative_to(b"/t/y/Kconfig", b"/t/x").is_err());
    }

    #[test]
    fn drives() {
        assert_eq!(internal(b"C:/tree"), b"/C:/tree".to_vec());
        assert_eq!(host(b"/C:/tree/Kconfig"), b"C:/tree/Kconfig".to_vec());
        assert_eq!(host(b"/tmp/x"), b"/tmp/x".to_vec());
    }
}
