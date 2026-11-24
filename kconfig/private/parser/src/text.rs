//! Byte-string operations with the semantics of Python's `str` methods, so
//! that the generators scan sources as the Python backend scanned them.

/// The line boundaries of `str.splitlines`, as UTF-8.
const LINE_BOUNDARIES: &[&[u8]] = &[
    b"\r\n",
    b"\n",
    b"\r",
    b"\x0b",
    b"\x0c",
    b"\x1c",
    b"\x1d",
    b"\x1e",
    b"\xc2\x85",
    b"\xe2\x80\xa8",
    b"\xe2\x80\xa9",
];

/// The characters `str.split()` and `str.strip()` treat as whitespace, as
/// UTF-8.
const WHITESPACE: &[&[u8]] = &[
    b" ",
    b"\t",
    b"\n",
    b"\r",
    b"\x0b",
    b"\x0c",
    b"\x1c",
    b"\x1d",
    b"\x1e",
    b"\x1f",
    b"\xc2\x85",
    b"\xc2\xa0",
    b"\xe1\x9a\x80",
    b"\xe2\x80\x80",
    b"\xe2\x80\x81",
    b"\xe2\x80\x82",
    b"\xe2\x80\x83",
    b"\xe2\x80\x84",
    b"\xe2\x80\x85",
    b"\xe2\x80\x86",
    b"\xe2\x80\x87",
    b"\xe2\x80\x88",
    b"\xe2\x80\x89",
    b"\xe2\x80\x8a",
    b"\xe2\x80\xa8",
    b"\xe2\x80\xa9",
    b"\xe2\x80\xaf",
    b"\xe2\x81\x9f",
    b"\xe3\x80\x80",
];

fn starts_with_any<'a>(text: &[u8], table: &[&'a [u8]]) -> Option<&'a [u8]> {
    table.iter().copied().find(|item| text.starts_with(item))
}

/// The entries of `WHITESPACE` and `LINE_BOUNDARIES` that are one ASCII
/// byte, as a set; the rest begin with a byte in `NON_ASCII_LEADS`. Most
/// bytes are neither, and settle in one lookup instead of a walk of the
/// table; the sources are scanned byte by byte, which under the interpreter
/// Bazel runs the module with made the walk the cost of the scan.
const fn byte_set(entries: &[&[u8]]) -> [bool; 128] {
    let mut set = [false; 128];
    let mut i = 0;
    while i < entries.len() {
        if entries[i].len() == 1 {
            set[entries[i][0] as usize] = true;
        }
        i += 1;
    }
    set
}

const ASCII_WHITESPACE: [bool; 128] = byte_set(WHITESPACE);
const ASCII_LINE_BOUNDARIES: [bool; 128] = byte_set(LINE_BOUNDARIES);
const NON_ASCII_LEADS: &[u8] = &[0xc2, 0xe1, 0xe2, 0xe3];

/// The whitespace `text` starts with, as `starts_with_any(text, WHITESPACE)`.
fn whitespace_prefix(text: &[u8]) -> Option<&'static [u8]> {
    match text.first() {
        None => None,
        Some(&b) if b < 0x80 && !ASCII_WHITESPACE[b as usize] => None,
        Some(&b) if b >= 0x80 && !NON_ASCII_LEADS.contains(&b) => None,
        _ => starts_with_any(text, WHITESPACE),
    }
}

/// The line boundary `text` starts with, as `starts_with_any(text, LINE_BOUNDARIES)`.
fn line_boundary_prefix(text: &[u8]) -> Option<&'static [u8]> {
    match text.first() {
        None => None,
        Some(&b) if b < 0x80 && !ASCII_LINE_BOUNDARIES[b as usize] => None,
        Some(&b) if b >= 0x80 && !NON_ASCII_LEADS.contains(&b) => None,
        _ => starts_with_any(text, LINE_BOUNDARIES),
    }
}

/// `text.splitlines()`.
pub fn splitlines(text: &[u8]) -> Vec<&[u8]> {
    let mut lines = Vec::new();
    let mut start = 0;
    let mut i = 0;
    while i < text.len() {
        if let Some(boundary) = line_boundary_prefix(&text[i..]) {
            lines.push(&text[start..i]);
            i += boundary.len();
            start = i;
        } else {
            i += 1;
        }
    }
    if start < text.len() {
        lines.push(&text[start..]);
    }
    lines
}

/// `text.lstrip()`.
pub fn lstrip(text: &[u8]) -> &[u8] {
    let mut i = 0;
    while i < text.len() {
        match whitespace_prefix(&text[i..]) {
            Some(space) => i += space.len(),
            None => break,
        }
    }
    &text[i..]
}

/// `text.split()`: the whitespace-separated words.
pub fn split_words(text: &[u8]) -> Vec<&[u8]> {
    let mut words = Vec::new();
    let mut rest = lstrip(text);
    while !rest.is_empty() {
        let mut end = 0;
        while end < rest.len() && whitespace_prefix(&rest[end..]).is_none() {
            end += 1;
        }
        words.push(&rest[..end]);
        rest = lstrip(&rest[end..]);
    }
    words
}

/// The first word of `text.split()`; empty where there is none.
pub fn first_word(text: &[u8]) -> &[u8] {
    let rest = lstrip(text);
    let mut end = 0;
    while end < rest.len() && whitespace_prefix(&rest[end..]).is_none() {
        end += 1;
    }
    &rest[..end]
}

/// `text.rstrip("\n")`.
pub fn rstrip_newlines(text: &[u8]) -> &[u8] {
    let mut end = text.len();
    while end > 0 && text[end - 1] == b'\n' {
        end -= 1;
    }
    &text[..end]
}

/// Whether `text` is `[A-Za-z0-9_-]+`.
pub fn is_word(text: &[u8]) -> bool {
    !text.is_empty()
        && text
            .iter()
            .all(|&b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn is_name_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b == b'-'
}

/// The names of the macro calls and variable references in `text`, `$(NAME`,
/// in order: the matches of `\$\(\s*([A-Za-z0-9_-]+)`.
///
/// Hand-written rather than a regex crate: those keep capture names in a
/// `HashMap`, which on wasip1 asks the host for random keys, and the module
/// may import nothing.
pub fn macro_references(text: &[u8]) -> Vec<Vec<u8>> {
    let mut names = Vec::new();
    let mut i = 0;
    while i + 1 < text.len() {
        if text[i] == b'$' && text[i + 1] == b'(' {
            let mut start = i + 2;
            while let Some(space) = whitespace_prefix(&text[start..]) {
                start += space.len();
            }
            let mut end = start;
            while end < text.len() && is_name_byte(text[end]) {
                end += 1;
            }
            if end > start {
                names.push(text[start..end].to_vec());
                i = end;
                continue;
            }
        }
        i += 1;
    }
    names
}

/// A preprocessor variable assignment, `NAME = value`, `NAME := value` or
/// `NAME += value`, at the start of a line: the name, and the names its value
/// refers to, as the groups of `^\s*([A-Za-z0-9_-]+)\s*(?::=|\+=|=)(.*)$`.
pub fn variable_assignment(line: &[u8]) -> Option<(Vec<u8>, Vec<Vec<u8>>)> {
    let rest = lstrip(line);
    let end = rest
        .iter()
        .position(|&b| !is_name_byte(b))
        .unwrap_or(rest.len());
    if end == 0 {
        return None;
    }
    let name = rest[..end].to_vec();
    let after = lstrip(&rest[end..]);
    let value = if after.starts_with(b":=") || after.starts_with(b"+=") {
        &after[2..]
    } else if after.starts_with(b"=") {
        &after[1..]
    } else {
        return None;
    };
    Some((name, macro_references(value)))
}

/// `int(text)`, as a canonical decimal string; None where Python raises.
pub fn python_int(text: &[u8]) -> Option<String> {
    let trimmed = lstrip(text);
    let mut end = trimmed.len();
    while end > 0 && starts_with_any(&trimmed[end - 1..], WHITESPACE).is_some() {
        end -= 1;
    }
    let trimmed = &trimmed[..end];
    let (negative, digits) = match trimmed.first() {
        Some(b'-') => (true, &trimmed[1..]),
        Some(b'+') => (false, &trimmed[1..]),
        _ => (false, trimmed),
    };
    if digits.is_empty()
        || !digits[0].is_ascii_digit()
        || !digits[digits.len() - 1].is_ascii_digit()
    {
        return None;
    }
    let mut value = String::new();
    let mut previous_underscore = false;
    for &b in digits {
        if b == b'_' {
            if previous_underscore {
                return None;
            }
            previous_underscore = true;
        } else if b.is_ascii_digit() {
            previous_underscore = false;
            value.push(b as char);
        } else {
            return None;
        }
    }
    let value = value.trim_start_matches('0');
    if value.is_empty() {
        return Some("0".to_string());
    }
    Some(if negative {
        format!("-{}", value)
    } else {
        value.to_string()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_lines() {
        assert_eq!(
            splitlines(b"a\nb\r\nc\rd"),
            vec![&b"a"[..], b"b", b"c", b"d"]
        );
        assert_eq!(splitlines(b"a\n"), vec![&b"a"[..]]);
        assert_eq!(splitlines(b""), Vec::<&[u8]>::new());
        assert_eq!(splitlines(b"\n\n"), vec![&b""[..], b""]);
    }

    #[test]
    fn finds_references() {
        assert_eq!(
            macro_references(b"default $(shell,echo 1) $( FOO) $(x"),
            vec![b"shell".to_vec(), b"FOO".to_vec(), b"x".to_vec()]
        );
        assert_eq!(macro_references(b"$()"), Vec::<Vec<u8>>::new());
        assert_eq!(macro_references(b"\xff $(A)"), vec![b"A".to_vec()]);
    }

    #[test]
    fn matches_assignments() {
        assert_eq!(
            variable_assignment(b"  FOO := $(shell,x)"),
            Some((b"FOO".to_vec(), vec![b"shell".to_vec()]))
        );
        assert_eq!(
            variable_assignment(b"BAR+=1"),
            Some((b"BAR".to_vec(), vec![]))
        );
        assert_eq!(variable_assignment(b"config FOO"), None);
    }

    #[test]
    fn parses_ints() {
        assert_eq!(python_int(b" 42 ").as_deref(), Some("42"));
        assert_eq!(python_int(b"-007").as_deref(), Some("-7"));
        assert_eq!(python_int(b"1_000").as_deref(), Some("1000"));
        assert_eq!(python_int(b"-0").as_deref(), Some("0"));
        assert_eq!(python_int(b"0x10"), None);
        assert_eq!(python_int(b""), None);
        assert_eq!(python_int(b"1__0"), None);
    }
}
