//! The sync loop against fake Dropbox and Drive servers that read the requests the core
//! builds: offline edits, two devices at once, conflicts, revoked sign-ins, deletions and
//! repertoires created elsewhere.

use std::collections::BTreeMap;

use orbt_core::chess::Side;
use orbt_core::formats::{Sidecar, Timestamp, revlog};
use orbt_core::http::{Header, HttpMethod, HttpRequest, HttpResponse};
use orbt_core::repertoire::RepertoireTree;
use orbt_core::sync::{
    AuthNeed, LocalWrite, SyncEngine, SyncOp, SyncOpKind, SyncOutcome, SyncState, content_hash,
};
use serde_json::{Value, json};

const TOKEN: &str = "access-1";
const REFRESH: &str = "refresh-1";

fn header<'a>(r: &'a HttpRequest, name: &str) -> Option<&'a str> {
    r.headers
        .iter()
        .find(|h| h.name.eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str())
}

fn respond(status: u16, body: impl Into<Vec<u8>>) -> HttpResponse {
    HttpResponse::new(status, body)
}

fn with_header(mut r: HttpResponse, name: &str, value: String) -> HttpResponse {
    r.headers.push(Header {
        name: name.into(),
        value,
    });
    r
}

trait Server {
    fn handle(&mut self, request: &HttpRequest) -> HttpResponse;
}

// A fake Dropbox: one App folder, revs counting up.

#[derive(Default)]
struct Dropbox {
    files: BTreeMap<String, (Vec<u8>, String)>,
    next_rev: u64,
    access: String,
    refresh: String,
    /// Entries per list page, to exercise paging.
    page_size: usize,
    requests: Vec<String>,
    /// Answer longpolls with changes.
    changed: bool,
}

impl Dropbox {
    fn new() -> Dropbox {
        Dropbox {
            access: TOKEN.into(),
            refresh: REFRESH.into(),
            page_size: 2,
            ..Dropbox::default()
        }
    }

    fn put(&mut self, name: &str, data: &[u8]) -> String {
        self.next_rev += 1;
        let rev = format!("{:09x}", self.next_rev);
        self.files.insert(name.into(), (data.to_vec(), rev.clone()));
        rev
    }

    fn list_page(&self, offset: usize) -> HttpResponse {
        let names: Vec<&String> = self.files.keys().collect();
        let end = (offset + self.page_size).min(names.len());
        let entries: Vec<Value> = names[offset..end]
            .iter()
            .map(|n| json!({".tag": "file", "name": n, "rev": self.files[*n].1, "id": format!("id:{n}")}))
            .chain([json!({".tag": "folder", "name": "Other"})])
            .collect();
        let has_more = end < names.len();
        respond(
            200,
            json!({"entries": entries, "cursor": format!("p{end}"), "has_more": has_more})
                .to_string(),
        )
    }

    fn conflict(summary: &str) -> HttpResponse {
        respond(
            409,
            json!({"error_summary": summary, "error": {".tag": "path"}}).to_string(),
        )
    }
}

fn name_of(path: &str) -> String {
    path.trim_start_matches('/').to_owned()
}

impl Server for Dropbox {
    fn handle(&mut self, r: &HttpRequest) -> HttpResponse {
        let endpoint = r.url.split(".com").nth(1).unwrap_or_default().to_owned();
        self.requests.push(endpoint.clone());
        assert_eq!(r.method, HttpMethod::Post);
        if endpoint == "/oauth2/token" {
            let body = String::from_utf8(r.body.clone()).unwrap();
            assert!(body.contains("grant_type=refresh_token"));
            assert!(body.contains("client_id=app-key"));
            return if body.contains(&format!("refresh_token={}", self.refresh)) {
                respond(
                    200,
                    json!({"access_token": self.access, "expires_in": 14400, "token_type": "bearer"})
                        .to_string(),
                )
            } else {
                respond(400, r#"{"error": "invalid_grant"}"#)
            };
        }
        if endpoint == "/2/files/list_folder/longpoll" {
            assert!(header(r, "Authorization").is_none());
            return respond(200, json!({"changes": self.changed}).to_string());
        }
        if header(r, "Authorization") != Some(&format!("Bearer {}", self.access)) {
            return respond(401, r#"{"error_summary": "expired_access_token/"}"#);
        }
        let arg: Value = match header(r, "Dropbox-API-Arg") {
            Some(h) => {
                assert!(h.is_ascii());
                serde_json::from_str(h).unwrap()
            }
            None => serde_json::from_slice(&r.body).unwrap(),
        };
        match endpoint.as_str() {
            "/2/files/list_folder" => self.list_page(0),
            "/2/files/list_folder/continue" => {
                let cursor = arg["cursor"].as_str().unwrap();
                self.list_page(cursor[1..].parse().unwrap())
            }
            "/2/files/download" => {
                let name = name_of(arg["path"].as_str().unwrap());
                match self.files.get(&name) {
                    Some((data, rev)) => with_header(
                        respond(200, data.clone()),
                        "Dropbox-API-Result",
                        json!({"name": name, "rev": rev}).to_string(),
                    ),
                    None => Dropbox::conflict("path/not_found/"),
                }
            }
            "/2/files/upload" => {
                let name = name_of(arg["path"].as_str().unwrap());
                assert_eq!(arg["strict_conflict"], true);
                let current = self.files.get(&name).map(|f| f.1.clone());
                let ok = match arg["mode"][".tag"].as_str().unwrap() {
                    "add" => current.is_none(),
                    "update" => current.as_deref() == arg["mode"]["update"].as_str(),
                    _ => false,
                };
                if !ok {
                    return Dropbox::conflict("path/conflict/file/..");
                }
                let rev = self.put(&name, &r.body);
                respond(200, json!({"name": name, "rev": rev}).to_string())
            }
            "/2/files/delete_v2" => {
                let name = name_of(arg["path"].as_str().unwrap());
                match self.files.get(&name) {
                    None => Dropbox::conflict("path_lookup/not_found/"),
                    Some((_, rev)) if Some(rev.as_str()) != arg["parent_rev"].as_str() => {
                        Dropbox::conflict("path_lookup/conflict/")
                    }
                    Some(_) => {
                        self.files.remove(&name);
                        respond(200, "{}")
                    }
                }
            }
            other => panic!("unexpected endpoint {other}"),
        }
    }
}

// A fake Google Drive: a folder, files by id, ETags counting up.

#[derive(Default)]
struct Drive {
    folder: Option<String>,
    /// id → (name, data, etag).
    files: BTreeMap<String, (String, Vec<u8>, String)>,
    next: u64,
    access: String,
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            out.push(u8::from_str_radix(&s[i + 1..i + 3], 16).unwrap());
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).unwrap()
}

fn query(url: &str) -> BTreeMap<String, String> {
    url.split_once('?')
        .map(|(_, q)| q)
        .unwrap_or_default()
        .split('&')
        .filter_map(|kv| kv.split_once('='))
        .map(|(k, v)| (k.to_owned(), percent_decode(v)))
        .collect()
}

impl Drive {
    fn tick(&mut self) -> String {
        self.next += 1;
        format!("\"e{}\"", self.next)
    }

    fn file_json(&self, id: &str) -> String {
        let (name, data, _) = &self.files[id];
        json!({"id": id, "name": name, "md5Checksum": content_hash(data), "version": "1"})
            .to_string()
    }
}

impl Server for Drive {
    fn handle(&mut self, r: &HttpRequest) -> HttpResponse {
        if header(r, "Authorization") != Some(&format!("Bearer {}", self.access)) {
            return respond(401, "{}");
        }
        let path = r.url.split('?').next().unwrap();
        let q = query(&r.url);
        let path = path
            .strip_prefix("https://www.googleapis.com")
            .expect("a Drive URL");
        match (r.method, path) {
            (HttpMethod::Get, "/drive/v3/files") => {
                let q = &q["q"];
                if q.contains("mimeType = 'application/vnd.google-apps.folder'") {
                    let files: Vec<Value> =
                        self.folder.iter().map(|id| json!({"id": id})).collect();
                    return respond(200, json!({ "files": files }).to_string());
                }
                let folder = self.folder.clone().unwrap();
                assert_eq!(q, &format!("'{folder}' in parents and trashed = false"));
                let files: Vec<Value> = self
                    .files
                    .keys()
                    .map(|id| serde_json::from_str(&self.file_json(id)).unwrap())
                    .collect();
                respond(200, json!({ "files": files }).to_string())
            }
            (HttpMethod::Post, "/drive/v3/files") => {
                let body: Value = serde_json::from_slice(&r.body).unwrap();
                assert_eq!(body["name"], "ORBT Chess");
                self.folder = Some("folder-1".into());
                respond(200, r#"{"id": "folder-1"}"#)
            }
            (HttpMethod::Post, "/upload/drive/v3/files") => {
                assert_eq!(q["uploadType"], "multipart");
                let content_type = header(r, "Content-Type").unwrap();
                let boundary = content_type.split("boundary=").nth(1).unwrap();
                let body = String::from_utf8(r.body.clone()).unwrap();
                let parts: Vec<&str> = body.split(&format!("--{boundary}")).collect();
                let metadata: Value =
                    serde_json::from_str(parts[1].split("\r\n\r\n").nth(1).unwrap().trim())
                        .unwrap();
                assert_eq!(metadata["parents"][0], self.folder.clone().unwrap());
                let data = parts[2].split_once("\r\n\r\n").unwrap().1;
                let data = data.strip_suffix("\r\n").unwrap();
                self.next += 1;
                let id = format!("file-{}", self.next);
                let etag = self.tick();
                let name = metadata["name"].as_str().unwrap().to_owned();
                self.files
                    .insert(id.clone(), (name, data.as_bytes().to_vec(), etag.clone()));
                with_header(respond(200, self.file_json(&id)), "ETag", etag)
            }
            (HttpMethod::Patch, p) if p.starts_with("/upload/drive/v3/files/") => {
                let id = p.rsplit('/').next().unwrap().to_owned();
                let Some(current) = self.files.get(&id).map(|f| f.2.clone()) else {
                    return respond(404, "{}");
                };
                if header(r, "If-Match") != Some(current.as_str()) {
                    return respond(
                        412,
                        r#"{"error": {"code": 412, "message": "Precondition Failed"}}"#,
                    );
                }
                let etag = self.tick();
                let file = self.files.get_mut(&id).unwrap();
                file.1 = r.body.clone();
                file.2 = etag.clone();
                with_header(respond(200, self.file_json(&id)), "ETag", etag)
            }
            (HttpMethod::Get, p) if p.starts_with("/drive/v3/files/") => {
                assert_eq!(q["alt"], "media");
                let id = p.rsplit('/').next().unwrap();
                match self.files.get(id) {
                    Some((_, data, etag)) => {
                        with_header(respond(200, data.clone()), "ETag", etag.clone())
                    }
                    None => respond(404, "{}"),
                }
            }
            (HttpMethod::Patch, p) if p.starts_with("/drive/v3/files/") => {
                let id = p.rsplit('/').next().unwrap();
                let body: Value = serde_json::from_slice(&r.body).unwrap();
                assert_eq!(body["trashed"], true);
                match self.files.remove(id) {
                    Some(_) => respond(200, json!({ "id": id }).to_string()),
                    None => respond(404, "{}"),
                }
            }
            other => panic!("unexpected request {other:?}"),
        }
    }
}

// A device: its local folder and its engine.

struct Device {
    engine: SyncEngine,
    local: BTreeMap<String, Vec<u8>>,
    online: bool,
    now: i64,
    writes: Vec<LocalWrite>,
    needs: Option<AuthNeed>,
}

impl Device {
    fn dropbox() -> Device {
        let mut engine = SyncEngine::dropbox("app-key", b"");
        engine.set_credentials(None, None, Some(REFRESH.into()));
        Device::with(engine)
    }

    fn drive() -> Device {
        let mut engine = SyncEngine::drive(b"");
        engine.set_credentials(Some(TOKEN.into()), Some(3_600_000), None);
        Device::with(engine)
    }

    fn with(mut engine: SyncEngine) -> Device {
        engine.set_local_files(Vec::new());
        Device {
            engine,
            local: BTreeMap::new(),
            online: true,
            now: 1_000,
            writes: Vec::new(),
            needs: None,
        }
    }

    fn edit(&mut self, name: &str, data: impl Into<Vec<u8>>) {
        let data = data.into();
        self.local.insert(name.into(), data.clone());
        self.engine.local_changed(name, Some(data));
    }

    fn remove(&mut self, name: &str) {
        self.local.remove(name);
        self.engine.local_changed(name, None);
    }

    fn apply(&mut self, outcome: SyncOutcome) {
        for write in outcome.writes {
            self.local.insert(write.name.clone(), write.data.clone());
            self.writes.push(write);
        }
        for name in outcome.deletes {
            self.local.remove(&name);
        }
        if outcome.needs.is_some() {
            self.needs = outcome.needs;
        }
    }

    /// The next op of the main lane, if any.
    fn next(&mut self) -> Option<SyncOp> {
        let poll = self.engine.poll(self.now);
        if poll.needs.is_some() {
            self.needs = poll.needs;
        }
        poll.ops.into_iter().find(|op| op.kind != SyncOpKind::Watch)
    }

    fn answer(&mut self, server: &mut dyn Server, op: &SyncOp) {
        let response = self.online.then(|| server.handle(&op.request));
        let outcome = self.engine.on_response(op, response.as_ref(), self.now);
        self.apply(outcome);
        self.now += 10;
    }

    /// Runs the engine until it has nothing to send; returns the requests sent.
    fn sync(&mut self, server: &mut dyn Server) -> Vec<SyncOpKind> {
        self.engine.sync_now();
        self.run(server)
    }

    fn run(&mut self, server: &mut dyn Server) -> Vec<SyncOpKind> {
        let mut kinds = Vec::new();
        for _ in 0..60 {
            let Some(op) = self.next() else {
                return kinds;
            };
            kinds.push(op.kind.clone());
            self.answer(server, &op);
            if !self.online {
                return kinds;
            }
        }
        panic!("the sync never settles: {kinds:?}");
    }
}

fn sidecar(id: &str) -> Vec<u8> {
    Sidecar::new(id.into(), Side::White, Timestamp(1_000)).encoded()
}

/// The moves of each line from the start, as SAN.
fn lines(pgn: &[u8]) -> Vec<String> {
    let tree = RepertoireTree::from_pgn(&String::from_utf8_lossy(pgn));
    let mut result = Vec::new();
    let mut stack = vec![(RepertoireTree::ROOT, String::new())];
    while let Some((id, line)) = stack.pop() {
        let node = tree.get(id).unwrap();
        if node.children.is_empty() {
            result.push(line.trim().to_owned());
        }
        for &child in &node.children {
            let san = &tree.get(child).unwrap().mv.as_ref().unwrap().san;
            stack.push((child, format!("{line} {san}")));
        }
    }
    result.sort();
    result
}

const E4: &str = "[Event \"Najdorf\"]\n\n1. e4 c5 2. Nf3 *\n";

fn revlog_line(id: i64) -> String {
    format!(
        "{{\"cid\":\"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -\",\"ease\":3,\"factor\":224,\"id\":{id},\"ivl\":-600,\"lastIvl\":0,\"time\":1234,\"type\":0}}\n"
    )
}

/// Two devices that both have the Najdorf, synced.
fn two_synced_devices(server: &mut Dropbox) -> (Device, Device) {
    let mut a = Device::dropbox();
    a.edit("Najdorf.pgn", E4);
    a.edit("Najdorf.otrep.json", sidecar("n"));
    a.sync(server);
    let mut b = Device::dropbox();
    b.sync(server);
    assert_eq!(a.local, b.local);
    (a, b)
}

#[test]
fn a_repertoire_created_on_another_device_arrives() {
    let mut server = Dropbox::new();
    let mut a = Device::dropbox();
    a.edit("Najdorf.pgn", E4);
    a.edit("Najdorf.otrep.json", sidecar("n"));
    a.edit("Najdorf.otlog.jsonl", revlog_line(1));
    a.edit("notes.txt", "not synced");
    let sent = a.sync(&mut server);
    // A token first, then the listing, then one upload per file.
    assert_eq!(sent[0], SyncOpKind::Refresh);
    assert_eq!(sent.iter().filter(|k| **k == SyncOpKind::Upload).count(), 3);
    assert_eq!(server.files.len(), 3);
    assert!(a.engine.unsynced_files().is_empty());

    let mut b = Device::dropbox();
    b.sync(&mut server);
    assert_eq!(b.local.len(), 3);
    assert_eq!(b.local["Najdorf.pgn"], E4.as_bytes());
    assert!(b.writes.iter().all(|w| w.created));
    // Nothing more to do on either side.
    assert_eq!(
        a.sync(&mut server),
        vec![SyncOpKind::List, SyncOpKind::List]
    );
    assert_eq!(
        b.sync(&mut server),
        vec![SyncOpKind::List, SyncOpKind::List]
    );
}

#[test]
fn edits_made_offline_upload_later() {
    let mut server = Dropbox::new();
    let (mut a, mut b) = two_synced_devices(&mut server);
    a.online = false;
    let edited = "[Event \"Najdorf\"]\n\n1. e4 c5 2. Nf3 d6 *\n";
    a.edit("Najdorf.pgn", edited);
    a.sync(&mut server);
    assert!(matches!(a.engine.state(), SyncState::Offline { .. }));
    assert_eq!(a.engine.unsynced_files(), vec!["Najdorf.pgn".to_owned()]);
    // Still offline: nothing goes out before the retry time.
    let poll = a.engine.poll(a.now);
    assert!(poll.ops.is_empty());
    assert!(poll.wake_at.unwrap() > a.now);

    a.online = true;
    a.now = poll.wake_at.unwrap();
    let sent = a.run(&mut server);
    assert!(sent.contains(&SyncOpKind::Upload));
    assert!(!sent.contains(&SyncOpKind::Download));
    b.sync(&mut server);
    assert_eq!(b.local["Najdorf.pgn"], edited.as_bytes());
    // Taken as it is: no merge, no upload back.
    assert_eq!(server.files["Najdorf.pgn"].0, edited.as_bytes());
}

#[test]
fn two_devices_editing_at_once_keep_both_edits() {
    let mut server = Dropbox::new();
    let (mut a, mut b) = two_synced_devices(&mut server);
    a.edit(
        "Najdorf.pgn",
        "[Event \"Najdorf\"]\n\n1. e4 c5 2. Nf3 d6 *\n",
    );
    b.edit(
        "Najdorf.pgn",
        "[Event \"Najdorf\"]\n\n1. e4 c5 (1... e5 2. Nf3) 2. Nf3 *\n",
    );
    a.edit("Najdorf.otlog.jsonl", revlog_line(10));
    b.edit("Najdorf.otlog.jsonl", revlog_line(20));
    a.sync(&mut server);
    let sent = b.sync(&mut server);
    assert!(sent.contains(&SyncOpKind::Download));
    a.sync(&mut server);
    assert_eq!(a.local, b.local);
    assert_eq!(
        lines(&a.local["Najdorf.pgn"]),
        vec!["e4 c5 Nf3 d6".to_owned(), "e4 e5 Nf3".to_owned()]
    );
    let log = revlog::decode(&a.local["Najdorf.otlog.jsonl"]);
    assert_eq!(log.iter().map(|e| e.id).collect::<Vec<_>>(), vec![10, 20]);
    // Settled: another round sends no file.
    assert_eq!(
        a.sync(&mut server),
        vec![SyncOpKind::List, SyncOpKind::List]
    );
}

#[test]
fn a_conflicting_upload_downloads_merges_and_retries() {
    let mut server = Dropbox::new();
    let (mut a, mut b) = two_synced_devices(&mut server);
    a.edit(
        "Najdorf.pgn",
        "[Event \"Najdorf\"]\n\n1. e4 c5 2. Nf3 d6 *\n",
    );
    a.engine.sync_now();
    // A lists and gets its upload ready ...
    let upload = loop {
        let op = a.next().unwrap();
        if op.kind == SyncOpKind::Upload {
            break op;
        }
        a.answer(&mut server, &op);
    };
    // ... while B's edit lands first.
    b.edit(
        "Najdorf.pgn",
        "[Event \"Najdorf\"]\n\n1. e4 c5 2. Nf3 Nc6 *\n",
    );
    b.sync(&mut server);
    a.answer(&mut server, &upload);
    let sent = a.run(&mut server);
    assert_eq!(
        sent,
        vec![SyncOpKind::List, SyncOpKind::Download, SyncOpKind::Upload]
    );
    b.sync(&mut server);
    assert_eq!(a.local, b.local);
    assert_eq!(
        lines(&a.local["Najdorf.pgn"]),
        vec!["e4 c5 Nf3 Nc6".to_owned(), "e4 c5 Nf3 d6".to_owned()]
    );
}

#[test]
fn an_expired_token_is_refreshed_and_a_revoked_one_asks_to_sign_in() {
    let mut server = Dropbox::new();
    let (mut a, _) = two_synced_devices(&mut server);
    // The access token expires: refreshed, and the sync goes on.
    server.access = "access-2".into();
    a.edit(
        "Najdorf.pgn",
        "[Event \"Najdorf\"]\n\n1. e4 c5 2. Nf3 d6 *\n",
    );
    let sent = a.sync(&mut server);
    assert_eq!(sent[..2], [SyncOpKind::List, SyncOpKind::Refresh]);
    assert!(a.engine.unsynced_files().is_empty());
    assert_eq!(a.needs, None);

    // The user revokes the app: the refresh fails, the platform is asked to sign in.
    server.access = "access-3".into();
    server.refresh = "refresh-2".into();
    a.edit("Najdorf.pgn", E4);
    a.sync(&mut server);
    assert_eq!(a.needs, Some(AuthNeed::SignIn));
    assert_eq!(a.engine.state(), &SyncState::NeedsSignIn);
    assert_eq!(a.engine.poll(a.now).needs, Some(AuthNeed::SignIn));
    assert!(a.engine.poll(a.now).ops.is_empty());
    assert_eq!(a.engine.unsynced_files(), vec!["Najdorf.pgn".to_owned()]);

    // Signed in again: the edit made meanwhile goes up.
    a.needs = None;
    a.engine
        .set_credentials(Some("access-3".into()), None, Some("refresh-2".into()));
    a.sync(&mut server);
    assert_eq!(a.needs, None);
    assert_eq!(server.files["Najdorf.pgn"].0, E4.as_bytes());

    // Never signed in: nothing is sent.
    let mut engine = SyncEngine::dropbox("app-key", b"");
    engine.set_local_files(Vec::new());
    let poll = engine.poll(0);
    assert!(poll.ops.is_empty());
    assert_eq!(poll.needs, Some(AuthNeed::SignIn));
}

#[test]
fn a_file_deleted_on_one_device_is_deleted_on_the_other() {
    let mut server = Dropbox::new();
    let (mut a, mut b) = two_synced_devices(&mut server);
    a.remove("Najdorf.pgn");
    a.remove("Najdorf.otrep.json");
    let sent = a.sync(&mut server);
    assert_eq!(sent.iter().filter(|k| **k == SyncOpKind::Delete).count(), 2);
    assert!(server.files.is_empty());
    b.sync(&mut server);
    assert!(b.local.is_empty());
    assert!(a.engine.saved_state().len() < 60);
}

#[test]
fn an_edit_wins_over_a_deletion_elsewhere() {
    let mut server = Dropbox::new();
    let (mut a, mut b) = two_synced_devices(&mut server);
    a.remove("Najdorf.pgn");
    a.sync(&mut server);
    // B edited it meanwhile: uploaded again.
    let edited = "[Event \"Najdorf\"]\n\n1. e4 c5 2. Nf3 d6 *\n";
    b.edit("Najdorf.pgn", edited);
    b.sync(&mut server);
    assert_eq!(server.files["Najdorf.pgn"].0, edited.as_bytes());
    // And comes back on A.
    a.sync(&mut server);
    assert_eq!(a.local["Najdorf.pgn"], edited.as_bytes());

    // A deletes it, B changes it before A's delete goes out: it comes back on A.
    a.remove("Najdorf.pgn");
    b.edit("Najdorf.pgn", E4);
    b.sync(&mut server);
    a.sync(&mut server);
    assert_eq!(a.local["Najdorf.pgn"], E4.as_bytes());
}

#[test]
fn the_saved_state_survives_a_relaunch() {
    let mut server = Dropbox::new();
    let (a, _) = two_synced_devices(&mut server);
    let state = a.engine.saved_state();
    let mut engine = SyncEngine::dropbox("app-key", &state);
    engine.set_credentials(None, None, Some(REFRESH.into()));
    engine.set_local_files(a.local.clone().into_iter().collect());
    let mut a = Device { engine, ..a };
    let sent = a.sync(&mut server);
    assert_eq!(sent, vec![SyncOpKind::Refresh, SyncOpKind::List]);
    // A file deleted while the app was closed is deleted remotely.
    let mut local = a.local.clone();
    local.remove("Najdorf.otrep.json");
    let mut engine = SyncEngine::dropbox("app-key", &a.engine.saved_state());
    engine.set_credentials(None, None, Some(REFRESH.into()));
    engine.set_local_files(local.into_iter().collect());
    let mut a = Device { engine, ..a };
    a.sync(&mut server);
    assert!(!server.files.contains_key("Najdorf.otrep.json"));
    // Garbage state: start over (both sides merged once, nothing lost).
    let mut engine = SyncEngine::dropbox("app-key", b"{not json");
    engine.set_credentials(None, None, Some(REFRESH.into()));
    engine.set_local_files(a.local.clone().into_iter().collect());
    let mut a = Device { engine, ..a };
    a.sync(&mut server);
    assert_eq!(server.files["Najdorf.pgn"].0, E4.as_bytes());
}

#[test]
fn dropbox_long_polls_while_watching() {
    let mut server = Dropbox::new();
    let (mut a, mut b) = two_synced_devices(&mut server);
    a.engine.set_watching(true);
    let poll = a.engine.poll(a.now);
    let watch = poll
        .ops
        .iter()
        .find(|op| op.kind == SyncOpKind::Watch)
        .expect("a long poll")
        .clone();
    assert!(watch.request.timeout_secs.unwrap() > 480);
    b.edit(
        "Najdorf.pgn",
        "[Event \"Najdorf\"]\n\n1. e4 c5 2. Nf3 d6 *\n",
    );
    b.sync(&mut server);
    server.changed = true;
    let response = server.handle(&watch.request);
    a.engine.on_response(&watch, Some(&response), a.now);
    a.run(&mut server);
    assert_eq!(a.local, b.local);
}

#[test]
fn answers_that_make_no_sense_never_loop() {
    let mut server = Dropbox::new();
    let (mut a, _) = two_synced_devices(&mut server);
    a.edit("Najdorf.pgn", "[Event \"Najdorf\"]\n\n1. d4 *\n");
    a.engine.sync_now();
    let mut weird = [
        respond(200, "not json"),
        respond(409, r#"{"error_summary": "path/insufficient_space/"}"#),
        respond(503, ""),
        respond(429, ""),
        respond(200, "{}"),
    ]
    .into_iter();
    let mut now = 0;
    for _ in 0..40 {
        now += 400_000;
        let poll = a.engine.poll(now);
        for op in poll.ops {
            let response = weird.next().unwrap_or_else(|| server.handle(&op.request));
            a.engine.on_response(&op, Some(&response), now);
        }
    }
    a.now = now;
    a.sync(&mut server);
    assert_eq!(
        server.files["Najdorf.pgn"].0,
        b"[Event \"Najdorf\"]\n\n1. d4 *\n"
    );
    // A stale answer (an op not in flight) is ignored.
    let stale = SyncOp {
        id: 999,
        kind: SyncOpKind::Upload,
        file: None,
        request: HttpRequest::get("https://x"),
    };
    assert_eq!(
        a.engine.on_response(&stale, Some(&respond(200, "{}")), now),
        SyncOutcome::default()
    );
}

#[test]
fn drive_makes_its_folder_and_uploads_conditionally() {
    let mut server = Drive {
        access: TOKEN.into(),
        ..Drive::default()
    };
    let mut a = Device::drive();
    a.edit("Najdorf.pgn", E4);
    a.edit("Najdorf.otrep.json", sidecar("n"));
    let sent = a.sync(&mut server);
    assert_eq!(
        sent[..2],
        [SyncOpKind::FindFolder, SyncOpKind::CreateFolder]
    );
    assert_eq!(server.files.len(), 2);

    let mut b = Device::drive();
    let sent = b.sync(&mut server);
    assert_eq!(sent[0], SyncOpKind::FindFolder);
    assert_eq!(b.local, a.local);

    // Both edit: the second upload's If-Match fails, it merges and retries.
    a.edit(
        "Najdorf.pgn",
        "[Event \"Najdorf\"]\n\n1. e4 c5 2. Nf3 d6 *\n",
    );
    b.edit(
        "Najdorf.pgn",
        "[Event \"Najdorf\"]\n\n1. e4 c5 2. Nf3 Nc6 *\n",
    );
    a.sync(&mut server);
    b.sync(&mut server);
    a.sync(&mut server);
    assert_eq!(a.local, b.local);
    assert_eq!(
        lines(&a.local["Najdorf.pgn"]),
        vec!["e4 c5 Nf3 Nc6".to_owned(), "e4 c5 Nf3 d6".to_owned()]
    );

    // An expired token: the platform is asked for a new one.
    server.access = "access-2".into();
    a.edit("Najdorf.pgn", E4);
    a.sync(&mut server);
    assert_eq!(a.needs, Some(AuthNeed::Token));
    assert_eq!(a.engine.state(), &SyncState::NeedsToken);
    a.needs = None;
    a.engine
        .set_credentials(Some("access-2".into()), Some(a.now + 3_600_000), None);
    a.sync(&mut server);
    assert!(a.engine.unsynced_files().is_empty());

    // Deleted on A: trashed, and gone from B.
    a.remove("Najdorf.otrep.json");
    a.sync(&mut server);
    assert_eq!(server.files.len(), 1);
    b.engine
        .set_credentials(Some("access-2".into()), None, None);
    b.sync(&mut server);
    assert!(!b.local.contains_key("Najdorf.otrep.json"));
}
