//! Snapshots of the repertoire's files besides the PGN: card ids (stored in the sidecar and the
//! review log), the sidecars in tests/data/sidecars and the review logs in tests/data/revlog.
//! After an intended change, review the new snapshots with `cargo insta review`.

mod common;

use std::collections::HashSet;
use std::fmt::Write;

use ot_core::chess::Epd;
use ot_core::formats::{Sidecar, revlog};
use ot_core::repertoire::RepertoireTree;
use ot_core::training::anki::{Card, DeckConfig, SchedTiming};

#[test]
fn card_ids() {
    // Card ids are stored, so they must never change for a position.
    let tree = RepertoireTree::from_pgn(&common::repertoire("berlin"));
    let mut out = String::new();
    for node in tree.nodes().take(40) {
        writeln!(out, "{} {}", Card::id_for(&node.epd), node.epd.as_str()).unwrap();
    }
    insta::assert_snapshot!(out);
}

fn sidecar(name: &str) -> Sidecar {
    let bytes = std::fs::read(common::data_path(&format!("sidecars/{name}.otrep.json"))).unwrap();
    Sidecar::decode(&bytes).unwrap_or_else(|e| panic!("{name}: {e}"))
}

fn text(s: &Sidecar) -> String {
    String::from_utf8(s.encoded()).unwrap()
}

#[test]
fn sidecars() {
    let checks = common::data_json("sidecars/checks.json");
    let t = &checks["timing"];
    let timing = SchedTiming::new(
        t["daysElapsed"].as_i64().unwrap(),
        t["nextDayAt"].as_i64().unwrap(),
        t["now"].as_i64().unwrap(),
    );
    for name in ["minimal", "full", "masters", "other"] {
        let s = sidecar(name);
        // What the core writes, and writing what it read back gives the same bytes.
        insta::assert_snapshot!(format!("sidecar.{name}"), text(&s));
        let again = Sidecar::decode(&s.encoded()).unwrap();
        assert!(again.encoded() == s.encoded(), "{name}");

        let p = s.estimated_progress();
        let c = s.estimated_study_counts(&DeckConfig::default(), &timing);
        let estimates = format!(
            "config key {}\ndatabase {} ({})\nprogress {p:?}\ncounts {c:?}\nnext due {:?}, due tomorrow {:?}\nlater learning dues {:?}\n",
            s.config_key(),
            s.database.cache_key(),
            s.database.summary(),
            s.next_due(&timing),
            s.due_tomorrow(&timing),
            s.later_learning_dues(&timing),
        );
        insta::assert_snapshot!(format!("estimates.{name}"), estimates);
    }

    let (full, other) = (sidecar("full"), sidecar("other"));
    insta::assert_snapshot!("sidecar.full_merged_with_other", text(&full.merged(&other)));

    let active: HashSet<Epd> = checks["active"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| Epd::new(e.as_str().unwrap()))
        .collect();
    let mut synced = full.clone();
    let changed = synced.sync_suspension(&active);
    insta::assert_snapshot!(
        "sidecar.full_synced",
        format!("changed: {changed}\n{}", text(&synced))
    );
}

#[test]
fn review_logs() {
    // Each line of a log re-encodes to the same bytes (decoding sorts, so line by line).
    let log = common::data_text("revlog/revlog.otlog.jsonl");
    for line in log.lines() {
        let entry = revlog::decode(line.as_bytes());
        assert_eq!(entry.len(), 1, "{line}");
        assert_eq!(
            String::from_utf8(revlog::encode(&entry)).unwrap(),
            format!("{line}\n")
        );
    }
    // Lines that do not decode are skipped; the rest come out sorted by id.
    let garbage = common::data_text("revlog/unsorted_with_garbage.otlog.jsonl");
    let decoded = revlog::encode(&revlog::decode(garbage.as_bytes()));
    insta::assert_snapshot!(String::from_utf8(decoded).unwrap());
}
