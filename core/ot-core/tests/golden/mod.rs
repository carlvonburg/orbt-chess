//! Reading the golden fixtures in core/fixtures (see its README for the schemas).
#![allow(dead_code)]

use std::collections::HashMap;
use std::io::Read;
use std::path::PathBuf;

use ot_core::chess::{Epd, PieceKind, Side};
use ot_core::repertoire::{NodeId, RepertoireTree};
use serde_json::Value;

pub fn dir() -> PathBuf {
    // At run time, so the tests still find the fixtures after the checkout moved.
    let crate_dir =
        std::env::var("CARGO_MANIFEST_DIR").unwrap_or_else(|_| env!("CARGO_MANIFEST_DIR").into());
    PathBuf::from(crate_dir).join("../fixtures")
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

/// `OT_REBASE_GOLDENS=1`: tests that support it write what the core produces into their
/// fixture instead of comparing (after an intended change; check the diff before committing).
pub fn rebasing() -> bool {
    std::env::var_os("OT_REBASE_GOLDENS").is_some()
}

/// Writes a fixture back where `json` read it from (gzipped and compact if it was).
pub fn write_json(path: &str, value: &Value) {
    use std::io::Write;
    let compact = !bytes(path).starts_with(b"{\n");
    let data = if compact {
        serde_json::to_vec(value)
    } else {
        serde_json::to_vec_pretty(value)
    }
    .expect("JSON");
    let plain = dir().join(path);
    if plain.exists() {
        std::fs::write(&plain, data).expect("write fixture");
        return;
    }
    let file = std::fs::File::create(dir().join(format!("{path}.gz"))).expect("write fixture");
    let mut gz = flate2::write::GzEncoder::new(file, flate2::Compression::best());
    gz.write_all(&data).expect("write fixture");
    gz.finish().expect("write fixture");
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

/// The EPDs the fixtures use where they differ from the tree's: chesskit-swift kept castling
/// rights when a rook was captured on its home square, and dropped them only when the king or
/// that rook moved (a bug; shakmaty is right). The fixtures were recorded with it.
pub fn legacy_epds(tree: &RepertoireTree) -> HashMap<NodeId, Epd> {
    fn castling(epd: &Epd) -> String {
        epd.as_str().split(' ').nth(2).unwrap_or("-").to_owned()
    }
    let mut result = HashMap::new();
    let mut stack = vec![(RepertoireTree::ROOT, castling(&tree.root().epd))];
    while let Some((id, rights)) = stack.pop() {
        let Some(node) = tree.get(id) else { continue };
        if castling(&node.epd) != rights {
            let mut fields: Vec<&str> = node.epd.as_str().split(' ').collect();
            fields[2] = &rights;
            result.insert(id, Epd::new(fields.join(" ")));
        }
        for &child in &node.children {
            let Some(mv) = tree.get(child).and_then(|c| c.mv.as_ref()) else {
                continue;
            };
            // chesskit-swift's invalidateCastling: any move of a king, or a rook of the
            // mover's color leaving its rook's start square.
            let from = mv.from();
            let lost: &[char] = match node.position.piece_at(from) {
                Some(p) if p.kind == PieceKind::King => match p.side {
                    Side::White => &['K', 'Q'],
                    Side::Black => &['k', 'q'],
                },
                Some(p) if p.kind == PieceKind::Rook => match (p.side, from.to_string().as_str()) {
                    (Side::White, "a1") => &['Q'],
                    (Side::White, "h1") => &['K'],
                    (Side::Black, "a8") => &['q'],
                    (Side::Black, "h8") => &['k'],
                    _ => &[],
                },
                _ => &[],
            };
            let mut next: String = rights.chars().filter(|c| !lost.contains(c)).collect();
            if next.is_empty() || next == "-" {
                next = "-".to_owned();
            }
            stack.push((child, next));
        }
    }
    result
}
