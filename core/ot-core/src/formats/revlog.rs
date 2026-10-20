//! The review log file `<Name>.otlog.jsonl`: one JSON entry per line, append-only.

use std::collections::BTreeMap;

use crate::training::anki::RevlogEntry;

pub const FILE_EXTENSION: &str = "otlog.jsonl";

/// Entries in id order; unreadable lines are skipped.
pub fn decode(data: &[u8]) -> Vec<RevlogEntry> {
    let mut result: Vec<RevlogEntry> = data
        .split(|&b| b == b'\n')
        .filter(|line| !line.is_empty())
        .filter_map(|line| serde_json::from_slice(line).ok())
        .collect();
    result.sort_by_key(|e| e.id);
    result
}

/// One line per entry, keys sorted, each ending in a newline.
pub fn encode(entries: &[RevlogEntry]) -> Vec<u8> {
    let mut data = Vec::new();
    for entry in entries {
        data.extend(super::apple_json::to_vec_compact(entry));
        data.push(b'\n');
    }
    data
}

/// Union by id, for logs written on two devices.
pub fn merged(a: &[RevlogEntry], b: &[RevlogEntry]) -> Vec<RevlogEntry> {
    let mut by_id: BTreeMap<i64, RevlogEntry> = BTreeMap::new();
    for entry in a.iter().chain(b) {
        by_id.insert(entry.id, entry.clone());
    }
    by_id.into_values().collect()
}
