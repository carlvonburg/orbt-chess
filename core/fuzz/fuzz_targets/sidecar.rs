//! A sidecar file (`<Name>.otrep.json`): decode, encode, open a document with it, study.
#![no_main]

use libfuzzer_sys::fuzz_target;
use ot_core::formats::Sidecar;
use ot_core::repertoire::RepertoireTree;

fuzz_target!(|data: &[u8]| {
    let Ok(sidecar) = Sidecar::decode(data) else {
        return;
    };
    let encoded = sidecar.encoded();
    let again = Sidecar::decode(&encoded).expect("an encoded sidecar decodes");
    assert_eq!(again.encoded(), encoded, "encode is stable");
    let stats = ot_fuzz::synthetic_stats(&RepertoireTree::from_pgn(ot_fuzz::PGN));
    ot_fuzz::exercise_document(ot_fuzz::PGN, data, &stats, 200);
});
