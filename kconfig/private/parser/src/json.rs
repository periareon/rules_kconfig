//! JSON output, as the Python backend wrote it.
//!
//! The response goes back to Starlark as bytes: the UTF-8 of Starlark
//! strings, and a file's content in it is the file's own bytes, which need
//! not be UTF-8. serde_json writes `str`s only, so `Value::dump` here writes
//! byte strings through unchanged, escaping what `json.dumps` escapes. The
//! files the generators render, the manifest and the `options` of
//! `settings/BUILD.bazel`, are text, and go through serde_json with
//! `PythonFormatter`, which has Python's separators and `ensure_ascii`.

use std::fmt::Write as _;
use std::io;

use serde::ser::{Serialize, SerializeMap, SerializeSeq, Serializer};
use serde_json::ser::Formatter;

/// A response, or part of one.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Str(Vec<u8>),
    Array(Vec<Value>),
    /// Entries in order, as Python dicts keep them.
    Object(Vec<(Vec<u8>, Value)>),
}

impl Value {
    pub fn str(text: impl AsRef<[u8]>) -> Value {
        Value::Str(text.as_ref().to_vec())
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Object(entries) => entries
                .iter()
                .find(|(k, _)| k == key.as_bytes())
                .map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Value]> {
        match self {
            Value::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&[u8]> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    /// `json.dumps(value, ensure_ascii=False)`, with byte strings as they are.
    pub fn dump(&self) -> Vec<u8> {
        let mut out = Vec::new();
        self.write(&mut out);
        out
    }

    fn write(&self, out: &mut Vec<u8>) {
        match self {
            Value::Null => out.extend_from_slice(b"null"),
            Value::Bool(true) => out.extend_from_slice(b"true"),
            Value::Bool(false) => out.extend_from_slice(b"false"),
            Value::Str(s) => write_bytes_string(out, s),
            Value::Array(items) => {
                out.push(b'[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.extend_from_slice(b", ");
                    }
                    item.write(out);
                }
                out.push(b']');
            }
            Value::Object(entries) => {
                out.push(b'{');
                for (i, (key, value)) in entries.iter().enumerate() {
                    if i > 0 {
                        out.extend_from_slice(b", ");
                    }
                    write_bytes_string(out, key);
                    out.extend_from_slice(b": ");
                    value.write(out);
                }
                out.push(b'}');
            }
        }
    }

    /// `json.dumps(value)`: ASCII, Python's separators.
    pub fn dump_ascii(&self) -> Result<Vec<u8>, String> {
        self.dump_with(PythonFormatter::compact())
    }

    /// `json.dumps(value, indent=indent)`.
    pub fn dump_indented(&self, indent: usize) -> Result<Vec<u8>, String> {
        self.dump_with(PythonFormatter::indented(indent))
    }

    fn dump_with(&self, formatter: PythonFormatter) -> Result<Vec<u8>, String> {
        let mut out = Vec::new();
        let mut serializer = serde_json::Serializer::with_formatter(&mut out, formatter);
        self.serialize(&mut serializer).map_err(|e| e.to_string())?;
        Ok(out)
    }
}

/// A JSON string of bytes: `"`, `\` and control characters escaped as
/// `json.dumps` escapes them, every other byte as it is.
fn write_bytes_string(out: &mut Vec<u8>, text: &[u8]) {
    out.push(b'"');
    for &byte in text {
        match byte {
            b'"' => out.extend_from_slice(b"\\\""),
            b'\\' => out.extend_from_slice(b"\\\\"),
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            b'\t' => out.extend_from_slice(b"\\t"),
            0x08 => out.extend_from_slice(b"\\b"),
            0x0c => out.extend_from_slice(b"\\f"),
            0x00..=0x1f => {
                let _ = write!(Escaper(out), "\\u{:04x}", byte);
            }
            _ => out.push(byte),
        }
    }
    out.push(b'"');
}

struct Escaper<'a>(&'a mut Vec<u8>);

impl std::fmt::Write for Escaper<'_> {
    fn write_str(&mut self, s: &str) -> std::fmt::Result {
        self.0.extend_from_slice(s.as_bytes());
        Ok(())
    }
}

/// Text only: a byte string that is not UTF-8 is an error here.
impl Serialize for Value {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        fn text<E: serde::ser::Error>(bytes: &[u8]) -> Result<&str, E> {
            std::str::from_utf8(bytes).map_err(E::custom)
        }
        match self {
            Value::Null => serializer.serialize_unit(),
            Value::Bool(b) => serializer.serialize_bool(*b),
            Value::Str(s) => serializer.serialize_str(text(s)?),
            Value::Array(items) => {
                let mut seq = serializer.serialize_seq(Some(items.len()))?;
                for item in items {
                    seq.serialize_element(item)?;
                }
                seq.end()
            }
            Value::Object(entries) => {
                let mut map = serializer.serialize_map(Some(entries.len()))?;
                for (key, value) in entries {
                    map.serialize_entry(text(key)?, value)?;
                }
                map.end()
            }
        }
    }
}

/// `json.dumps`'s output: `, ` and `: ` as separators, or `indent` with a
/// newline per item, and every non-ASCII character as a `\u` escape.
pub struct PythonFormatter {
    indent: Option<usize>,
    current_indent: usize,
    has_value: bool,
}

impl PythonFormatter {
    pub fn compact() -> PythonFormatter {
        PythonFormatter {
            indent: None,
            current_indent: 0,
            has_value: false,
        }
    }

    pub fn indented(indent: usize) -> PythonFormatter {
        PythonFormatter {
            indent: Some(indent),
            current_indent: 0,
            has_value: false,
        }
    }

    fn newline<W: ?Sized + io::Write>(&self, writer: &mut W) -> io::Result<()> {
        if let Some(width) = self.indent {
            writer.write_all(b"\n")?;
            for _ in 0..self.current_indent * width {
                writer.write_all(b" ")?;
            }
        }
        Ok(())
    }

    fn begin_item<W: ?Sized + io::Write>(&mut self, writer: &mut W, first: bool) -> io::Result<()> {
        if !first {
            writer.write_all(if self.indent.is_some() { b"," } else { b", " })?;
        }
        self.newline(writer)
    }

    fn begin_container<W: ?Sized + io::Write>(
        &mut self,
        writer: &mut W,
        open: &[u8],
    ) -> io::Result<()> {
        self.current_indent += 1;
        self.has_value = false;
        writer.write_all(open)
    }

    fn end_container<W: ?Sized + io::Write>(
        &mut self,
        writer: &mut W,
        close: &[u8],
    ) -> io::Result<()> {
        self.current_indent -= 1;
        if self.has_value {
            self.newline(writer)?;
        }
        writer.write_all(close)
    }
}

impl Formatter for PythonFormatter {
    fn begin_array<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.begin_container(writer, b"[")
    }

    fn end_array<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.end_container(writer, b"]")
    }

    fn begin_array_value<W: ?Sized + io::Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> io::Result<()> {
        self.begin_item(writer, first)
    }

    fn end_array_value<W: ?Sized + io::Write>(&mut self, _writer: &mut W) -> io::Result<()> {
        self.has_value = true;
        Ok(())
    }

    fn begin_object<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.begin_container(writer, b"{")
    }

    fn end_object<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.end_container(writer, b"}")
    }

    fn begin_object_key<W: ?Sized + io::Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> io::Result<()> {
        self.begin_item(writer, first)
    }

    fn begin_object_value<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        writer.write_all(b": ")
    }

    fn end_object_value<W: ?Sized + io::Write>(&mut self, _writer: &mut W) -> io::Result<()> {
        self.has_value = true;
        Ok(())
    }

    fn write_string_fragment<W: ?Sized + io::Write>(
        &mut self,
        writer: &mut W,
        fragment: &str,
    ) -> io::Result<()> {
        for ch in fragment.chars() {
            let code = ch as u32;
            if ch.is_ascii() {
                writer.write_all(&[code as u8])?;
            } else if code >= 0x10000 {
                let v = code - 0x10000;
                write!(
                    writer,
                    "\\u{:04x}\\u{:04x}",
                    0xd800 + (v >> 10),
                    0xdc00 + (v & 0x3ff)
                )?;
            } else {
                write!(writer, "\\u{:04x}", code)?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_bytes_through() {
        let value = Value::Object(vec![
            (
                b"a".to_vec(),
                Value::Str(b"h\xc3\xa9llo \xff\n\"\\".to_vec()),
            ),
            (
                b"n".to_vec(),
                Value::Array(vec![Value::Bool(true), Value::Null]),
            ),
        ]);
        assert_eq!(
            value.dump(),
            b"{\"a\": \"h\xc3\xa9llo \xff\\n\\\"\\\\\", \"n\": [true, null]}".to_vec()
        );
    }

    #[test]
    fn escapes_ascii_like_python() {
        let value = Value::Array(vec![Value::str("é😀\u{1}"), Value::str("1")]);
        assert_eq!(
            value.dump_ascii().unwrap(),
            r#"["\u00e9\ud83d\ude00\u0001", "1"]"#.as_bytes().to_vec()
        );
        assert!(Value::Str(vec![0xff]).dump_ascii().is_err());
    }

    #[test]
    fn indents_like_python() {
        let value = Value::Object(vec![
            (b"root".to_vec(), Value::str("Kconfig")),
            (
                b"files".to_vec(),
                Value::Array(vec![Value::str("a"), Value::str("b")]),
            ),
            (b"empty".to_vec(), Value::Array(vec![])),
            (
                b"map".to_vec(),
                Value::Object(vec![(b"k".to_vec(), Value::str("v"))]),
            ),
        ]);
        let expected = "{\n  \"root\": \"Kconfig\",\n  \"files\": [\n    \"a\",\n    \"b\"\n  ],\n  \"empty\": [],\n  \"map\": {\n    \"k\": \"v\"\n  }\n}";
        assert_eq!(
            value.dump_indented(2).unwrap(),
            expected.as_bytes().to_vec()
        );
    }
}
