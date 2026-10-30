//! What a storage provider is to the sync loop: requests it builds and answers it reads.
//! Everything else (when to send what, merging) is the provider-neutral loop in `super`.

use crate::http::{HttpRequest, HttpResponse};

use super::Millis;

/// A file in the provider's folder.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RemoteFile {
    pub name: String,
    /// What the provider addresses the file by (Dropbox: its path; Drive: the file id).
    pub id: String,
    /// Changes whenever the content does (Dropbox: `rev`; Drive: `md5Checksum`).
    pub rev: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Listing {
    pub files: Vec<RemoteFile>,
    /// Another page follows: list again with this.
    pub next_page: Option<String>,
    /// Watch for changes after this listing (Dropbox's cursor).
    pub cursor: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Downloaded {
    pub data: Vec<u8>,
    /// The version downloaded, when the answer says (else the listing's).
    pub rev: Option<String>,
    /// What a conditional upload sends back (Drive's ETag).
    pub etag: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Stored {
    pub file: RemoteFile,
    pub etag: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Watched {
    pub changes: bool,
    /// Wait this long before watching again.
    pub backoff_ms: Millis,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Answer<T> {
    Ok(T),
    /// The file changed since the version the request was conditional on.
    Conflict,
    NotFound,
    /// The access token was refused (expired or revoked).
    Unauthorized,
    RateLimited {
        retry_after_ms: Option<Millis>,
    },
    /// The server failed (5xx): try again later.
    Unavailable,
    /// Any other answer, or one that cannot be read.
    Failed,
}

impl<T> Answer<T> {
    /// The statuses every provider answers alike, or None for the provider to read.
    pub fn common(r: &HttpResponse) -> Option<Answer<T>> {
        match r.status {
            401 => Some(Answer::Unauthorized),
            429 => Some(Answer::RateLimited {
                retry_after_ms: r.retry_after_secs().map(|s| s.clamp(0, 86_400) * 1000),
            }),
            500..=599 => Some(Answer::Unavailable),
            _ => None,
        }
    }
}

/// An existing file to replace, and what the replacement is conditional on.
#[derive(Clone, Copy, Debug)]
pub struct Replacing<'a> {
    pub file: &'a RemoteFile,
    pub etag: Option<&'a str>,
}

/// A provider's HTTP API. `token` is the access token; `folder` the app's folder (from
/// `find_folder`/`create_folder`, or "" when the provider has none to find).
pub trait Provider: Send + std::fmt::Debug {
    /// A request for a new access token, or None when the platform gets tokens itself.
    fn refresh(&self, refresh_token: &str) -> Option<HttpRequest>;
    /// The new access token and how many seconds it lasts.
    fn read_refresh(&self, r: &HttpResponse) -> Answer<(String, Option<i64>)>;

    /// Revokes the sign-in on the provider's side (signing out), or None when the platform does
    /// (Drive: the system drops its token).
    fn revoke(&self, token: &str) -> Option<HttpRequest>;

    /// Looks the app's folder up, or None when the provider needs none (Dropbox's App folder).
    fn find_folder(&self, token: &str) -> Option<HttpRequest>;
    /// The folder's id, or None when there is none yet.
    fn read_find_folder(&self, r: &HttpResponse) -> Answer<Option<String>>;
    fn create_folder(&self, token: &str) -> HttpRequest;
    fn read_create_folder(&self, r: &HttpResponse) -> Answer<String>;

    fn list(&self, token: &str, folder: &str, page: Option<&str>) -> HttpRequest;
    fn read_list(&self, r: &HttpResponse) -> Answer<Listing>;

    fn download(&self, token: &str, file: &RemoteFile) -> HttpRequest;
    fn read_download(&self, r: &HttpResponse) -> Answer<Downloaded>;

    /// Creates `name`, or replaces `replacing` only if it is still that version. None: the
    /// replacement cannot be made conditional (download first).
    fn upload(
        &self,
        token: &str,
        folder: &str,
        name: &str,
        data: &[u8],
        replacing: Option<Replacing<'_>>,
    ) -> Option<HttpRequest>;
    fn read_upload(&self, r: &HttpResponse) -> Answer<Stored>;

    /// Deletes the file if it is still that version (where the provider can tell).
    fn delete(&self, token: &str, file: Replacing<'_>) -> HttpRequest;
    fn read_delete(&self, r: &HttpResponse) -> Answer<()>;

    /// Waits for changes after `cursor` (a long poll), or None when the provider has none.
    fn watch(&self, cursor: &str) -> Option<HttpRequest>;
    fn read_watch(&self, r: &HttpResponse) -> Answer<Watched>;
}

/// JSON with every non-ASCII character escaped, for HTTP headers.
pub fn ascii_json(value: &serde_json::Value) -> String {
    let text = value.to_string();
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if c.is_ascii() {
            out.push(c);
        } else {
            let mut units = [0u16; 2];
            for unit in c.encode_utf16(&mut units) {
                out.push_str(&format!("\\u{unit:04x}"));
            }
        }
    }
    out
}
