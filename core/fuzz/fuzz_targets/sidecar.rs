//! A sidecar file (`<Name>.otrep.json`): decode, encode, open a document with it, study.
#![no_main]

use libfuzzer_sys::fuzz_target;
use orbt_core::formats::Sidecar;
use orbt_core::repertoire::RepertoireTree;

fuzz_target!(|data: &[u8]| {
    let Ok(sidecar) = Sidecar::decode(data) else {
        return;
    };
    let encoded = sidecar.encoded();
    let again = Sidecar::decode(&encoded).expect("an encoded sidecar decodes");
    assert_eq!(again.encoded(), encoded, "encode is stable");
    let stats = orbt_fuzz::synthetic_stats(&RepertoireTree::from_pgn(orbt_fuzz::PGN));
    orbt_fuzz::exercise_document(orbt_fuzz::PGN, data, &stats, 200);
});
