//! Rendering helpers: Python's `str.format` for the templates, as far as
//! they use it, and Starlark string escaping.

/// `template.format(**fields)`, where the template's `{name}` placeholders
/// name entries of `fields`; the `{{` and `}}` of the Python templates are
/// already single braces here.
pub fn template(template: &str, fields: &[(&str, &[u8])]) -> Vec<u8> {
    let mut out = Vec::with_capacity(template.len());
    let bytes = template.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'{' {
            if let Some(end) = bytes[i..].iter().position(|&b| b == b'}') {
                let name = &template[i + 1..i + end];
                if let Some((_, value)) = fields.iter().find(|(field, _)| *field == name) {
                    out.extend_from_slice(value);
                    i += end + 1;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    out
}

/// A string's text inside Starlark double quotes: backslashes and quotes
/// escaped, as the Python backend escaped them.
pub fn escape_starlark(text: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len());
    for &b in text {
        match b {
            b'\\' => out.extend_from_slice(b"\\\\"),
            b'"' => out.extend_from_slice(b"\\\""),
            _ => out.push(b),
        }
    }
    out
}

pub fn concat(parts: &[&[u8]]) -> Vec<u8> {
    parts.concat()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fills_templates() {
        assert_eq!(
            template("a {x} {y} {z} {x}", &[("x", b"1"), ("y", b"")]),
            b"a 1  {z} 1".to_vec()
        );
        assert_eq!(
            template("{flag: \"true\"}", &[]),
            b"{flag: \"true\"}".to_vec()
        );
    }

    #[test]
    fn escapes() {
        assert_eq!(escape_starlark(br#"a\b"c"#), br#"a\\b\"c"#.to_vec());
    }
}
