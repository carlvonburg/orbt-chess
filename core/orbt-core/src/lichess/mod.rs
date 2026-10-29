//! Lichess: OAuth2 with PKCE (no client registration, no scopes; the explorer only needs a
//! valid token), cloud evals and links into the analysis board. The core describes the
//! requests and reads the answers; the platform shows the browser sheet, sends the requests
//! and keeps the token in its secure storage.

pub mod cloud_eval;

use sha2::{Digest, Sha256};

use crate::chess::{PlayedMove, Side, san};
use crate::http::{HttpMethod, HttpRequest, HttpResponse};

pub const HOST: &str = "https://lichess.org";
pub const CLIENT_ID: &str = "org.orbtchess.orbt";
pub const CALLBACK_SCHEME: &str = "org.orbtchess.orbt";
pub const REDIRECT_URI: &str = "org.orbtchess.orbt://oauth-callback";
/// Without `expires_in`, Lichess tokens last about a year.
pub const DEFAULT_TOKEN_SECS: i64 = 365 * 86_400;

const PKCE_CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";

/// A PKCE verifier or state from random bytes (one character per byte).
pub fn random_string(random: &[u8]) -> String {
    random
        .iter()
        .map(|&b| PKCE_CHARS[b as usize % PKCE_CHARS.len()] as char)
        .collect()
}

fn base64url(data: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..=chunk.len() {
            out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

/// The S256 code challenge: base64url (no padding) of SHA-256 of the verifier.
pub fn code_challenge(verifier: &str) -> String {
    base64url(&Sha256::digest(verifier.as_bytes()))
}

/// Percent-encodes everything but unreserved characters (as for form bodies and queries).
pub fn form_encode(value: &str) -> String {
    let mut out = String::new();
    for b in value.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// The page that asks the user to allow access.
pub fn authorize_url(verifier: &str, state: &str) -> String {
    let query = [
        ("response_type", "code".to_owned()),
        ("client_id", CLIENT_ID.to_owned()),
        ("redirect_uri", REDIRECT_URI.to_owned()),
        ("code_challenge_method", "S256".to_owned()),
        ("code_challenge", code_challenge(verifier)),
        ("state", state.to_owned()),
    ];
    let query: Vec<String> = query
        .iter()
        .map(|(k, v)| format!("{k}={}", form_encode(v)))
        .collect();
    format!("{HOST}/oauth?{}", query.join("&"))
}

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum AuthError {
    #[error("State mismatch in Lichess callback")]
    StateMismatch,
    #[error("Lichess refused sign-in: {0}")]
    Refused(String),
    #[error("No code in Lichess callback")]
    NoCode,
    #[error("Token exchange failed")]
    BadTokenResponse,
    #[error("Token exchange failed ({0})")]
    TokenStatus(u16),
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' => {
                if let Some(hex) = value.get(i + 1..i + 3)
                    && let Ok(b) = u8::from_str_radix(hex, 16)
                {
                    out.push(b);
                    i += 3;
                    continue;
                }
                out.push(b'%');
            }
            b'+' => out.push(b' '),
            b => out.push(b),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Reads the redirect: the code to exchange, or None when the user declined.
pub fn parse_callback(url: &str, expected_state: &str) -> Result<Option<String>, AuthError> {
    let query = url.split_once('?').map_or("", |(_, q)| q);
    let query = query.split('#').next().unwrap_or("");
    let param = |name: &str| {
        query
            .split('&')
            .filter_map(|kv| kv.split_once('='))
            .find(|(k, _)| *k == name)
            .map(|(_, v)| percent_decode(v))
    };
    if param("state").as_deref() != Some(expected_state) {
        return Err(AuthError::StateMismatch);
    }
    if let Some(error) = param("error") {
        return if error == "access_denied" {
            Ok(None)
        } else {
            Err(AuthError::Refused(error))
        };
    }
    param("code").map(Some).ok_or(AuthError::NoCode)
}

/// The form body for `POST https://lichess.org/api/token`.
pub fn token_request_body(code: &str, verifier: &str) -> String {
    let body = [
        ("grant_type", "authorization_code"),
        ("code", code),
        ("code_verifier", verifier),
        ("redirect_uri", REDIRECT_URI),
        ("client_id", CLIENT_ID),
    ];
    body.iter()
        .map(|(k, v)| format!("{k}={}", form_encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

/// Exchanges the code from the callback for a token.
pub fn token_request(code: &str, verifier: &str) -> HttpRequest {
    HttpRequest::new(HttpMethod::Post, format!("{HOST}/api/token")).body(
        "application/x-www-form-urlencoded",
        token_request_body(code, verifier),
    )
}

/// The token and when it expires (unix seconds), from the token endpoint's answer.
pub fn parse_token_response(
    response: &HttpResponse,
    now_secs: i64,
) -> Result<(String, i64), AuthError> {
    #[derive(serde::Deserialize)]
    struct TokenResponse {
        access_token: String,
        expires_in: Option<f64>,
    }
    if response.status != 200 {
        return Err(AuthError::TokenStatus(response.status));
    }
    let r: TokenResponse =
        serde_json::from_slice(&response.body).map_err(|_| AuthError::BadTokenResponse)?;
    let secs = r.expires_in.map_or(DEFAULT_TOKEN_SECS, |s| s as i64);
    Ok((r.access_token, now_secs + secs))
}

/// Signing out: revokes the token.
pub fn revoke_request(token: &str) -> HttpRequest {
    HttpRequest::new(HttpMethod::Delete, format!("{HOST}/api/token")).bearer(token)
}

/// The signed-in account, for its username.
pub fn account_request(token: &str) -> HttpRequest {
    HttpRequest::get(format!("{HOST}/api/account")).bearer(token)
}

/// The username from the account request's answer.
pub fn parse_account(response: &HttpResponse) -> Option<String> {
    #[derive(serde::Deserialize)]
    struct Account {
        username: String,
    }
    if response.status != 200 {
        return None;
    }
    serde_json::from_slice::<Account>(&response.body)
        .ok()
        .map(|a| a.username)
}

/// Opens the line in the Lichess analysis board, keeping the move history.
pub fn analysis_url(moves: &[PlayedMove], orientation: Side) -> String {
    let sans: Vec<String> = moves.iter().map(|m| san::loose(&m.san)).collect();
    let color = if orientation == Side::Black {
        "?color=black"
    } else {
        ""
    };
    if sans.is_empty() {
        return format!("{HOST}/analysis{color}");
    }
    // URL path characters stay; '#' and '?' (and anything else) are encoded.
    let mut path = String::new();
    for b in sans.join("_").bytes() {
        match b {
            b'A'..=b'Z'
            | b'a'..=b'z'
            | b'0'..=b'9'
            | b'-'
            | b'.'
            | b'_'
            | b'~'
            | b'!'
            | b'$'
            | b'&'
            | b'\''
            | b'('
            | b')'
            | b'*'
            | b'+'
            | b','
            | b';'
            | b'='
            | b':'
            | b'@'
            | b'/' => path.push(b as char),
            _ => path.push_str(&format!("%{b:02X}")),
        }
    }
    format!("{HOST}/analysis/pgn/{path}{color}")
}

/// "1. d4 d5 2. c4 c6", numbered from `start_ply` (0 = White's first move).
pub fn move_list(moves: &[PlayedMove], start_ply: usize) -> String {
    let mut parts = Vec::new();
    for (i, m) in moves.iter().enumerate() {
        let ply = start_ply + i;
        if ply.is_multiple_of(2) {
            parts.push(format!("{}. {}", ply / 2 + 1, m.san));
        } else if i == 0 {
            parts.push(format!("{}… {}", ply / 2 + 1, m.san));
        } else {
            parts.push(m.san.clone());
        }
    }
    parts.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chess::ChessPosition;

    #[test]
    fn pkce_challenge_matches_rfc_7636() {
        // RFC 7636, Appendix B.
        assert_eq!(
            code_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
        assert_eq!(random_string(&[0, 1, 65, 66]), "AB~A");
    }

    #[test]
    fn authorize_and_callback() {
        let url = authorize_url("verifier", "st8");
        assert!(url.starts_with(
            "https://lichess.org/oauth?response_type=code&client_id=org.orbtchess.orbt"
        ));
        assert!(url.contains("redirect_uri=org.orbtchess.orbt%3A%2F%2Foauth-callback"));
        assert!(url.ends_with("&state=st8"));
        let cb = "org.orbtchess.orbt://oauth-callback?code=abc%2B1&state=st8";
        assert_eq!(parse_callback(cb, "st8"), Ok(Some("abc+1".into())));
        assert_eq!(parse_callback(cb, "other"), Err(AuthError::StateMismatch));
        let denied = "org.orbtchess.orbt://oauth-callback?error=access_denied&state=st8";
        assert_eq!(parse_callback(denied, "st8"), Ok(None));
    }

    #[test]
    fn token_exchange() {
        let body = token_request_body("c o", "v");
        assert_eq!(
            body,
            "grant_type=authorization_code&code=c%20o&code_verifier=v&redirect_uri=org.orbtchess.orbt%3A%2F%2Foauth-callback&client_id=org.orbtchess.orbt"
        );
        let request = token_request("c o", "v");
        assert_eq!(request.method, HttpMethod::Post);
        assert_eq!(request.url, "https://lichess.org/api/token");
        assert_eq!(request.body, body.as_bytes());
        assert_eq!(
            (
                request.headers[0].name.as_str(),
                request.headers[0].value.as_str()
            ),
            ("Content-Type", "application/x-www-form-urlencoded")
        );
        let ok = |body: &str| HttpResponse::new(200, body);
        let (token, expires) =
            parse_token_response(&ok(r#"{"access_token":"lio_x","expires_in":100}"#), 1_000)
                .unwrap();
        assert_eq!((token.as_str(), expires), ("lio_x", 1_100));
        let (_, expires) = parse_token_response(&ok(r#"{"access_token":"lio_x"}"#), 0).unwrap();
        assert_eq!(expires, DEFAULT_TOKEN_SECS);
        assert_eq!(
            parse_token_response(&HttpResponse::new(400, "{}"), 0),
            Err(AuthError::TokenStatus(400))
        );
        assert_eq!(
            AuthError::TokenStatus(400).to_string(),
            "Token exchange failed (400)"
        );
    }

    #[test]
    fn account_and_sign_out() {
        let request = account_request("lio_x");
        assert_eq!(
            (request.method, request.url.as_str()),
            (HttpMethod::Get, "https://lichess.org/api/account")
        );
        assert_eq!(request.headers[0].value, "Bearer lio_x");
        assert_eq!(
            parse_account(&HttpResponse::new(200, r#"{"id":"x","username":"Magnus"}"#)),
            Some("Magnus".into())
        );
        assert_eq!(parse_account(&HttpResponse::new(401, "{}")), None);
        let request = revoke_request("lio_x");
        assert_eq!(
            (request.method, request.url.as_str()),
            (HttpMethod::Delete, "https://lichess.org/api/token")
        );
        assert_eq!(request.headers[0].name, "Authorization");
    }

    #[test]
    fn analysis_links_keep_the_moves() {
        let mut p = ChessPosition::start();
        let mut moves = Vec::new();
        for m in ["e4", "e5", "Qh5", "Nc6", "Bc4", "Nf6", "Qxf7#"] {
            let (mv, next) = p.play_san(m).unwrap();
            moves.push(mv);
            p = next;
        }
        assert_eq!(
            analysis_url(&moves, Side::Black),
            "https://lichess.org/analysis/pgn/e4_e5_Qh5_Nc6_Bc4_Nf6_Qxf7?color=black"
        );
        assert_eq!(
            analysis_url(&[], Side::White),
            "https://lichess.org/analysis"
        );
        assert_eq!(move_list(&moves[1..3], 1), "1… e5 2. Qh5");
    }
}
