//! A review log (`<Name>.otlog.jsonl`): decode, encode, merge, and the statistics screens.
#![no_main]

use libfuzzer_sys::fuzz_target;
use ot_core::formats::revlog;
use ot_core::statistics::{GraphRange, GraphsContext};

fuzz_target!(|data: &[u8]| {
    let entries = revlog::decode(data);
    let encoded = revlog::encode(&entries);
    assert_eq!(revlog::decode(&encoded), entries, "encode round trips");
    let merged = revlog::merged(&entries, &entries);
    let offset = i64::from(data.first().copied().unwrap_or(0)) * 900 - 12 * 3600;
    let graphs = GraphsContext::new(Vec::new(), 3, 1, merged, ot_fuzz::timing(), offset);
    let _ = graphs.today();
    let _ = graphs.card_counts();
    let _ = graphs.future_due();
    let _ = graphs.reviews();
    for range in [
        GraphRange::Month,
        GraphRange::ThreeMonths,
        GraphRange::Year,
        GraphRange::All,
    ] {
        let _ = graphs.hours(range);
        let _ = graphs.buttons(range);
    }
    let _ = graphs.intervals();
    let _ = graphs.stability();
    let _ = graphs.difficulty();
    let _ = graphs.retrievability();
    let _ = graphs.true_retention(None);
    let _ = graphs.streak();
});
