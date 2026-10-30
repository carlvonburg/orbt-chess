//! Storage provider answers (Dropbox, Google Drive): the sync loop reads any status, headers
//! and body, merges any download into the local files, and never panics; nor do the sign-ins'
//! answers or conflict copies' names.
#![no_main]

use libfuzzer_sys::fuzz_target;
use orbt_core::chess::Side;
use orbt_core::http::{Header, HttpResponse};
use orbt_core::sync::{FileKind, SyncEngine, conflict_original, drive, dropbox, merge};

const STATUSES: [u16; 12] = [200, 200, 200, 401, 400, 404, 409, 412, 429, 500, 503, 403];

/// The answers in `data`: a status byte, a header byte, a length byte, then the body.
fn answers(mut data: &[u8]) -> Vec<Option<HttpResponse>> {
    let mut result = Vec::new();
    while let [status, header, len, rest @ ..] = data {
        let len = (*len as usize).min(rest.len());
        let (body, tail) = rest.split_at(len);
        data = tail;
        if *status == 255 {
            result.push(None);
            continue;
        }
        let mut r = HttpResponse::new(STATUSES[*status as usize % STATUSES.len()], body);
        let value = String::from_utf8_lossy(body).into_owned();
        match header % 4 {
            0 => {}
            1 => r.headers.push(Header { name: "Dropbox-API-Result".into(), value }),
            2 => r.headers.push(Header { name: "ETag".into(), value }),
            _ => r.headers.push(Header { name: "Retry-After".into(), value }),
        }
        result.push(Some(r));
    }
    result
}

fuzz_target!(|data: &[u8]| {
    for kind in [FileKind::Pgn, FileKind::Sidecar, FileKind::Revlog] {
        merge(kind, orbt_fuzz::PGN.as_bytes(), data);
        merge(kind, &orbt_fuzz::sidecar(Side::White), data);
    }
    let name = String::from_utf8_lossy(data);
    let _ = conflict_original(&name);
    let _ = conflict_original(&format!("{name}.pgn"));
    let answers = answers(data);
    for answer in answers.iter().flatten() {
        let _ = drive::read_token(answer, i64::MAX);
        let _ = drive::read_account(answer);
        let _ = dropbox::read_token(answer, i64::MAX);
        let _ = dropbox::read_account(answer);
    }
    for mut engine in [
        SyncEngine::dropbox("key", data),
        SyncEngine::drive(b""),
        SyncEngine::drive(data),
        SyncEngine::drive_oauth(
            drive::Client { id: "client".into(), secret: Some("s".into()) },
            b"",
        ),
    ] {
        engine.set_credentials(Some("t".into()), None, Some("r".into()));
        engine.set_local_files(vec![
            ("Fuzz.pgn".into(), orbt_fuzz::PGN.into()),
            ("Fuzz.otrep.json".into(), orbt_fuzz::sidecar(Side::White)),
        ]);
        engine.set_watching(true);
        let mut answers = answers.iter();
        let mut now = 0;
        'run: for step in 0..400 {
            now += 400_000;
            if step % 50 == 0 {
                engine.sync_now();
                engine.set_credentials(Some("t".into()), None, None);
            }
            for op in engine.poll(now).ops {
                let Some(answer) = answers.next() else { break 'run };
                let outcome = engine.on_response(&op, answer.as_ref(), now);
                for write in outcome.writes {
                    engine.local_changed(&write.name, Some(write.data));
                }
            }
        }
        let _ = engine.saved_state();
        let _ = engine.unsynced_files();
    }
});
