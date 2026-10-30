//! Dropbox's HTTP API v2 in the App folder (`Apps/ORBT Chess`): paths are relative to it.
//! Sign-in is PKCE with `token_access_type=offline` (`authorize_url`, `token_request`,
//! `read_token`); the core refreshes the access token with the refresh token from then on,
//! and signing out revokes it (`auth/token/revoke`).

use serde::Deserialize;
use serde_json::json;

use super::Millis;
use super::provider::{
    Answer, Downloaded, Listing, Provider, RemoteFile, Replacing, Stored, Watched, ascii_json,
};
use crate::http::{HttpMethod, HttpRequest, HttpResponse, query_encode};
use crate::oauth::{code_challenge, form};

const API: &str = "https://api.dropboxapi.com";
const WWW: &str = "https://www.dropbox.com";
/// The apps' redirect, registered in Dropbox's app console.
pub const REDIRECT_URI: &str = "org.orbtchess.orbt://dropbox-callback";
const CONTENT: &str = "https://content.dropboxapi.com";
const NOTIFY: &str = "https://notify.dropboxapi.com";
/// Dropbox waits up to this long, plus up to 90 s of its own.
const WATCH_SECS: u32 = 480;
const TIMEOUT_SECS: u32 = 60;

#[derive(Clone, Debug)]
pub struct Dropbox {
    /// The app key (the OAuth client id).
    pub app_key: String,
}

#[derive(Deserialize)]
struct Entry {
    #[serde(rename = ".tag")]
    tag: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    rev: Option<String>,
}

#[derive(Deserialize)]
struct ListAnswer {
    entries: Vec<Entry>,
    cursor: String,
    has_more: bool,
}

#[derive(Deserialize)]
struct Metadata {
    name: String,
    rev: String,
}

#[derive(Deserialize)]
struct TokenAnswer {
    access_token: String,
    expires_in: Option<i64>,
}

#[derive(Deserialize)]
struct WatchAnswer {
    changes: bool,
    backoff: Option<i64>,
}

fn path(name: &str) -> String {
    format!("/{name}")
}

fn rpc(token: &str, endpoint: &str, arg: serde_json::Value) -> HttpRequest {
    HttpRequest::new(HttpMethod::Post, format!("{API}/2/{endpoint}"))
        .bearer(token)
        .body("application/json", arg.to_string())
        .timeout(TIMEOUT_SECS)
}

fn error_summary(r: &HttpResponse) -> String {
    serde_json::from_slice::<serde_json::Value>(&r.body)
        .ok()
        .and_then(|v| v.get("error_summary")?.as_str().map(str::to_owned))
        .unwrap_or_default()
}

/// The answer to a file request: 409 is Dropbox's endpoint-specific error.
fn read<T>(r: &HttpResponse, ok: impl FnOnce(&HttpResponse) -> Option<T>) -> Answer<T> {
    if let Some(common) = Answer::common(r) {
        return common;
    }
    match r.status {
        200 => ok(r).map_or(Answer::Failed, Answer::Ok),
        409 => {
            let summary = error_summary(r);
            if summary.contains("not_found") {
                Answer::NotFound
            } else if summary.contains("conflict") {
                Answer::Conflict
            } else {
                Answer::Failed
            }
        }
        _ => Answer::Failed,
    }
}

/// What signing in gives: the refresh token is what to keep (the core refreshes with it).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignIn {
    pub access_token: String,
    /// Unix ms; None when the answer did not say.
    pub expires_at: Option<Millis>,
    pub refresh_token: String,
    /// Dropbox's account id (`dbid:…`): tells whether a new sign-in is the same account.
    pub account_id: Option<String>,
}

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum SignInError {
    #[error("Dropbox refused the sign-in ({0})")]
    Refused(String),
    #[error("Dropbox's answer to the sign-in could not be read")]
    BadAnswer,
}

#[derive(Deserialize)]
struct SignInAnswer {
    access_token: String,
    expires_in: Option<i64>,
    refresh_token: String,
    account_id: Option<String>,
}

impl Dropbox {
    /// The page that asks the user to allow access to the App folder, for a refresh token
    /// (`token_access_type=offline`), redirecting to `redirect_uri` (read the redirect with
    /// `oauth::parse_redirect`).
    pub fn authorize_url(&self, verifier: &str, state: &str, redirect_uri: &str) -> String {
        let challenge = code_challenge(verifier);
        let query = form(&[
            ("client_id", &self.app_key),
            ("response_type", "code"),
            ("token_access_type", "offline"),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("redirect_uri", redirect_uri),
            ("state", state),
        ]);
        format!("{WWW}/oauth2/authorize?{query}")
    }

    /// Exchanges the code from the redirect for a refresh token and a first access token.
    pub fn token_request(&self, code: &str, verifier: &str, redirect_uri: &str) -> HttpRequest {
        let body = form(&[
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", verifier),
            ("client_id", &self.app_key),
            ("redirect_uri", redirect_uri),
        ]);
        HttpRequest::new(HttpMethod::Post, format!("{API}/oauth2/token"))
            .body("application/x-www-form-urlencoded", body)
            .timeout(TIMEOUT_SECS)
    }
}

/// The token request's answer (`now`: unix ms).
pub fn read_token(r: &HttpResponse, now: Millis) -> Result<SignIn, SignInError> {
    if r.status != 200 {
        let reason = serde_json::from_slice::<serde_json::Value>(&r.body)
            .ok()
            .and_then(|v| {
                let text = v.get("error_description").or_else(|| v.get("error"))?;
                text.as_str().map(str::to_owned)
            })
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| format!("error {}", r.status));
        return Err(SignInError::Refused(reason));
    }
    let a: SignInAnswer = serde_json::from_slice(&r.body).map_err(|_| SignInError::BadAnswer)?;
    if a.access_token.is_empty() || a.refresh_token.is_empty() {
        return Err(SignInError::BadAnswer);
    }
    Ok(SignIn {
        access_token: a.access_token,
        expires_at: a
            .expires_in
            .filter(|&s| s > 0)
            .map(|s| now + s.min(1 << 31) * 1000),
        refresh_token: a.refresh_token,
        account_id: a.account_id,
    })
}

/// The signed-in account, for its email (shown in Settings).
pub fn account_request(access_token: &str) -> HttpRequest {
    HttpRequest::new(
        HttpMethod::Post,
        format!("{API}/2/users/get_current_account"),
    )
    .bearer(access_token)
    .timeout(TIMEOUT_SECS)
}

/// The email from the account request's answer.
pub fn read_account(r: &HttpResponse) -> Option<String> {
    #[derive(Deserialize)]
    struct Account {
        email: String,
    }
    if r.status != 200 {
        return None;
    }
    serde_json::from_slice::<Account>(&r.body)
        .ok()
        .map(|a| a.email)
        .filter(|e| !e.is_empty())
}

/// Disables the access token and, with it, the refresh token it came from (signing out).
pub fn revoke_request(access_token: &str) -> HttpRequest {
    HttpRequest::new(HttpMethod::Post, format!("{API}/2/auth/token/revoke"))
        .bearer(access_token)
        .timeout(TIMEOUT_SECS)
}

impl Provider for Dropbox {
    fn refresh(&self, refresh_token: &str) -> Option<HttpRequest> {
        let form = format!(
            "grant_type=refresh_token&refresh_token={}&client_id={}",
            query_encode(refresh_token),
            query_encode(&self.app_key)
        );
        Some(
            HttpRequest::new(HttpMethod::Post, format!("{API}/oauth2/token"))
                .body("application/x-www-form-urlencoded", form)
                .timeout(TIMEOUT_SECS),
        )
    }

    fn read_refresh(&self, r: &HttpResponse) -> Answer<(String, Option<i64>)> {
        match r.status {
            200 => serde_json::from_slice::<TokenAnswer>(&r.body)
                .ok()
                .map_or(Answer::Failed, |t| {
                    Answer::Ok((t.access_token, t.expires_in))
                }),
            // invalid_grant: the refresh token was revoked.
            400 | 401 => Answer::Unauthorized,
            _ => Answer::common(r).unwrap_or(Answer::Failed),
        }
    }

    fn revoke(&self, token: &str) -> Option<HttpRequest> {
        Some(revoke_request(token))
    }

    fn find_folder(&self, _token: &str) -> Option<HttpRequest> {
        None
    }

    fn read_find_folder(&self, _r: &HttpResponse) -> Answer<Option<String>> {
        Answer::Ok(Some(String::new()))
    }

    fn create_folder(&self, token: &str) -> HttpRequest {
        rpc(token, "files/list_folder", json!({"path": ""}))
    }

    fn read_create_folder(&self, _r: &HttpResponse) -> Answer<String> {
        Answer::Ok(String::new())
    }

    fn list(&self, token: &str, _folder: &str, page: Option<&str>) -> HttpRequest {
        match page {
            Some(cursor) => rpc(
                token,
                "files/list_folder/continue",
                json!({"cursor": cursor}),
            ),
            None => rpc(
                token,
                "files/list_folder",
                json!({"path": "", "recursive": false, "include_deleted": false}),
            ),
        }
    }

    fn read_list(&self, r: &HttpResponse) -> Answer<Listing> {
        read(r, |r| {
            let answer: ListAnswer = serde_json::from_slice(&r.body).ok()?;
            Some(Listing {
                files: answer
                    .entries
                    .into_iter()
                    .filter(|e| e.tag == "file")
                    .filter_map(|e| {
                        Some(RemoteFile {
                            id: path(&e.name),
                            rev: e.rev?,
                            name: e.name,
                        })
                    })
                    .collect(),
                next_page: answer.has_more.then(|| answer.cursor.clone()),
                cursor: (!answer.has_more).then_some(answer.cursor),
            })
        })
    }

    fn download(&self, token: &str, file: &RemoteFile) -> HttpRequest {
        HttpRequest::new(HttpMethod::Post, format!("{CONTENT}/2/files/download"))
            .bearer(token)
            .header("Dropbox-API-Arg", ascii_json(&json!({"path": file.id})))
            .timeout(TIMEOUT_SECS)
    }

    fn read_download(&self, r: &HttpResponse) -> Answer<Downloaded> {
        read(r, |r| {
            let rev = r
                .header("Dropbox-API-Result")
                .and_then(|h| serde_json::from_str::<Metadata>(h).ok())
                .map(|m| m.rev);
            Some(Downloaded {
                data: r.body.clone(),
                rev,
                etag: None,
            })
        })
    }

    fn upload(
        &self,
        token: &str,
        _folder: &str,
        name: &str,
        data: &[u8],
        replacing: Option<Replacing<'_>>,
    ) -> Option<HttpRequest> {
        let mode = match replacing {
            Some(r) => json!({".tag": "update", "update": r.file.rev}),
            None => json!({".tag": "add"}),
        };
        let arg = json!({
            "path": replacing.map_or_else(|| path(name), |r| r.file.id.clone()),
            "mode": mode,
            "autorename": false,
            "mute": true,
            "strict_conflict": true,
        });
        Some(
            HttpRequest::new(HttpMethod::Post, format!("{CONTENT}/2/files/upload"))
                .bearer(token)
                .header("Dropbox-API-Arg", ascii_json(&arg))
                .body("application/octet-stream", data)
                .timeout(TIMEOUT_SECS),
        )
    }

    fn read_upload(&self, r: &HttpResponse) -> Answer<Stored> {
        read(r, |r| {
            let m: Metadata = serde_json::from_slice(&r.body).ok()?;
            Some(Stored {
                file: RemoteFile {
                    id: path(&m.name),
                    name: m.name,
                    rev: m.rev,
                },
                etag: None,
            })
        })
    }

    fn delete(&self, token: &str, file: Replacing<'_>) -> HttpRequest {
        rpc(
            token,
            "files/delete_v2",
            json!({"path": file.file.id, "parent_rev": file.file.rev}),
        )
    }

    fn read_delete(&self, r: &HttpResponse) -> Answer<()> {
        read(r, |_| Some(()))
    }

    fn watch(&self, cursor: &str) -> Option<HttpRequest> {
        // No token: the cursor is the credential.
        Some(
            HttpRequest::new(
                HttpMethod::Post,
                format!("{NOTIFY}/2/files/list_folder/longpoll"),
            )
            .body(
                "application/json",
                json!({"cursor": cursor, "timeout": WATCH_SECS}).to_string(),
            )
            .timeout(WATCH_SECS + 120),
        )
    }

    fn read_watch(&self, r: &HttpResponse) -> Answer<Watched> {
        if let Some(common) = Answer::common(r) {
            return common;
        }
        match r.status {
            200 => {
                serde_json::from_slice::<WatchAnswer>(&r.body)
                    .ok()
                    .map_or(Answer::Failed, |w| {
                        Answer::Ok(Watched {
                            changes: w.changes,
                            backoff_ms: w.backoff.unwrap_or(0).clamp(0, 3600) * 1000,
                        })
                    })
            }
            // The cursor was reset: list again.
            _ => Answer::Failed,
        }
    }
}
