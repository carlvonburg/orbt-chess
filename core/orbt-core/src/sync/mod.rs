//! Syncing the repertoire folder with a storage provider (Dropbox, Google Drive) as a state
//! machine (sans-IO), shaped like the explorer queue: the platform sends the requests `poll`
//! hands out and reports each answer to `on_response`; it calls `poll` again at `wake_at` or
//! after any event.
//!
//! Every file of a repertoire syncs on its own: the PGN, the sidecar `<Name>.otrep.json` and
//! the review log `<Name>.otlog.jsonl`. For each, the engine keeps the last remote version this
//! device took in (`Base`: its rev and content hash). A full listing says which files changed
//! remotely (rev), the platform's reports say which changed locally (hash):
//! - only local: upload, conditional on the base rev (Dropbox `update` mode, Drive `If-Match`);
//! - only remote: download and take it as it is (so deletions of lines carry over);
//! - both, or no base: download and merge with the core's merges (the PGN's tree union, as for
//!   an iCloud conflict version; `Sidecar::merged`; the review log's union by id), write the
//!   result locally and upload it. A conflicting upload (409/412) downloads again.
//!
//! The platform writes `Outcome::writes` to the local files; for an open repertoire it also
//! hands them to the document (`remote_pgn`, `remote_sidecar`), as it does for an iCloud
//! change, and reports the document's saves with `local_changed`. A file deleted remotely is
//! deleted locally unless it changed here (then it is uploaded again); one deleted here is
//! deleted remotely (Drive: to the trash) unless it changed there (then it comes back).
//! Edits made offline upload later. One request at a time, plus Dropbox's long poll while
//! `set_watching(true)`.

pub mod drive;
pub mod dropbox;
pub mod provider;

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::formats::{Sidecar, revlog};
use crate::http::{HttpRequest, HttpResponse};
use crate::repertoire::RepertoireTree;
use provider::{Answer, Provider, RemoteFile, Replacing};

/// Milliseconds since 1970.
pub type Millis = i64;

const OFFLINE_RETRY_MS: Millis = 30_000;
const DEFAULT_PAUSE_MS: Millis = 60_000;
const UNAVAILABLE_PAUSE_MS: Millis = 30_000;
const FAILED_PAUSE_MS: Millis = 300_000;
/// Refresh the access token this long before it expires.
const TOKEN_MARGIN_MS: Millis = 60_000;
const STATE_VERSION: i64 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileKind {
    Pgn,
    Sidecar,
    Revlog,
}

/// The kind of a file the sync handles, by its name; None for any other file.
pub fn file_kind(name: &str) -> Option<FileKind> {
    if name.contains(['/', '\\']) || name.starts_with('.') {
        return None;
    }
    let kinds = [
        (".pgn", FileKind::Pgn),
        (SIDECAR_SUFFIX, FileKind::Sidecar),
        (REVLOG_SUFFIX, FileKind::Revlog),
    ];
    kinds.into_iter().find_map(|(suffix, kind)| {
        (name.len() > suffix.len() && name.ends_with(suffix)).then_some(kind)
    })
}

const SIDECAR_SUFFIX: &str = ".otrep.json";
const REVLOG_SUFFIX: &str = ".otlog.jsonl";

/// The content hash the engine compares versions by (hex SHA-256, first 16 bytes).
pub fn content_hash(data: &[u8]) -> String {
    Sha256::digest(data)[..16]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Both versions of a file in one: the PGN's move trees united (the local header kept), the
/// sidecars merged (`Sidecar::merged`), the review logs united by id. An unreadable sidecar
/// gives way to the readable one.
pub fn merge(kind: FileKind, local: &[u8], remote: &[u8]) -> Vec<u8> {
    match kind {
        FileKind::Pgn => {
            let mut tree = RepertoireTree::from_pgn(&String::from_utf8_lossy(local));
            tree.merge_tree(&RepertoireTree::from_pgn(&String::from_utf8_lossy(remote)));
            tree.pgn_text().into_bytes()
        }
        FileKind::Sidecar => match (Sidecar::decode(local), Sidecar::decode(remote)) {
            (Ok(l), Ok(r)) => l.merged(&r).encoded(),
            (Err(_), Ok(_)) => remote.to_vec(),
            _ => local.to_vec(),
        },
        FileKind::Revlog => revlog::encode(&revlog::merged(
            &revlog::decode(local),
            &revlog::decode(remote),
        )),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthNeed {
    /// Get a fresh access token and pass it to `set_credentials` (Drive: from the system).
    Token,
    /// The sign-in was revoked or expired for good: sign in again.
    SignIn,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncState {
    Idle,
    Syncing,
    Offline {
        until: Millis,
    },
    /// Rate limited or the provider failed: waiting.
    Paused {
        until: Millis,
    },
    NeedsToken,
    NeedsSignIn,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncOpKind {
    Refresh,
    FindFolder,
    CreateFolder,
    List,
    Download,
    Upload,
    Delete,
    Watch,
}

/// A request for the platform to send.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncOp {
    pub id: u64,
    pub kind: SyncOpKind,
    /// The file it is about, for display.
    pub file: Option<String>,
    /// Send it as it is (it carries the token).
    pub request: HttpRequest,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SyncPoll {
    pub ops: Vec<SyncOp>,
    /// Call `poll` again at this time (or after any event).
    pub wake_at: Option<Millis>,
    /// Nothing is sent until this is dealt with.
    pub needs: Option<AuthNeed>,
}

/// A local file to write: a version from another device, or a merge with it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocalWrite {
    pub name: String,
    pub data: Vec<u8>,
    /// There was no local file (a repertoire created, or restored, on another device).
    pub created: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SyncOutcome {
    pub writes: Vec<LocalWrite>,
    /// Local files to delete: deleted on another device.
    pub deletes: Vec<String>,
    pub needs: Option<AuthNeed>,
    /// Persist `saved_state` (and pass it to `new` next launch).
    pub save_state: bool,
}

/// The last remote version this device took in.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Base {
    id: String,
    rev: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    etag: Option<String>,
    hash: String,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct SavedState {
    version: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    folder: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cursor: Option<String>,
    #[serde(default)]
    files: BTreeMap<String, Base>,
}

#[derive(Debug, Default)]
struct Entry {
    /// The local file's content; None: there is none.
    local: Option<Vec<u8>>,
    base: Option<Base>,
    /// The file in the latest listing.
    remote: Option<RemoteFile>,
    /// A conditional request failed: download before anything else.
    needs_download: bool,
    /// An answer this engine can't act on: left alone until the next `sync_now`.
    failed: bool,
}

impl Entry {
    fn local_hash(&self) -> Option<String> {
        self.local.as_deref().map(content_hash)
    }
}

#[derive(Clone, Debug)]
enum Pending {
    Refresh,
    FindFolder,
    CreateFolder,
    List,
    Download(String),
    /// The name and the hash of what was uploaded.
    Upload(String, String),
    Delete(String),
}

#[derive(Clone, Debug)]
enum Action {
    Download,
    Upload,
    Delete,
    Forget,
}

#[derive(Debug)]
struct Access {
    token: String,
    expires_at: Option<Millis>,
}

#[derive(Debug)]
pub struct SyncEngine {
    provider: Box<dyn Provider>,
    access: Option<Access>,
    refresh_token: Option<String>,
    needs: Option<AuthNeed>,
    /// 401s in a row: a second one right after a new token means it does not work.
    unauthorized: u32,
    folder: Option<String>,
    folder_missing: bool,
    cursor: Option<String>,
    files: BTreeMap<String, Entry>,
    /// The platform reported its local files (`set_local_files`): before that, a missing local
    /// file is no deletion.
    local_known: bool,
    list_due: bool,
    /// At least one full listing arrived: remote files can be compared.
    listed: bool,
    listing: Vec<RemoteFile>,
    list_page: Option<String>,
    in_flight: Option<(u64, Pending)>,
    watching: bool,
    watch_in_flight: Option<u64>,
    watch_after: Millis,
    offline_until: Option<Millis>,
    paused_until: Option<Millis>,
    state: SyncState,
    next_id: u64,
}

impl SyncEngine {
    /// `saved_state`: what `saved_state` returned last time (empty or unreadable: start over;
    /// files on both sides are then merged once).
    pub fn new(provider: Box<dyn Provider>, saved_state: &[u8]) -> SyncEngine {
        let saved: SavedState = serde_json::from_slice(saved_state)
            .ok()
            .filter(|s: &SavedState| s.version == STATE_VERSION)
            .unwrap_or_default();
        let files = saved
            .files
            .into_iter()
            .filter(|(name, _)| file_kind(name).is_some())
            .map(|(name, base)| {
                let entry = Entry {
                    base: Some(base),
                    ..Entry::default()
                };
                (name, entry)
            })
            .collect();
        SyncEngine {
            provider,
            access: None,
            refresh_token: None,
            needs: None,
            unauthorized: 0,
            folder: saved.folder,
            folder_missing: false,
            cursor: saved.cursor,
            files,
            local_known: false,
            list_due: true,
            listed: false,
            listing: Vec::new(),
            list_page: None,
            in_flight: None,
            watching: false,
            watch_in_flight: None,
            watch_after: 0,
            offline_until: None,
            paused_until: None,
            state: SyncState::Idle,
            next_id: 1,
        }
    }

    pub fn dropbox(app_key: &str, saved_state: &[u8]) -> SyncEngine {
        SyncEngine::new(
            Box::new(dropbox::Dropbox {
                app_key: app_key.to_owned(),
            }),
            saved_state,
        )
    }

    pub fn drive(saved_state: &[u8]) -> SyncEngine {
        SyncEngine::new(Box::new(drive::Drive), saved_state)
    }

    /// What to persist between launches (no secrets: tokens stay with the platform).
    pub fn saved_state(&self) -> Vec<u8> {
        let saved = SavedState {
            version: STATE_VERSION,
            folder: self.folder.clone(),
            cursor: self.cursor.clone(),
            files: self
                .files
                .iter()
                .filter_map(|(name, e)| Some((name.clone(), e.base.clone()?)))
                .collect(),
        };
        serde_json::to_vec(&saved).unwrap_or_default()
    }

    pub fn state(&self) -> &SyncState {
        &self.state
    }

    /// Files whose local version is not uploaded yet.
    pub fn unsynced_files(&self) -> Vec<String> {
        self.files
            .iter()
            .filter(|(_, e)| {
                e.local.is_some() && e.base.as_ref().map(|b| &b.hash) != e.local_hash().as_ref()
            })
            .map(|(name, _)| name.clone())
            .collect()
    }

    // Events

    /// After signing in, or a fresh token from the system. `expires_at`: unix ms;
    /// `refresh_token`: Dropbox's, which the core uses to get new access tokens (None keeps
    /// the one it has).
    pub fn set_credentials(
        &mut self,
        access_token: Option<String>,
        expires_at: Option<Millis>,
        refresh_token: Option<String>,
    ) {
        self.access = access_token.map(|token| Access { token, expires_at });
        if refresh_token.is_some() {
            self.refresh_token = refresh_token;
        }
        self.needs = None;
        if matches!(self.state, SyncState::NeedsToken | SyncState::NeedsSignIn) {
            self.state = SyncState::Idle;
        }
    }

    /// Every file in the local folder, once at start (others are ignored). Files the engine
    /// synced before and that are missing now were deleted here.
    pub fn set_local_files(&mut self, files: Vec<(String, Vec<u8>)>) {
        for entry in self.files.values_mut() {
            entry.local = None;
        }
        for (name, data) in files {
            if file_kind(&name).is_some() {
                self.files.entry(name).or_default().local = Some(data);
            }
        }
        self.local_known = true;
    }

    /// A local file was written (`Some`) or deleted (`None`).
    pub fn local_changed(&mut self, name: &str, data: Option<Vec<u8>>) {
        if file_kind(name).is_none() {
            return;
        }
        let entry = self.files.entry(name.to_owned()).or_default();
        entry.local = data;
        entry.failed = false;
    }

    /// Look for changes from other devices (on open, on focus) and retry what failed.
    pub fn sync_now(&mut self) {
        self.list_due = true;
        for entry in self.files.values_mut() {
            entry.failed = false;
        }
        self.paused_until = None;
        self.offline_until = None;
        self.watch_after = 0;
    }

    /// Long-poll for changes while the app is in front (Dropbox).
    pub fn set_watching(&mut self, watching: bool) {
        self.watching = watching;
    }

    /// The network is back.
    pub fn resume(&mut self) {
        self.offline_until = None;
        self.watch_after = 0;
        if matches!(self.state, SyncState::Offline { .. }) {
            self.state = SyncState::Idle;
        }
    }

    // Requests

    /// The core refreshes access tokens itself (Dropbox).
    fn can_refresh(&self) -> bool {
        self.provider.refresh("").is_some()
    }

    fn token_valid(&self, now: Millis) -> Option<&str> {
        self.access
            .as_ref()
            .filter(|a| a.expires_at.is_none_or(|t| t > now + TOKEN_MARGIN_MS))
            .map(|a| a.token.as_str())
    }

    fn next_file_action(&self) -> Option<(String, Action)> {
        if !self.local_known || !self.listed {
            return None;
        }
        self.files.iter().find_map(|(name, e)| {
            if e.failed {
                return None;
            }
            let local = e.local_hash();
            let action = match (&local, &e.remote, &e.base) {
                (_, Some(_), _) if e.needs_download => Action::Download,
                (None, None, _) => Action::Forget,
                (Some(_), None, None) => Action::Upload,
                // Deleted remotely: resolved when the listing came in; this one changed since.
                (Some(_), None, Some(_)) => Action::Upload,
                (_, Some(_), None) => Action::Download,
                (_, Some(r), Some(b)) if r.rev != b.rev => Action::Download,
                (None, Some(_), Some(_)) => Action::Delete,
                (Some(l), Some(_), Some(b)) if *l != b.hash => Action::Upload,
                _ => return None,
            };
            Some((name.clone(), action))
        })
    }

    fn next_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    fn pause(&mut self, now: Millis, ms: Millis) {
        let until = now + ms;
        self.paused_until = Some(until);
        self.state = SyncState::Paused { until };
    }

    /// The requests to send now, and when to poll again.
    pub fn poll(&mut self, now: Millis) -> SyncPoll {
        let mut poll = SyncPoll::default();
        if let Some(needs) = self.needs {
            poll.needs = Some(needs);
            return poll;
        }
        if let Some(until) = self.offline_until.filter(|&t| t > now) {
            self.state = SyncState::Offline { until };
            poll.wake_at = Some(until);
            return poll;
        }
        if let Some(until) = self.paused_until.filter(|&t| t > now) {
            self.state = SyncState::Paused { until };
            poll.wake_at = Some(until);
            return poll;
        }
        self.offline_until = None;
        self.paused_until = None;

        if self.in_flight.is_none() {
            // Files that need no request.
            while let Some((name, Action::Forget)) = self.next_file_action() {
                self.files.remove(&name);
            }
            let op = self.next_op(now);
            match op {
                Ok(Some(op)) => {
                    self.state = SyncState::Syncing;
                    poll.ops.push(op);
                }
                Ok(None) => self.state = SyncState::Idle,
                Err(needs) => {
                    self.needs = Some(needs);
                    self.state = match needs {
                        AuthNeed::Token => SyncState::NeedsToken,
                        AuthNeed::SignIn => SyncState::NeedsSignIn,
                    };
                    poll.needs = Some(needs);
                    return poll;
                }
            }
        }

        // Dropbox's long poll, beside the rest.
        if self.watching
            && self.watch_in_flight.is_none()
            && self.listed
            && !self.list_due
            && let Some(cursor) = &self.cursor
        {
            if self.watch_after > now {
                poll.wake_at = Some(self.watch_after);
            } else if let Some(request) = self.provider.watch(cursor) {
                let id = self.next_id();
                self.watch_in_flight = Some(id);
                poll.ops.push(SyncOp {
                    id,
                    kind: SyncOpKind::Watch,
                    file: None,
                    request,
                });
            }
        }
        poll
    }

    /// The next request of the main lane, or what the sign-in needs first.
    fn next_op(&mut self, now: Millis) -> Result<Option<SyncOp>, AuthNeed> {
        enum Work {
            Folder,
            List,
            File(String, Action),
        }
        let work = if self.folder.is_none() {
            Work::Folder
        } else if self.list_due {
            Work::List
        } else if let Some((name, action)) = self.next_file_action() {
            Work::File(name, action)
        } else {
            return Ok(None);
        };
        let Some(token) = self.token_valid(now).map(str::to_owned) else {
            let refresh = self
                .refresh_token
                .as_deref()
                .and_then(|t| self.provider.refresh(t));
            return match refresh {
                Some(request) => Ok(Some(self.send(Pending::Refresh, None, request))),
                // Dropbox without a refresh token: not signed in.
                None if self.can_refresh() => Err(AuthNeed::SignIn),
                None => Err(AuthNeed::Token),
            };
        };
        let folder = self.folder.clone().unwrap_or_default();
        let op = match work {
            Work::Folder => match self.provider.find_folder(&token) {
                None => {
                    self.folder = Some(String::new());
                    return self.next_op(now);
                }
                Some(_) if self.folder_missing => {
                    let request = self.provider.create_folder(&token);
                    self.send(Pending::CreateFolder, None, request)
                }
                Some(request) => self.send(Pending::FindFolder, None, request),
            },
            Work::List => {
                let request = self
                    .provider
                    .list(&token, &folder, self.list_page.as_deref());
                self.send(Pending::List, None, request)
            }
            Work::File(name, action) => {
                let Some(entry) = self.files.get(&name) else {
                    return Ok(None);
                };
                match action {
                    Action::Download => {
                        let Some(remote) = &entry.remote else {
                            return Ok(None);
                        };
                        let request = self.provider.download(&token, remote);
                        self.send(Pending::Download(name.clone()), Some(name), request)
                    }
                    Action::Upload => {
                        let data = entry.local.clone().unwrap_or_default();
                        let hash = content_hash(&data);
                        let replacing = match (&entry.remote, &entry.base) {
                            (Some(remote), Some(base)) => Some(Replacing {
                                file: remote,
                                etag: base.etag.as_deref(),
                            }),
                            _ => None,
                        };
                        match self
                            .provider
                            .upload(&token, &folder, &name, &data, replacing)
                        {
                            Some(request) => {
                                self.send(Pending::Upload(name.clone(), hash), Some(name), request)
                            }
                            None => {
                                // Not conditional without a download first.
                                if let Some(entry) = self.files.get_mut(&name) {
                                    entry.needs_download = true;
                                }
                                return self.next_op(now);
                            }
                        }
                    }
                    Action::Delete => {
                        let (Some(remote), Some(base)) = (&entry.remote, &entry.base) else {
                            return Ok(None);
                        };
                        let request = self.provider.delete(
                            &token,
                            Replacing {
                                file: remote,
                                etag: base.etag.as_deref(),
                            },
                        );
                        self.send(Pending::Delete(name.clone()), Some(name), request)
                    }
                    Action::Forget => return Ok(None),
                }
            }
        };
        Ok(Some(op))
    }

    fn send(&mut self, pending: Pending, file: Option<String>, request: HttpRequest) -> SyncOp {
        let id = self.next_id();
        let kind = match &pending {
            Pending::Refresh => SyncOpKind::Refresh,
            Pending::FindFolder => SyncOpKind::FindFolder,
            Pending::CreateFolder => SyncOpKind::CreateFolder,
            Pending::List => SyncOpKind::List,
            Pending::Download(_) => SyncOpKind::Download,
            Pending::Upload(..) => SyncOpKind::Upload,
            Pending::Delete(_) => SyncOpKind::Delete,
        };
        self.in_flight = Some((id, pending));
        SyncOp {
            id,
            kind,
            file,
            request,
        }
    }

    // Answers

    /// The answer to an op from `poll` (None: no answer, e.g. offline or a timeout).
    pub fn on_response(
        &mut self,
        op: &SyncOp,
        response: Option<&HttpResponse>,
        now: Millis,
    ) -> SyncOutcome {
        let mut outcome = SyncOutcome::default();
        if self.watch_in_flight == Some(op.id) {
            self.watch_in_flight = None;
            self.on_watch(response, now);
            return outcome;
        }
        let pending = match self.in_flight.take() {
            Some((id, pending)) if id == op.id => pending,
            other => {
                // An answer to nothing in flight (stale): ignore it.
                self.in_flight = other;
                return outcome;
            }
        };
        let Some(r) = response else {
            let until = now + OFFLINE_RETRY_MS;
            self.offline_until = Some(until);
            self.state = SyncState::Offline { until };
            return outcome;
        };
        match pending {
            Pending::Refresh => match self.provider.read_refresh(r) {
                Answer::Ok((token, expires_in)) => {
                    self.access = Some(Access {
                        token,
                        expires_at: expires_in.map(|s| now + s.clamp(0, 1 << 31) * 1000),
                    });
                }
                Answer::Unauthorized => self.need(AuthNeed::SignIn, &mut outcome),
                other => self.retry_later(other, now, &mut outcome),
            },
            Pending::FindFolder => match self.provider.read_find_folder(r) {
                Answer::Ok(Some(folder)) => self.set_folder(folder, &mut outcome),
                Answer::Ok(None) => self.folder_missing = true,
                other => self.retry_later(other, now, &mut outcome),
            },
            Pending::CreateFolder => match self.provider.read_create_folder(r) {
                Answer::Ok(folder) => self.set_folder(folder, &mut outcome),
                other => self.retry_later(other, now, &mut outcome),
            },
            Pending::List => match self.provider.read_list(r) {
                Answer::Ok(listing) => {
                    self.unauthorized = 0;
                    self.listing.extend(listing.files);
                    match listing.next_page {
                        Some(page) => self.list_page = Some(page),
                        None => {
                            self.list_page = None;
                            if listing.cursor.is_some() {
                                self.cursor = listing.cursor;
                            }
                            self.listing_complete(&mut outcome);
                        }
                    }
                }
                Answer::NotFound if self.provider.find_folder("").is_some() => {
                    // The app's folder is gone: find or make it again.
                    self.folder = None;
                    self.folder_missing = false;
                    self.restart_listing();
                }
                other => {
                    self.restart_listing();
                    self.retry_later(other, now, &mut outcome);
                }
            },
            Pending::Download(name) => {
                let answer = self.provider.read_download(r);
                self.on_download(&name, answer, now, &mut outcome);
            }
            Pending::Upload(name, hash) => {
                let answer = self.provider.read_upload(r);
                self.on_upload(&name, hash, answer, now, &mut outcome);
            }
            Pending::Delete(name) => match self.provider.read_delete(r) {
                Answer::Ok(()) | Answer::NotFound => {
                    self.unauthorized = 0;
                    if self.files.get(&name).is_some_and(|e| e.local.is_none()) {
                        self.files.remove(&name);
                    }
                    outcome.save_state = true;
                }
                Answer::Conflict => self.conflict(&name),
                other => self.file_failed(&name, other, now, &mut outcome),
            },
        }
        outcome
    }

    fn set_folder(&mut self, folder: String, outcome: &mut SyncOutcome) {
        self.unauthorized = 0;
        if self.folder.as_ref() != Some(&folder) {
            // Another folder: what was synced with the old one says nothing about it.
            for entry in self.files.values_mut() {
                entry.base = None;
                entry.remote = None;
            }
            self.cursor = None;
        }
        self.folder = Some(folder);
        self.folder_missing = false;
        outcome.save_state = true;
    }

    fn restart_listing(&mut self) {
        self.listing.clear();
        self.list_page = None;
    }

    fn listing_complete(&mut self, outcome: &mut SyncOutcome) {
        self.list_due = false;
        self.listed = true;
        let mut remote: BTreeMap<String, RemoteFile> = std::mem::take(&mut self.listing)
            .into_iter()
            .filter(|f| file_kind(&f.name).is_some())
            .map(|f| (f.name.clone(), f))
            .collect();
        for (name, entry) in self.files.iter_mut() {
            entry.remote = remote.remove(name);
        }
        for (name, file) in remote {
            self.files.insert(
                name,
                Entry {
                    remote: Some(file),
                    ..Entry::default()
                },
            );
        }
        // Deleted on another device.
        let local_known = self.local_known;
        let mut gone = Vec::new();
        for (name, entry) in self.files.iter_mut() {
            let Some(base) = &entry.base else { continue };
            if entry.remote.is_some() || !local_known {
                continue;
            }
            match entry.local_hash() {
                Some(hash) if hash == base.hash => gone.push(name.clone()),
                // Changed here since: upload it again.
                Some(_) => entry.base = None,
                None => gone.push(name.clone()),
            }
        }
        for name in gone {
            if self.files.remove(&name).is_some_and(|e| e.local.is_some()) {
                outcome.deletes.push(name);
            }
        }
        outcome.save_state = true;
    }

    fn on_download(
        &mut self,
        name: &str,
        answer: Answer<provider::Downloaded>,
        now: Millis,
        outcome: &mut SyncOutcome,
    ) {
        let downloaded = match answer {
            Answer::Ok(d) => d,
            Answer::NotFound => {
                self.list_due = true;
                if let Some(entry) = self.files.get_mut(name) {
                    entry.needs_download = false;
                    entry.remote = None;
                }
                return;
            }
            other => return self.file_failed(name, other, now, outcome),
        };
        self.unauthorized = 0;
        let Some(kind) = file_kind(name) else { return };
        let Some(entry) = self.files.get_mut(name) else {
            return;
        };
        let Some(remote) = &mut entry.remote else {
            return;
        };
        if let Some(rev) = downloaded.rev {
            remote.rev = rev;
        }
        let base = Base {
            id: remote.id.clone(),
            rev: remote.rev.clone(),
            etag: downloaded.etag,
            hash: content_hash(&downloaded.data),
        };
        let new_local = match &entry.local {
            None => Some(downloaded.data),
            Some(local) => {
                let unchanged = entry
                    .base
                    .as_ref()
                    .is_some_and(|b| b.hash == content_hash(local));
                let merged = if unchanged {
                    downloaded.data
                } else {
                    merge(kind, local, &downloaded.data)
                };
                (merged != *local).then_some(merged)
            }
        };
        if let Some(data) = new_local {
            outcome.writes.push(LocalWrite {
                name: name.to_owned(),
                data: data.clone(),
                created: entry.local.is_none(),
            });
            entry.local = Some(data);
        }
        entry.base = Some(base);
        entry.needs_download = false;
        outcome.save_state = true;
    }

    fn on_upload(
        &mut self,
        name: &str,
        hash: String,
        answer: Answer<provider::Stored>,
        now: Millis,
        outcome: &mut SyncOutcome,
    ) {
        match answer {
            Answer::Ok(stored) => {
                self.unauthorized = 0;
                let Some(entry) = self.files.get_mut(name) else {
                    return;
                };
                entry.base = Some(Base {
                    id: stored.file.id.clone(),
                    rev: stored.file.rev.clone(),
                    etag: stored.etag,
                    hash,
                });
                entry.remote = Some(stored.file);
                outcome.save_state = true;
            }
            Answer::Conflict => self.conflict(name),
            Answer::NotFound => {
                // Replaced a file deleted meanwhile: create it again.
                if let Some(entry) = self.files.get_mut(name) {
                    entry.remote = None;
                    entry.base = None;
                }
                self.list_due = true;
            }
            other => self.file_failed(name, other, now, outcome),
        }
    }

    /// Changed remotely since the version a request was conditional on.
    fn conflict(&mut self, name: &str) {
        if let Some(entry) = self.files.get_mut(name) {
            entry.needs_download = true;
        }
        self.list_due = true;
    }

    fn file_failed(
        &mut self,
        name: &str,
        answer: Answer<impl Sized>,
        now: Millis,
        outcome: &mut SyncOutcome,
    ) {
        if matches!(answer, Answer::Failed) {
            if let Some(entry) = self.files.get_mut(name) {
                entry.failed = true;
            }
        } else {
            self.retry_later(answer, now, outcome);
        }
    }

    /// An answer that is not the request's: retried after a pause or a new token.
    fn retry_later(&mut self, answer: Answer<impl Sized>, now: Millis, outcome: &mut SyncOutcome) {
        match answer {
            Answer::Unauthorized => {
                self.unauthorized += 1;
                let can_refresh = self.refresh_token.is_some() && self.can_refresh();
                if self.unauthorized >= 2 {
                    self.need(AuthNeed::SignIn, outcome);
                } else if can_refresh {
                    self.access = None;
                } else {
                    self.access = None;
                    self.need(AuthNeed::Token, outcome);
                }
            }
            Answer::RateLimited { retry_after_ms } => {
                self.pause(now, retry_after_ms.unwrap_or(DEFAULT_PAUSE_MS));
            }
            Answer::Unavailable => self.pause(now, UNAVAILABLE_PAUSE_MS),
            _ => self.pause(now, FAILED_PAUSE_MS),
        }
    }

    fn need(&mut self, needs: AuthNeed, outcome: &mut SyncOutcome) {
        self.needs = Some(needs);
        outcome.needs = Some(needs);
        self.state = match needs {
            AuthNeed::Token => SyncState::NeedsToken,
            AuthNeed::SignIn => SyncState::NeedsSignIn,
        };
    }

    fn on_watch(&mut self, response: Option<&HttpResponse>, now: Millis) {
        let Some(r) = response else {
            self.watch_after = now + OFFLINE_RETRY_MS;
            return;
        };
        match self.provider.read_watch(r) {
            Answer::Ok(watched) => {
                if watched.changes {
                    self.list_due = true;
                }
                self.watch_after = now + watched.backoff_ms;
            }
            Answer::RateLimited { retry_after_ms } => {
                self.watch_after = now + retry_after_ms.unwrap_or(DEFAULT_PAUSE_MS);
            }
            Answer::Unavailable => self.watch_after = now + UNAVAILABLE_PAUSE_MS,
            _ => {
                // The cursor is no good any more: list again for a new one.
                self.cursor = None;
                self.list_due = true;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::formats::SIDECAR_EXTENSION;

    #[test]
    fn suffixes_match_the_formats() {
        assert_eq!(SIDECAR_SUFFIX, format!(".{SIDECAR_EXTENSION}"));
        assert_eq!(REVLOG_SUFFIX, format!(".{}", revlog::FILE_EXTENSION));
        assert_eq!(file_kind("Najdorf.pgn"), Some(FileKind::Pgn));
        assert_eq!(file_kind("Najdorf.otrep.json"), Some(FileKind::Sidecar));
        assert_eq!(file_kind("Najdorf.otlog.jsonl"), Some(FileKind::Revlog));
        assert_eq!(file_kind(".pgn"), None);
        assert_eq!(file_kind("a/b.pgn"), None);
        assert_eq!(file_kind("notes.txt"), None);
    }

    #[test]
    fn header_json_is_ascii() {
        let v = serde_json::json!({"path": "/Réti 🐴.pgn"});
        let text = provider::ascii_json(&v);
        assert!(text.is_ascii());
        assert_eq!(serde_json::from_str::<serde_json::Value>(&text).unwrap(), v);
    }
}
