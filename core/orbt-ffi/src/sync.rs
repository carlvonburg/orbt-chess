use std::sync::{Arc, Mutex};

use crate::stats::SignInError;
use orbt_core::http::{HttpRequest, HttpResponse};
use orbt_core::sync::dropbox::{self, Dropbox};
use orbt_core::sync::{
    self, AuthNeed, FileKind, LocalWrite, SyncEngine, SyncOp, SyncOpKind, SyncOutcome, SyncPoll,
    SyncState,
};

#[uniffi::remote(Enum)]
pub enum FileKind {
    Pgn,
    Sidecar,
    Revlog,
}

#[uniffi::remote(Enum)]
pub enum AuthNeed {
    Token,
    SignIn,
}

#[uniffi::remote(Enum)]
pub enum SyncState {
    Idle,
    Syncing,
    Offline { until: i64 },
    Paused { until: i64 },
    NeedsToken,
    NeedsSignIn,
}

#[uniffi::remote(Enum)]
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

#[uniffi::remote(Record)]
pub struct SyncOp {
    pub id: u64,
    pub kind: SyncOpKind,
    pub file: Option<String>,
    pub request: HttpRequest,
}

#[uniffi::remote(Record)]
pub struct SyncPoll {
    pub ops: Vec<SyncOp>,
    pub wake_at: Option<i64>,
    pub needs: Option<AuthNeed>,
}

#[uniffi::remote(Record)]
pub struct LocalWrite {
    pub name: String,
    pub data: Vec<u8>,
    pub created: bool,
}

#[uniffi::remote(Record)]
pub struct SyncOutcome {
    pub writes: Vec<LocalWrite>,
    pub deletes: Vec<String>,
    pub needs: Option<AuthNeed>,
    pub save_state: bool,
}

#[derive(uniffi::Record)]
pub struct LocalFile {
    pub name: String,
    pub data: Vec<u8>,
}

/// Told when there is syncing to do: call `RepertoireSync::poll`.
#[uniffi::export(with_foreign)]
pub trait SyncListener: Send + Sync {
    fn wake(&self);
}

/// What signing in to Dropbox gives: keep the refresh token (the core refreshes with it).
#[derive(uniffi::Record)]
pub struct DropboxSignIn {
    pub access_token: String,
    /// Unix ms; None when Dropbox did not say.
    pub expires_at: Option<i64>,
    pub refresh_token: String,
    /// `dbid:…`: whether a new sign-in is the same account.
    pub account_id: Option<String>,
}

fn dropbox(app_key: String) -> Dropbox {
    Dropbox { app_key }
}

/// The apps' redirect from Dropbox (registered in its app console).
#[uniffi::export]
pub fn dropbox_redirect_uri() -> String {
    dropbox::REDIRECT_URI.to_owned()
}

/// Dropbox's sign-in page (PKCE, for a refresh token), redirecting to `redirect_uri`. Read the
/// redirect with `oauth_parse_redirect`.
#[uniffi::export]
pub fn dropbox_authorize_url(
    app_key: String,
    verifier: String,
    state: String,
    redirect_uri: String,
) -> String {
    dropbox(app_key).authorize_url(&verifier, &state, &redirect_uri)
}

/// Exchanges the code from the redirect for the tokens (`redirect_uri`: the authorize URL's).
#[uniffi::export]
pub fn dropbox_token_request(
    app_key: String,
    code: String,
    verifier: String,
    redirect_uri: String,
) -> HttpRequest {
    dropbox(app_key).token_request(&code, &verifier, &redirect_uri)
}

/// The token request's answer (`now_ms`: unix ms).
#[uniffi::export]
pub fn dropbox_parse_token(
    response: HttpResponse,
    now_ms: i64,
) -> Result<DropboxSignIn, SignInError> {
    let s = dropbox::read_token(&response, now_ms)?;
    Ok(DropboxSignIn {
        access_token: s.access_token,
        expires_at: s.expires_at,
        refresh_token: s.refresh_token,
        account_id: s.account_id,
    })
}

/// The signed-in account, for its email (`dropbox_parse_account`).
#[uniffi::export]
pub fn dropbox_account_request(access_token: String) -> HttpRequest {
    dropbox::account_request(&access_token)
}

#[uniffi::export]
pub fn dropbox_parse_account(response: HttpResponse) -> Option<String> {
    dropbox::read_account(&response)
}

/// The kind of a file the sync handles, or None for any other file.
#[uniffi::export]
pub fn sync_file_kind(name: String) -> Option<FileKind> {
    sync::file_kind(&name)
}

/// The repertoire folder synced with Dropbox or Google Drive: the platform sends the requests
/// `poll` hands out, passes the answers to `on_response` and applies the outcome to its files
/// (see `orbt_core::sync`).
#[derive(uniffi::Object)]
pub struct RepertoireSync {
    engine: Mutex<SyncEngine>,
    listener: Mutex<Option<Arc<dyn SyncListener>>>,
}

impl RepertoireSync {
    fn with(engine: SyncEngine) -> Arc<RepertoireSync> {
        Arc::new(RepertoireSync {
            engine: Mutex::new(engine),
            listener: Mutex::new(None),
        })
    }

    fn update<R>(&self, f: impl FnOnce(&mut SyncEngine) -> R) -> R {
        let result = f(&mut self.engine.lock().expect("sync lock"));
        let listener = self.listener.lock().expect("listener lock").clone();
        if let Some(l) = listener {
            l.wake();
        }
        result
    }
}

#[uniffi::export]
impl RepertoireSync {
    /// Dropbox's App folder; `app_key` is the OAuth client id. `saved_state`: what
    /// `saved_state` returned last time (empty to start over).
    #[uniffi::constructor]
    pub fn dropbox(app_key: String, saved_state: Vec<u8>) -> Arc<RepertoireSync> {
        RepertoireSync::with(SyncEngine::dropbox(&app_key, &saved_state))
    }

    /// The "ORBT Chess" folder in Google Drive (`drive.file` scope).
    #[uniffi::constructor]
    pub fn drive(saved_state: Vec<u8>) -> Arc<RepertoireSync> {
        RepertoireSync::with(SyncEngine::drive(&saved_state))
    }

    pub fn set_listener(&self, listener: Arc<dyn SyncListener>) {
        *self.listener.lock().expect("listener lock") = Some(listener);
    }

    /// Persist this when an outcome says `save_state` (no secrets in it).
    pub fn saved_state(&self) -> Vec<u8> {
        self.engine.lock().expect("sync lock").saved_state()
    }

    pub fn state(&self) -> SyncState {
        self.engine.lock().expect("sync lock").state().clone()
    }

    /// Files whose local version is not uploaded yet.
    pub fn unsynced_files(&self) -> Vec<String> {
        self.engine.lock().expect("sync lock").unsynced_files()
    }

    /// After signing in, or a fresh token (`expires_at` in unix ms, None when unknown: the
    /// token is used until refused, then `AuthNeed::Token` asks for another). Dropbox: pass
    /// the refresh token, the core refreshes the access token itself.
    pub fn set_credentials(
        &self,
        access_token: Option<String>,
        expires_at: Option<i64>,
        refresh_token: Option<String>,
    ) {
        self.update(|e| e.set_credentials(access_token, expires_at, refresh_token));
    }

    /// Every file of the local folder, once at start.
    pub fn set_local_files(&self, files: Vec<LocalFile>) {
        self.update(|e| e.set_local_files(files.into_iter().map(|f| (f.name, f.data)).collect()));
    }

    /// A local file was written (`data`) or deleted (None), saves of open repertoires included.
    pub fn local_changed(&self, name: String, data: Option<Vec<u8>>) {
        self.update(|e| e.local_changed(&name, data));
    }

    /// On open and on focus: look for changes from other devices.
    pub fn sync_now(&self) {
        self.update(SyncEngine::sync_now);
    }

    /// Long-poll for changes (Dropbox) while the app is in front.
    pub fn set_watching(&self, watching: bool) {
        self.update(|e| e.set_watching(watching));
    }

    /// The network is back.
    pub fn resume(&self) {
        self.update(SyncEngine::resume);
    }

    /// Signing out: the next request that revokes the sign-in on the provider's side (Dropbox),
    /// or None when none is left. Send each and pass its answer to `on_sign_out_response`
    /// until None (best effort: stop when offline). From the first call nothing else is sent.
    pub fn sign_out_request(&self, now_ms: i64) -> Option<HttpRequest> {
        self.engine
            .lock()
            .expect("sync lock")
            .sign_out_request(now_ms)
    }

    /// The answer to `sign_out_request`'s request (None: none came).
    pub fn on_sign_out_response(&self, response: Option<HttpResponse>, now_ms: i64) {
        self.engine
            .lock()
            .expect("sync lock")
            .on_sign_out_response(response.as_ref(), now_ms);
    }

    /// The requests to send now, and when to poll again.
    pub fn poll(&self, now_ms: i64) -> SyncPoll {
        self.engine.lock().expect("sync lock").poll(now_ms)
    }

    /// The answer to an op (`response` None: no answer, e.g. offline). Apply the outcome:
    /// write and delete the local files (an open repertoire's through its document:
    /// `remote_pgn`, `remote_sidecar`), persist the state when asked.
    pub fn on_response(
        &self,
        op: SyncOp,
        response: Option<HttpResponse>,
        now_ms: i64,
    ) -> SyncOutcome {
        self.update(|e| e.on_response(&op, response.as_ref(), now_ms))
    }
}
