//! Reading the golden fixtures in core/fixtures (see its README for the schemas).
#![allow(dead_code)]

use std::io::Read;
use std::path::PathBuf;

use serde_json::Value;

pub fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../fixtures")
}

/// The file's bytes, from `<path>` or else `<path>.gz`.
pub fn bytes(path: &str) -> Vec<u8> {
    let plain = dir().join(path);
    if let Ok(data) = std::fs::read(&plain) {
        return data;
    }
    let gz = dir().join(format!("{path}.gz"));
    let file = std::fs::File::open(&gz).unwrap_or_else(|_| panic!("missing fixture {path}"));
    let mut out = Vec::new();
    flate2::read::GzDecoder::new(file)
        .read_to_end(&mut out)
        .expect("valid gzip");
    out
}

pub fn text(path: &str) -> String {
    String::from_utf8(bytes(path)).expect("UTF-8 fixture")
}

pub fn json(path: &str) -> Value {
    use serde::Deserialize;
    let data = bytes(path);
    let mut de = serde_json::Deserializer::from_slice(&data);
    de.disable_recursion_limit();
    Value::deserialize(&mut de).unwrap_or_else(|e| panic!("{path}: {e}"))
}

/// Input names (inputs/<name>.pgn), sorted.
pub fn inputs() -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir().join("inputs"))
        .expect("inputs dir")
        .filter_map(|e| {
            let name = e.ok()?.file_name().into_string().ok()?;
            let stem = name.strip_suffix(".gz").unwrap_or(&name);
            stem.strip_suffix(".pgn").map(str::to_owned)
        })
        .collect();
    names.sort();
    names
}

/// Compares JSON values, numbers as f64 within `tol` (relative), and reports the first
/// difference with its path.
pub fn diff(path: &str, expected: &Value, actual: &Value, tol: f64) -> Option<String> {
    match (expected, actual) {
        (Value::Number(a), Value::Number(b)) => {
            let (a, b) = (a.as_f64()?, b.as_f64()?);
            let ok = a == b || (a - b).abs() <= tol * a.abs().max(b.abs());
            (!ok).then(|| format!("{path}: expected {a}, got {b}"))
        }
        (Value::Array(a), Value::Array(b)) => {
            if a.len() != b.len() {
                return Some(format!(
                    "{path}: expected {} items, got {}\n  expected {}\n  got      {}",
                    a.len(),
                    b.len(),
                    short(expected),
                    short(actual)
                ));
            }
            a.iter()
                .zip(b)
                .enumerate()
                .find_map(|(i, (x, y))| diff(&format!("{path}[{i}]"), x, y, tol))
        }
        (Value::Object(a), Value::Object(b)) => {
            for (k, x) in a {
                match b.get(k) {
                    Some(y) => {
                        if let Some(d) = diff(&format!("{path}.{k}"), x, y, tol) {
                            return Some(d);
                        }
                    }
                    None if x.is_null() => {}
                    None => return Some(format!("{path}.{k}: missing, expected {}", short(x))),
                }
            }
            b.iter()
                .find(|(k, y)| !a.contains_key(*k) && !y.is_null())
                .map(|(k, y)| format!("{path}.{k}: unexpected {}", short(y)))
        }
        _ => (expected != actual).then(|| {
            format!(
                "{path}: expected {}, got {}",
                short(expected),
                short(actual)
            )
        }),
    }
}

fn short(v: &Value) -> String {
    let s = v.to_string();
    if s.len() > 300 {
        format!("{}…", &s[..300])
    } else {
        s
    }
}

#[track_caller]
pub fn assert_same(path: &str, expected: &Value, actual: &Value, tol: f64) {
    if let Some(d) = diff(path, expected, actual, tol) {
        panic!("{d}");
    }
}
