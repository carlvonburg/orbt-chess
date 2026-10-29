//! HTTP requests as data (sans-IO): the core describes each request and reads each answer;
//! the platform only sends them and hands back status, headers and body.

/// Percent-encodes a query value (unreserved characters, '/' and ',' stay as they are).
pub fn query_encode(value: &str) -> String {
    let mut out = String::new();
    for b in value.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' | b',' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HttpMethod {
    Get,
    Post,
    Patch,
    Delete,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Header {
    pub name: String,
    pub value: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpRequest {
    pub method: HttpMethod,
    pub url: String,
    pub headers: Vec<Header>,
    pub body: Vec<u8>,
    /// Give up after this long; None: the platform's default.
    pub timeout_secs: Option<u32>,
}

impl HttpRequest {
    pub fn new(method: HttpMethod, url: impl Into<String>) -> HttpRequest {
        HttpRequest {
            method,
            url: url.into(),
            headers: Vec::new(),
            body: Vec::new(),
            timeout_secs: None,
        }
    }

    pub fn get(url: impl Into<String>) -> HttpRequest {
        HttpRequest::new(HttpMethod::Get, url)
    }

    pub fn header(mut self, name: &str, value: impl Into<String>) -> HttpRequest {
        self.headers.push(Header {
            name: name.to_owned(),
            value: value.into(),
        });
        self
    }

    pub fn bearer(self, token: &str) -> HttpRequest {
        self.header("Authorization", format!("Bearer {token}"))
    }

    pub fn body(mut self, content_type: &str, body: impl Into<Vec<u8>>) -> HttpRequest {
        self.body = body.into();
        self.header("Content-Type", content_type)
    }

    pub fn timeout(mut self, secs: u32) -> HttpRequest {
        self.timeout_secs = Some(secs);
        self
    }
}

/// What the server answered.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HttpResponse {
    pub status: u16,
    pub headers: Vec<Header>,
    pub body: Vec<u8>,
}

impl HttpResponse {
    pub fn new(status: u16, body: impl Into<Vec<u8>>) -> HttpResponse {
        HttpResponse {
            status,
            headers: Vec::new(),
            body: body.into(),
        }
    }

    /// A header's value; names are case-insensitive.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|h| h.name.eq_ignore_ascii_case(name))
            .map(|h| h.value.as_str())
    }

    /// Retry-After in seconds (the delay form; an HTTP date is ignored).
    pub fn retry_after_secs(&self) -> Option<i64> {
        let value: f64 = self.header("Retry-After")?.trim().parse().ok()?;
        Some(value as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headers_are_case_insensitive() {
        let mut r = HttpResponse::new(429, Vec::new());
        assert_eq!(r.retry_after_secs(), None);
        r.headers.push(Header {
            name: "retry-after".into(),
            value: "90".into(),
        });
        assert_eq!(r.header("Retry-After"), Some("90"));
        assert_eq!(r.retry_after_secs(), Some(90));
        let request = HttpRequest::get("https://x").bearer("t").timeout(5);
        assert_eq!(request.headers[0].value, "Bearer t");
        assert_eq!(request.timeout_secs, Some(5));
    }
}
