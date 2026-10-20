//! JSON written the way Foundation's `JSONEncoder` writes it (`.prettyPrinted`, sorted keys,
//! unescaped slashes), so files saved by this core are byte-identical to the Swift build's and
//! an unchanged sidecar is never rewritten.
//!
//! Differences from serde_json's pretty printer: `"key" : value`; an empty object or array is
//! written as an opening bracket, a blank line and the closing bracket; a whole double is
//! written without a fraction (`1`, not `1.0`); other doubles use Swift's `description`
//! (`1e-05`, not `1e-5`). Keys are sorted by the callers, which declare fields in key order and
//! use sorted maps.

use std::io::{self, Write};

use serde::Serialize;
use serde_json::ser::Formatter;

pub fn to_vec_pretty<T: Serialize>(value: &T) -> Vec<u8> {
    let mut out = Vec::new();
    let mut ser = serde_json::Serializer::with_formatter(&mut out, AppleFormatter::default());
    value.serialize(&mut ser).expect("serializes");
    out
}

/// Compact JSON (`JSONEncoder` without `.prettyPrinted`), with Swift's number format.
pub fn to_vec_compact<T: Serialize>(value: &T) -> Vec<u8> {
    let mut out = Vec::new();
    let mut ser = serde_json::Serializer::with_formatter(&mut out, CompactSwiftNumbers);
    value.serialize(&mut ser).expect("serializes");
    out
}

/// Swift's text for a double: whole values below 2^53 as integers, other values as Swift's
/// `description` (shortest round-trip digits; exponent form below 1e-4 and from 2^53 up).
pub fn swift_double(value: f64) -> String {
    if !value.is_finite() {
        return value.to_string();
    }
    if value == value.trunc() && value.abs() < 9_007_199_254_740_992.0 {
        return format!("{}", value as i64);
    }
    // Shortest digits and decimal exponent, from Rust's `{:e}` (also shortest round-trip).
    let sci = format!("{value:e}");
    let (mantissa, exp) = sci.split_once('e').expect("exponent");
    let exp: i32 = exp.parse().expect("exponent");
    let negative = mantissa.starts_with('-');
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    let sign = if negative { "-" } else { "" };
    if (-4..16).contains(&exp) {
        let point = exp + 1; // digits before the decimal point
        let text = if point <= 0 {
            format!("0.{}{}", "0".repeat((-point) as usize), digits)
        } else if point as usize >= digits.len() {
            format!("{digits}{}.0", "0".repeat(point as usize - digits.len()))
        } else {
            format!(
                "{}.{}",
                &digits[..point as usize],
                &digits[point as usize..]
            )
        };
        return format!("{sign}{text}");
    }
    let (first, rest) = digits.split_at(1);
    let frac = if rest.is_empty() {
        String::new()
    } else {
        format!(".{rest}")
    };
    let esign = if exp < 0 { '-' } else { '+' };
    format!("{sign}{first}{frac}e{esign}{:02}", exp.abs())
}

struct CompactSwiftNumbers;

impl Formatter for CompactSwiftNumbers {
    fn write_f64<W: ?Sized + Write>(&mut self, writer: &mut W, value: f64) -> io::Result<()> {
        writer.write_all(swift_double(value).as_bytes())
    }
}

#[derive(Default)]
struct AppleFormatter {
    indent: usize,
    has_value: bool,
}

impl AppleFormatter {
    fn newline<W: ?Sized + Write>(&self, writer: &mut W) -> io::Result<()> {
        writer.write_all(b"\n")?;
        for _ in 0..self.indent {
            writer.write_all(b"  ")?;
        }
        Ok(())
    }

    fn end<W: ?Sized + Write>(&mut self, writer: &mut W, bracket: &[u8]) -> io::Result<()> {
        self.indent -= 1;
        if self.has_value {
            self.newline(writer)?;
        } else {
            // Foundation: an empty container spans a blank line.
            writer.write_all(b"\n")?;
            self.newline(writer)?;
        }
        self.has_value = true;
        writer.write_all(bracket)
    }
}

impl Formatter for AppleFormatter {
    fn write_f64<W: ?Sized + Write>(&mut self, writer: &mut W, value: f64) -> io::Result<()> {
        writer.write_all(swift_double(value).as_bytes())
    }

    fn begin_array<W: ?Sized + Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.indent += 1;
        self.has_value = false;
        writer.write_all(b"[")
    }

    fn end_array<W: ?Sized + Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.end(writer, b"]")
    }

    fn begin_array_value<W: ?Sized + Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> io::Result<()> {
        if !first {
            writer.write_all(b",")?;
        }
        self.newline(writer)
    }

    fn end_array_value<W: ?Sized + Write>(&mut self, _writer: &mut W) -> io::Result<()> {
        self.has_value = true;
        Ok(())
    }

    fn begin_object<W: ?Sized + Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.indent += 1;
        self.has_value = false;
        writer.write_all(b"{")
    }

    fn end_object<W: ?Sized + Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.end(writer, b"}")
    }

    fn begin_object_key<W: ?Sized + Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> io::Result<()> {
        if !first {
            writer.write_all(b",")?;
        }
        self.newline(writer)
    }

    fn begin_object_value<W: ?Sized + Write>(&mut self, writer: &mut W) -> io::Result<()> {
        writer.write_all(b" : ")
    }

    fn end_object_value<W: ?Sized + Write>(&mut self, _writer: &mut W) -> io::Result<()> {
        self.has_value = true;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doubles_like_swift() {
        assert_eq!(swift_double(1.0), "1");
        assert_eq!(swift_double(-3.0), "-3");
        assert_eq!(swift_double(0.5), "0.5");
        assert_eq!(swift_double(2.3065), "2.3065");
        assert_eq!(swift_double(0.0001), "0.0001");
        assert_eq!(swift_double(0.00001), "1e-05");
        assert_eq!(swift_double(0.000123), "0.000123");
        assert_eq!(swift_double(1.5e-7), "1.5e-07");
        assert_eq!(swift_double(123.456), "123.456");
        assert_eq!(swift_double(1e16), "1e+16");
    }

    #[test]
    fn pretty_layout() {
        let v = serde_json::json!({"a": {}, "b": [1, 2], "c": {"d": []}});
        let text = String::from_utf8(to_vec_pretty(&v)).unwrap();
        assert_eq!(
            text,
            "{\n  \"a\" : {\n\n  },\n  \"b\" : [\n    1,\n    2\n  ],\n  \"c\" : {\n    \"d\" : [\n\n    ]\n  }\n}"
        );
    }
}
