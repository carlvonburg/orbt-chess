//! Lichess: OAuth2 with PKCE (no client registration, no scopes; the explorer only needs a
//! valid token), cloud evals and links into the analysis board. The core describes the
//! requests and reads the answers; the platform shows the browser sheet, sends the requests
//! and keeps the token in its secure storage.

pub mod cloud_eval;

use crate::chess::{PlayedMove, Side, san};
use crate::http::{HttpMethod, HttpRequest, HttpResponse};
use crate::oauth::{code_challenge, form};

pub const HOST: &str = "https://lichess.org";
pub const CLIENT_ID: &str = "org.orbtchess.orbt";
pub const CALLBACK_SCHEME: &str = "org.orbtchess.orbt";
/// The apps' redirect (their custom scheme); the desktop's is a loopback URI.
pub const REDIRECT_URI: &str = "org.orbtchess.orbt://oauth-callback";
/// Without `expires_in`, Lichess tokens last about a year.
pub const DEFAULT_TOKEN_SECS: i64 = 365 * 86_400;

/// The page that asks the user to allow access, redirecting to `redirect_uri` (read the
/// redirect with `oauth::parse_redirect`).
pub fn authorize_url(verifier: &str, state: &str, redirect_uri: &str) -> String {
    let challenge = code_challenge(verifier);
    let query = form(&[
        ("response_type", "code"),
        ("client_id", CLIENT_ID),
        ("redirect_uri", redirect_uri),
        ("code_challenge_method", "S256"),
        ("code_challenge", &challenge),
        ("state", state),
    ]);
    format!("{HOST}/oauth?{query}")
}

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum AuthError {
    #[error("Token exchange failed")]
    BadTokenResponse,
    #[error("Token exchange failed ({0})")]
    TokenStatus(u16),
}

/// The form body for `POST https://lichess.org/api/token`: the redirect URI is the one the
/// authorize URL named.
pub fn token_request_body(code: &str, verifier: &str, redirect_uri: &str) -> String {
    form(&[
        ("grant_type", "authorization_code"),
        ("code", code),
        ("code_verifier", verifier),
        ("redirect_uri", redirect_uri),
        ("client_id", CLIENT_ID),
    ])
}

/// Exchanges the code from the callback for a token.
pub fn token_request(code: &str, verifier: &str, redirect_uri: &str) -> HttpRequest {
    HttpRequest::new(HttpMethod::Post, format!("{HOST}/api/token")).body(
        "application/x-www-form-urlencoded",
        token_request_body(code, verifier, redirect_uri),
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
    fn token_exchange() {
        let body = token_request_body("c o", "v", REDIRECT_URI);
        assert_eq!(
            body,
            "grant_type=authorization_code&code=c%20o&code_verifier=v&redirect_uri=org.orbtchess.orbt%3A%2F%2Foauth-callback&client_id=org.orbtchess.orbt"
        );
        let request = token_request("c o", "v", REDIRECT_URI);
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
