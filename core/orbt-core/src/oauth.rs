//! OAuth2 with PKCE (RFC 7636), for every provider the app signs in to (Lichess, Dropbox):
//! the verifier and state, the S256 challenge, form encoding and the redirect back to the app.
//! The providers' own requests are in `lichess` and `sync::dropbox`.

use sha2::{Digest, Sha256};

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

/// `k=v&k=v`, each value form-encoded: a query or an `application/x-www-form-urlencoded` body.
pub fn form(fields: &[(&str, &str)]) -> String {
    fields
        .iter()
        .map(|(k, v)| format!("{k}={}", form_encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum RedirectError {
    #[error("The sign-in's answer did not match the request")]
    StateMismatch,
    #[error("The sign-in was refused ({0})")]
    Refused(String),
    #[error("The sign-in's answer had no code")]
    NoCode,
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

/// Reads the redirect back to the app (RFC 6749 4.1.2): the code to exchange, or None when
/// the user declined (`access_denied`). The state must be the one the authorize URL sent.
pub fn parse_redirect(url: &str, expected_state: &str) -> Result<Option<String>, RedirectError> {
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
        return Err(RedirectError::StateMismatch);
    }
    if let Some(error) = param("error") {
        return if error == "access_denied" {
            Ok(None)
        } else {
            Err(RedirectError::Refused(error))
        };
    }
    param("code").map(Some).ok_or(RedirectError::NoCode)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_challenge_matches_rfc_7636() {
        // RFC 7636, Appendix B.
        assert_eq!(
            code_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
        assert_eq!(random_string(&[0, 1, 65, 66]), "AB~A");
        assert_eq!(form(&[("a", "b c"), ("d", "e/f")]), "a=b%20c&d=e%2Ff");
    }
}
