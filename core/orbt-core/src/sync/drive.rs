//! Google Drive API v3 with the `drive.file` scope: the app's folder "ORBT Chess" in My Drive
//! and the files in it. Access tokens come from the platform (Play Services, Google Sign-In).

use serde::Deserialize;
use serde_json::json;

use super::provider::{
    Answer, Downloaded, Listing, Provider, RemoteFile, Replacing, Stored, Watched,
};
use crate::http::{HttpMethod, HttpRequest, HttpResponse, query_encode};

const API: &str = "https://www.googleapis.com/drive/v3";
const UPLOAD: &str = "https://www.googleapis.com/upload/drive/v3";
pub const FOLDER_NAME: &str = "ORBT Chess";
const FOLDER_TYPE: &str = "application/vnd.google-apps.folder";
const FILE_FIELDS: &str = "id,name,md5Checksum,version";
const TIMEOUT_SECS: u32 = 60;

#[derive(Clone, Debug, Default)]
pub struct Drive;

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

impl Provider for Drive {
    fn refresh(&self, _refresh_token: &str) -> Option<HttpRequest> {
        None
    }

    fn read_refresh(&self, _r: &HttpResponse) -> Answer<(String, Option<i64>)> {
        Answer::Failed
    }

    fn revoke(&self, _token: &str) -> Option<HttpRequest> {
        None
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
                let etag = r.etag?;
                Some(
                    HttpRequest::new(
                        HttpMethod::Patch,
                        format!(
                            "{UPLOAD}/files/{}?uploadType=media&fields={fields}",
                            query_encode(&r.file.id)
                        ),
                    )
                    .bearer(token)
                    .header("If-Match", etag)
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
