//! Dropbox's HTTP API v2 in the App folder (`Apps/ORBT Chess`): paths are relative to it.
//! Sign-in is PKCE with `token_access_type=offline`; the core refreshes the access token.

use serde::Deserialize;
use serde_json::json;

use super::provider::{
    Answer, Downloaded, Listing, Provider, RemoteFile, Replacing, Stored, Watched, ascii_json,
};
use crate::http::{HttpMethod, HttpRequest, HttpResponse, query_encode};

const API: &str = "https://api.dropboxapi.com";
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
