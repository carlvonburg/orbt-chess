//! Google Drive API v3 with the `drive.file` scope: the app's folder "ORBT Chess" in My Drive
//! and the files in it. Access tokens come from the platform (Android: Play services, which
//! refreshes them itself), or from Google's OAuth for installed apps (iPhone, iPad, Mac: an iOS
//! client, no secret, its reversed id as the redirect; Windows, Linux: a "Desktop app" client,
//! a loopback redirect and a secret that ships in the app, so not secret; both PKCE with
//! `access_type=offline`: `authorize_url`, `token_request`, `read_token`), and then the core
//! refreshes them with the refresh token and signing out revokes it.

use serde::Deserialize;
use serde_json::json;

use super::Millis;
use super::provider::{
    Answer, Downloaded, Listing, Provider, RemoteFile, Replacing, Stored, Watched,
};
use crate::http::{HttpMethod, HttpRequest, HttpResponse, query_encode};
use crate::oauth::{code_challenge, form};

const API: &str = "https://www.googleapis.com/drive/v3";
const UPLOAD: &str = "https://www.googleapis.com/upload/drive/v3";
pub const FOLDER_NAME: &str = "ORBT Chess";
const FOLDER_TYPE: &str = "application/vnd.google-apps.folder";
const FILE_FIELDS: &str = "id,name,md5Checksum,version";
const TIMEOUT_SECS: u32 = 60;
const ACCOUNTS: &str = "https://accounts.google.com";
const OAUTH: &str = "https://oauth2.googleapis.com";
/// The only scope asked for: the files the app creates or the user opens with it.
pub const SCOPE: &str = "https://www.googleapis.com/auth/drive.file";

#[derive(Clone, Debug, Default)]
pub struct Drive {
    /// The OAuth client when the core signs in and refreshes; None when the platform gets the
    /// tokens (Android's Play services).
    pub client: Option<Client>,
}

/// A Google OAuth client of the platform's (never committed).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Client {
    pub id: String,
    /// A "Desktop app" client's secret, which Google wants in the code exchange and each
    /// refresh even with PKCE; None for an iOS client.
    pub secret: Option<String>,
}

impl Client {
    /// The token endpoint's form: `fields`, then the client id and, when there is one, secret.
    fn token_request(&self, fields: &[(&str, &str)]) -> HttpRequest {
        let mut fields = fields.to_vec();
        fields.push(("client_id", &self.id));
        if let Some(secret) = &self.secret {
            fields.push(("client_secret", secret));
        }
        HttpRequest::new(HttpMethod::Post, format!("{OAUTH}/token"))
            .body("application/x-www-form-urlencoded", form(&fields))
            .timeout(TIMEOUT_SECS)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct File {
    id: String,
    #[serde(default)]
    name: String,
    md5_checksum: Option<String>,
    version: Option<String>,
}

impl File {
    fn remote(self) -> RemoteFile {
        RemoteFile {
            rev: self.md5_checksum.or(self.version).unwrap_or_default(),
            id: self.id,
            name: self.name,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileList {
    #[serde(default)]
    files: Vec<File>,
    next_page_token: Option<String>,
}

/// A name inside a Drive query string literal.
fn quoted(value: &str) -> String {
    value.replace('\\', "\\\\").replace('\'', "\\'")
}

fn files_url(q: &str, fields: &str, page: Option<&str>) -> String {
    let mut url = format!(
        "{API}/files?q={}&fields={}&pageSize=1000&spaces=drive",
        query_encode(q),
        query_encode(fields)
    );
    if let Some(page) = page {
        url.push_str(&format!("&pageToken={}", query_encode(page)));
    }
    url
}

fn get(token: &str, url: String) -> HttpRequest {
    HttpRequest::get(url).bearer(token).timeout(TIMEOUT_SECS)
}

fn read<T>(r: &HttpResponse, ok: impl FnOnce(&HttpResponse) -> Option<T>) -> Answer<T> {
    if let Some(common) = Answer::common(r) {
        return common;
    }
    match r.status {
        200 => ok(r).map_or(Answer::Failed, Answer::Ok),
        // Drive's rate limits come as 403 with these reasons.
        403 if String::from_utf8_lossy(&r.body).contains("ateLimitExceeded") => {
            Answer::RateLimited {
                retry_after_ms: None,
            }
        }
        404 => Answer::NotFound,
        412 => Answer::Conflict,
        _ => Answer::Failed,
    }
}

fn etag(r: &HttpResponse) -> Option<String> {
    r.header("ETag").map(str::to_owned)
}

/// The redirect Google allows an iOS client: its reversed client id as the scheme
/// (`com.googleusercontent.apps.<id>:/oauth2redirect`), registered as a URL type in the app.
/// A Desktop app client redirects to the loopback server instead (`http://127.0.0.1:<port>/`).
pub fn redirect_uri(client_id: &str) -> String {
    let id = client_id
        .strip_suffix(".apps.googleusercontent.com")
        .unwrap_or(client_id);
    format!("com.googleusercontent.apps.{id}:/oauth2redirect")
}

/// What signing in gives: the refresh token is what to keep (the core refreshes with it).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignIn {
    pub access_token: String,
    /// Unix ms; None when the answer did not say.
    pub expires_at: Option<Millis>,
    pub refresh_token: String,
}

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum SignInError {
    #[error("Google refused the sign-in ({0})")]
    Refused(String),
    #[error("Google Drive access was not allowed")]
    NoDriveAccess,
    #[error("Google's answer to the sign-in could not be read")]
    BadAnswer,
}

#[derive(Deserialize)]
struct TokenAnswer {
    access_token: String,
    expires_in: Option<i64>,
    refresh_token: Option<String>,
    scope: Option<String>,
}

/// Google's error description, else its error, else the status.
fn error_reason(r: &HttpResponse) -> String {
    serde_json::from_slice::<serde_json::Value>(&r.body)
        .ok()
        .and_then(|v| {
            let text = v.get("error_description").or_else(|| v.get("error"))?;
            text.as_str().map(str::to_owned)
        })
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| format!("error {}", r.status))
}

/// The page that asks the user to allow access to the app's Drive files, for a refresh token
/// (`access_type=offline`), redirecting to `redirect_uri` (read the redirect with
/// `oauth::parse_redirect`).
pub fn authorize_url(client_id: &str, verifier: &str, state: &str, redirect_uri: &str) -> String {
    let challenge = code_challenge(verifier);
    let query = form(&[
        ("client_id", client_id),
        ("response_type", "code"),
        ("scope", SCOPE),
        ("access_type", "offline"),
        ("code_challenge", &challenge),
        ("code_challenge_method", "S256"),
        ("redirect_uri", redirect_uri),
        ("state", state),
    ]);
    format!("{ACCOUNTS}/o/oauth2/v2/auth?{query}")
}

/// Exchanges the code from the redirect for a refresh token and a first access token.
pub fn token_request(
    client: &Client,
    code: &str,
    verifier: &str,
    redirect_uri: &str,
) -> HttpRequest {
    client.token_request(&[
        ("grant_type", "authorization_code"),
        ("code", code),
        ("code_verifier", verifier),
        ("redirect_uri", redirect_uri),
    ])
}

/// The token request's answer (`now`: unix ms). Google lets the user untick Drive on its
/// consent page: a sign-in without the `drive.file` scope is refused.
pub fn read_token(r: &HttpResponse, now: Millis) -> Result<SignIn, SignInError> {
    if r.status != 200 {
        return Err(SignInError::Refused(error_reason(r)));
    }
    let a: TokenAnswer = serde_json::from_slice(&r.body).map_err(|_| SignInError::BadAnswer)?;
    let refresh_token = a.refresh_token.unwrap_or_default();
    if a.access_token.is_empty() || refresh_token.is_empty() {
        return Err(SignInError::BadAnswer);
    }
    if let Some(scope) = a.scope
        && !scope.split(' ').any(|s| s == SCOPE)
    {
        return Err(SignInError::NoDriveAccess);
    }
    Ok(SignIn {
        access_token: a.access_token,
        expires_at: a
            .expires_in
            .filter(|&s| s > 0)
            .map(|s| now + s.min(1 << 31) * 1000),
        refresh_token,
    })
}

/// The signed-in account, for its email (shown in Settings; `drive.file` allows it).
pub fn account_request(access_token: &str) -> HttpRequest {
    get(
        access_token,
        format!("{API}/about?fields=user(emailAddress)"),
    )
}

/// The email from the account request's answer.
pub fn read_account(r: &HttpResponse) -> Option<String> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct User {
        email_address: String,
    }
    #[derive(Deserialize)]
    struct About {
        user: User,
    }
    if r.status != 200 {
        return None;
    }
    serde_json::from_slice::<About>(&r.body)
        .ok()
        .map(|a| a.user.email_address)
        .filter(|e| !e.is_empty())
}

/// Revokes a token (signing out): an access token takes its refresh token with it.
pub fn revoke_request(token: &str) -> HttpRequest {
    HttpRequest::new(HttpMethod::Post, format!("{OAUTH}/revoke"))
        .body(
            "application/x-www-form-urlencoded",
            form(&[("token", token)]),
        )
        .timeout(TIMEOUT_SECS)
}

impl Provider for Drive {
    fn refresh(&self, refresh_token: &str) -> Option<HttpRequest> {
        let client = self.client.as_ref()?;
        Some(client.token_request(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
        ]))
    }

    fn read_refresh(&self, r: &HttpResponse) -> Answer<(String, Option<i64>)> {
        match r.status {
            200 => serde_json::from_slice::<TokenAnswer>(&r.body)
                .ok()
                .filter(|t| !t.access_token.is_empty())
                .map_or(Answer::Failed, |t| {
                    Answer::Ok((t.access_token, t.expires_in))
                }),
            // invalid_grant: revoked, unused for six months, the password changed, or seven
            // days old while the consent screen is in Testing.
            400 | 401 => Answer::Unauthorized,
            _ => Answer::common(r).unwrap_or(Answer::Failed),
        }
    }

    fn revoke(&self, token: &str) -> Option<HttpRequest> {
        // Play services' tokens are the system's to drop.
        self.client.as_ref()?;
        Some(revoke_request(token))
    }

    fn find_folder(&self, token: &str) -> Option<HttpRequest> {
        let q = format!(
            "name = '{}' and mimeType = '{FOLDER_TYPE}' and 'root' in parents and trashed = false",
            quoted(FOLDER_NAME)
        );
        Some(get(token, files_url(&q, "files(id)", None)))
    }

    fn read_find_folder(&self, r: &HttpResponse) -> Answer<Option<String>> {
        read(r, |r| {
            let list: FileList = serde_json::from_slice(&r.body).ok()?;
            Some(list.files.into_iter().next().map(|f| f.id))
        })
    }

    fn create_folder(&self, token: &str) -> HttpRequest {
        HttpRequest::new(HttpMethod::Post, format!("{API}/files?fields=id"))
            .bearer(token)
            .body(
                "application/json",
                json!({"name": FOLDER_NAME, "mimeType": FOLDER_TYPE}).to_string(),
            )
            .timeout(TIMEOUT_SECS)
    }

    fn read_create_folder(&self, r: &HttpResponse) -> Answer<String> {
        read(r, |r| {
            Some(serde_json::from_slice::<File>(&r.body).ok()?.id).filter(|id| !id.is_empty())
        })
    }

    fn list(&self, token: &str, folder: &str, page: Option<&str>) -> HttpRequest {
        let q = format!("'{}' in parents and trashed = false", quoted(folder));
        let fields = format!("nextPageToken,files({FILE_FIELDS})");
        get(token, files_url(&q, &fields, page))
    }

    fn read_list(&self, r: &HttpResponse) -> Answer<Listing> {
        read(r, |r| {
            let list: FileList = serde_json::from_slice(&r.body).ok()?;
            Some(Listing {
                files: list.files.into_iter().map(File::remote).collect(),
                next_page: list.next_page_token,
                cursor: None,
            })
        })
    }

    fn download(&self, token: &str, file: &RemoteFile) -> HttpRequest {
        get(
            token,
            format!("{API}/files/{}?alt=media", query_encode(&file.id)),
        )
    }

    fn read_download(&self, r: &HttpResponse) -> Answer<Downloaded> {
        read(r, |r| {
            Some(Downloaded {
                data: r.body.clone(),
                rev: None,
                etag: etag(r),
            })
        })
    }

    fn upload(
        &self,
        token: &str,
        folder: &str,
        name: &str,
        data: &[u8],
        replacing: Option<Replacing<'_>>,
    ) -> Option<HttpRequest> {
        let fields = query_encode(FILE_FIELDS);
        match replacing {
            Some(r) => {
                let request = HttpRequest::new(
                    HttpMethod::Patch,
                    format!(
                        "{UPLOAD}/files/{}?uploadType=media&fields={fields}",
                        query_encode(&r.file.id)
                    ),
                )
                .bearer(token);
                // Drive v3 answers without an ETag, so most replacements are not conditional:
                // the engine replaces a file only while the latest listing shows the version it
                // last synced (`md5Checksum`), which leaves the moments between that listing and
                // this upload. Waiting for an ETag instead downloaded the file forever.
                // Differences: Google documents `If-Match` for Drive v2 only; check the 412 on the
                // live API before shipping.
                let request = match r.etag {
                    Some(etag) => request.header("If-Match", etag),
                    None => request,
                };
                Some(
                    request
                        .body("application/octet-stream", data)
                        .timeout(TIMEOUT_SECS),
                )
            }
            None => {
                let boundary = format!("orbt-{}", super::content_hash(data));
                let metadata = json!({"name": name, "parents": [folder]}).to_string();
                let mut body = format!(
                    "--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{metadata}\r\n--{boundary}\r\nContent-Type: application/octet-stream\r\n\r\n"
                )
                .into_bytes();
                body.extend_from_slice(data);
                body.extend_from_slice(format!("\r\n--{boundary}--").as_bytes());
                Some(
                    HttpRequest::new(
                        HttpMethod::Post,
                        format!("{UPLOAD}/files?uploadType=multipart&fields={fields}"),
                    )
                    .bearer(token)
                    .body(&format!("multipart/related; boundary={boundary}"), body)
                    .timeout(TIMEOUT_SECS),
                )
            }
        }
    }

    fn read_upload(&self, r: &HttpResponse) -> Answer<Stored> {
        read(r, |r| {
            Some(Stored {
                file: serde_json::from_slice::<File>(&r.body).ok()?.remote(),
                etag: etag(r),
            })
        })
    }

    fn delete(&self, token: &str, file: Replacing<'_>) -> HttpRequest {
        // To the trash, where the user can get it back.
        HttpRequest::new(
            HttpMethod::Patch,
            format!("{API}/files/{}?fields=id", query_encode(&file.file.id)),
        )
        .bearer(token)
        .body("application/json", json!({"trashed": true}).to_string())
        .timeout(TIMEOUT_SECS)
    }

    fn read_delete(&self, r: &HttpResponse) -> Answer<()> {
        read(r, |_| Some(()))
    }

    fn watch(&self, _cursor: &str) -> Option<HttpRequest> {
        None
    }

    fn read_watch(&self, _r: &HttpResponse) -> Answer<Watched> {
        Answer::Failed
    }
}
