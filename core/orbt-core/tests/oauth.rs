//! Signing in with OAuth2 and PKCE: the redirect back to the app (any provider), Lichess's
//! Dropbox's and Google Drive's requests with the redirect URI the platform receives (the apps' custom
//! scheme, the desktop's loopback server), their answers and signing out.

use std::collections::BTreeMap;

use orbt_core::http::{HttpMethod, HttpRequest, HttpResponse};
use orbt_core::lichess;
use orbt_core::oauth::{self, RedirectError, code_challenge};
use orbt_core::sync::drive;
use orbt_core::sync::dropbox::{self, Dropbox, SignIn, SignInError};

const LOOPBACK: &str = "http://127.0.0.1:5123/";

fn decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            out.push(u8::from_str_radix(&s[i + 1..i + 3], 16).unwrap());
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).unwrap()
}

fn fields(form: &str) -> BTreeMap<String, String> {
    form.split('&')
        .map(|kv| {
            let (k, v) = kv.split_once('=').unwrap();
            (k.to_owned(), decode(v))
        })
        .collect()
}

fn query(url: &str) -> BTreeMap<String, String> {
    fields(url.split_once('?').unwrap().1)
}

fn body(r: &HttpRequest) -> BTreeMap<String, String> {
    fields(std::str::from_utf8(&r.body).unwrap())
}

fn header<'a>(r: &'a HttpRequest, name: &str) -> Option<&'a str> {
    r.headers
        .iter()
        .find(|h| h.name.eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str())
}

#[test]
fn the_redirect_gives_the_code_when_the_state_matches() {
    let cb = "org.orbtchess.orbt://oauth-callback?code=abc%2B1&state=st8";
    assert_eq!(oauth::parse_redirect(cb, "st8"), Ok(Some("abc+1".into())));
    assert_eq!(
        oauth::parse_redirect(cb, "other"),
        Err(RedirectError::StateMismatch)
    );
    // The loopback server's redirect, with a fragment.
    let cb = "http://127.0.0.1:5123/?state=st8&code=xyz#_";
    assert_eq!(oauth::parse_redirect(cb, "st8"), Ok(Some("xyz".into())));
    // Declined: no code, no error.
    let denied = "org.orbtchess.orbt://dropbox-callback?error=access_denied&state=st8";
    assert_eq!(oauth::parse_redirect(denied, "st8"), Ok(None));
    // Any other error is the provider's, named in the text; no provider is named.
    let refused = "x://y?state=st8&error=invalid_scope&error_description=no";
    let error = oauth::parse_redirect(refused, "st8").unwrap_err();
    assert_eq!(error, RedirectError::Refused("invalid_scope".into()));
    assert_eq!(error.to_string(), "The sign-in was refused (invalid_scope)");
    assert_eq!(
        oauth::parse_redirect("x://y?state=st8", "st8"),
        Err(RedirectError::NoCode)
    );
    for e in [RedirectError::StateMismatch, RedirectError::NoCode] {
        assert!(!e.to_string().contains("Lichess"));
    }
}

#[test]
fn lichess_sends_the_redirect_uri_it_is_given() {
    let url = lichess::authorize_url("verifier", "st8", LOOPBACK);
    assert!(url.starts_with("https://lichess.org/oauth?"));
    let q = query(&url);
    assert_eq!(q["redirect_uri"], LOOPBACK);
    assert_eq!(q["client_id"], lichess::CLIENT_ID);
    assert_eq!(q["code_challenge"], code_challenge("verifier"));
    assert_eq!(q["code_challenge_method"], "S256");
    assert_eq!(q["state"], "st8");
    assert!(url.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A5123%2F"));

    let request = lichess::token_request("code", "verifier", LOOPBACK);
    assert_eq!(request.url, "https://lichess.org/api/token");
    let b = body(&request);
    assert_eq!(b["redirect_uri"], LOOPBACK);
    assert_eq!(b["code"], "code");
    assert_eq!(b["code_verifier"], "verifier");

    // The apps' custom scheme.
    let url = lichess::authorize_url("verifier", "st8", lichess::REDIRECT_URI);
    assert_eq!(
        query(&url)["redirect_uri"],
        "org.orbtchess.orbt://oauth-callback"
    );
}

#[test]
fn dropbox_asks_for_a_refresh_token_with_pkce() {
    let dropbox = Dropbox {
        app_key: "app-key".into(),
    };
    let url = dropbox.authorize_url("verifier", "st8", dropbox::REDIRECT_URI);
    assert!(url.starts_with("https://www.dropbox.com/oauth2/authorize?"));
    let q = query(&url);
    assert_eq!(q["client_id"], "app-key");
    assert_eq!(q["response_type"], "code");
    assert_eq!(q["token_access_type"], "offline");
    assert_eq!(q["code_challenge"], code_challenge("verifier"));
    assert_eq!(q["code_challenge_method"], "S256");
    assert_eq!(q["redirect_uri"], "org.orbtchess.orbt://dropbox-callback");
    assert_eq!(q["state"], "st8");

    let request = dropbox.token_request("c o", "verifier", LOOPBACK);
    assert_eq!(request.method, HttpMethod::Post);
    assert_eq!(request.url, "https://api.dropboxapi.com/oauth2/token");
    assert_eq!(
        header(&request, "Content-Type"),
        Some("application/x-www-form-urlencoded")
    );
    let b = body(&request);
    assert_eq!(b["grant_type"], "authorization_code");
    assert_eq!(b["code"], "c o");
    assert_eq!(b["code_verifier"], "verifier");
    assert_eq!(b["client_id"], "app-key");
    assert_eq!(b["redirect_uri"], LOOPBACK);
}

#[test]
fn dropbox_token_answers_are_read() {
    let answer = r#"{"access_token": "sl.abc", "token_type": "bearer", "expires_in": 14400,
        "refresh_token": "r-1", "scope": "files.content.read", "uid": "12",
        "account_id": "dbid:AAH"}"#;
    assert_eq!(
        dropbox::read_token(&HttpResponse::new(200, answer), 1_000),
        Ok(SignIn {
            access_token: "sl.abc".into(),
            expires_at: Some(1_000 + 14_400_000),
            refresh_token: "r-1".into(),
            account_id: Some("dbid:AAH".into()),
        })
    );
    // No expiry: unknown, not invented.
    let answer = r#"{"access_token": "sl.abc", "refresh_token": "r-1"}"#;
    let sign_in = dropbox::read_token(&HttpResponse::new(200, answer), 1_000).unwrap();
    assert_eq!((sign_in.expires_at, sign_in.account_id), (None, None));
    // Without a refresh token the sign-in is no use.
    let answer = r#"{"access_token": "sl.abc", "expires_in": 14400}"#;
    assert_eq!(
        dropbox::read_token(&HttpResponse::new(200, answer), 0),
        Err(SignInError::BadAnswer)
    );
    assert_eq!(
        dropbox::read_token(&HttpResponse::new(200, "<html>"), 0),
        Err(SignInError::BadAnswer)
    );
    // Refused: Dropbox's description, else its error, else the status.
    let refused = r#"{"error": "invalid_grant", "error_description": "code doesn't exist"}"#;
    let error = dropbox::read_token(&HttpResponse::new(400, refused), 0).unwrap_err();
    assert_eq!(
        error.to_string(),
        "Dropbox refused the sign-in (code doesn't exist)"
    );
    assert_eq!(
        dropbox::read_token(&HttpResponse::new(400, r#"{"error": "invalid_grant"}"#), 0),
        Err(SignInError::Refused("invalid_grant".into()))
    );
    assert_eq!(
        dropbox::read_token(&HttpResponse::new(503, ""), 0),
        Err(SignInError::Refused("error 503".into()))
    );
}

#[test]
fn dropbox_account_and_revoke() {
    let request = dropbox::account_request("sl.abc");
    assert_eq!(request.method, HttpMethod::Post);
    assert_eq!(
        request.url,
        "https://api.dropboxapi.com/2/users/get_current_account"
    );
    assert_eq!(header(&request, "Authorization"), Some("Bearer sl.abc"));
    assert!(request.body.is_empty());
    let answer = r#"{"account_id": "dbid:AAH", "email": "magnus@example.org",
        "name": {"display_name": "Magnus"}}"#;
    assert_eq!(
        dropbox::read_account(&HttpResponse::new(200, answer)),
        Some("magnus@example.org".into())
    );
    assert_eq!(dropbox::read_account(&HttpResponse::new(401, "{}")), None);

    let request = dropbox::revoke_request("sl.abc");
    assert_eq!(request.method, HttpMethod::Post);
    assert_eq!(
        request.url,
        "https://api.dropboxapi.com/2/auth/token/revoke"
    );
    assert_eq!(header(&request, "Authorization"), Some("Bearer sl.abc"));
    assert!(request.body.is_empty());
}

#[test]
fn lichess_signs_out_on_the_server() {
    let request = lichess::revoke_request("lio_x");
    assert_eq!(
        (request.method, request.url.as_str()),
        (HttpMethod::Delete, "https://lichess.org/api/token")
    );
    assert_eq!(header(&request, "Authorization"), Some("Bearer lio_x"));
}

const GOOGLE_CLIENT: &str = "123-abc.apps.googleusercontent.com";

fn ios_client() -> drive::Client {
    drive::Client {
        id: GOOGLE_CLIENT.into(),
        secret: None,
    }
}

/// Windows, Linux: a Desktop app client, whose secret ships in the app.
fn desktop_client() -> drive::Client {
    drive::Client {
        id: "456-def.apps.googleusercontent.com".into(),
        secret: Some("GOCSPX-shipped".into()),
    }
}

#[test]
fn drive_asks_for_a_refresh_token_with_pkce() {
    let redirect = drive::redirect_uri(GOOGLE_CLIENT);
    assert_eq!(
        redirect,
        "com.googleusercontent.apps.123-abc:/oauth2redirect"
    );
    let url = drive::authorize_url(GOOGLE_CLIENT, "verifier", "st8", &redirect);
    assert!(url.starts_with("https://accounts.google.com/o/oauth2/v2/auth?"));
    let q = query(&url);
    assert_eq!(q["client_id"], GOOGLE_CLIENT);
    assert_eq!(q["response_type"], "code");
    assert_eq!(q["scope"], "https://www.googleapis.com/auth/drive.file");
    assert_eq!(q["access_type"], "offline");
    assert_eq!(q["code_challenge"], code_challenge("verifier"));
    assert_eq!(q["code_challenge_method"], "S256");
    assert_eq!(q["redirect_uri"], redirect);
    assert_eq!(q["state"], "st8");

    // Google's redirect to an iOS client has the code in its query.
    let back = format!(
        "{redirect}?state=st8&code=4/0Ab%2Bc&scope=https://www.googleapis.com/auth/drive.file"
    );
    assert_eq!(
        oauth::parse_redirect(&back, "st8"),
        Ok(Some("4/0Ab+c".into()))
    );

    let request = drive::token_request(&ios_client(), "4/0Ab+c", "verifier", &redirect);
    assert_eq!(request.method, HttpMethod::Post);
    assert_eq!(request.url, "https://oauth2.googleapis.com/token");
    assert_eq!(
        header(&request, "Content-Type"),
        Some("application/x-www-form-urlencoded")
    );
    let b = body(&request);
    assert_eq!(b["grant_type"], "authorization_code");
    assert_eq!(b["code"], "4/0Ab+c");
    assert_eq!(b["code_verifier"], "verifier");
    assert_eq!(b["client_id"], GOOGLE_CLIENT);
    assert_eq!(b["redirect_uri"], redirect);
    // An iOS client has no secret.
    assert!(!b.contains_key("client_secret"));
    assert!(header(&request, "Authorization").is_none());

    // A Desktop app client: the loopback redirect, and its secret in the exchange.
    let url = drive::authorize_url(&desktop_client().id, "verifier", "st8", LOOPBACK);
    assert_eq!(query(&url)["redirect_uri"], LOOPBACK);
    assert!(!query(&url).contains_key("client_secret"));
    let request = drive::token_request(&desktop_client(), "c", "verifier", LOOPBACK);
    let b = body(&request);
    assert_eq!(b["client_id"], "456-def.apps.googleusercontent.com");
    assert_eq!(b["client_secret"], "GOCSPX-shipped");
    assert_eq!(b["redirect_uri"], LOOPBACK);
    assert_eq!(b["code_verifier"], "verifier");
}

#[test]
fn drive_token_answers_are_read() {
    let answer = r#"{"access_token": "ya29.a0", "expires_in": 3599, "refresh_token": "1//0g",
        "scope": "https://www.googleapis.com/auth/drive.file", "token_type": "Bearer"}"#;
    assert_eq!(
        drive::read_token(&HttpResponse::new(200, answer), 1_000),
        Ok(drive::SignIn {
            access_token: "ya29.a0".into(),
            expires_at: Some(1_000 + 3_599_000),
            refresh_token: "1//0g".into(),
        })
    );
    // Other scopes beside it are fine; no scope said: assumed as asked.
    let answer = r#"{"access_token": "ya29.a0", "refresh_token": "1//0g",
        "scope": "openid https://www.googleapis.com/auth/drive.file"}"#;
    let sign_in = drive::read_token(&HttpResponse::new(200, answer), 0).unwrap();
    assert_eq!(sign_in.expires_at, None);
    let answer = r#"{"access_token": "ya29.a0", "refresh_token": "1//0g"}"#;
    assert!(drive::read_token(&HttpResponse::new(200, answer), 0).is_ok());
    // The user unticked Drive on Google's consent page.
    let answer = r#"{"access_token": "ya29.a0", "refresh_token": "1//0g", "scope": "openid"}"#;
    assert_eq!(
        drive::read_token(&HttpResponse::new(200, answer), 0),
        Err(drive::SignInError::NoDriveAccess)
    );
    // Without a refresh token the sign-in is no use.
    let answer = r#"{"access_token": "ya29.a0", "expires_in": 3599}"#;
    assert_eq!(
        drive::read_token(&HttpResponse::new(200, answer), 0),
        Err(drive::SignInError::BadAnswer)
    );
    assert_eq!(
        drive::read_token(&HttpResponse::new(200, "<html>"), 0),
        Err(drive::SignInError::BadAnswer)
    );
    // Refused: Google's description, else its error, else the status.
    let refused = r#"{"error": "invalid_grant", "error_description": "Bad Request"}"#;
    let error = drive::read_token(&HttpResponse::new(400, refused), 0).unwrap_err();
    assert_eq!(
        error.to_string(),
        "Google refused the sign-in (Bad Request)"
    );
    assert_eq!(
        drive::read_token(&HttpResponse::new(401, r#"{"error": "invalid_client"}"#), 0),
        Err(drive::SignInError::Refused("invalid_client".into()))
    );
    assert_eq!(
        drive::read_token(&HttpResponse::new(503, ""), 0),
        Err(drive::SignInError::Refused("error 503".into()))
    );
}

#[test]
fn drive_refresh_account_and_revoke() {
    use orbt_core::sync::provider::{Answer, Provider};

    let own = drive::Drive {
        client: Some(ios_client()),
    };
    let request = own.refresh("1//0g").expect("a refresh request");
    assert_eq!(request.method, HttpMethod::Post);
    assert_eq!(request.url, "https://oauth2.googleapis.com/token");
    let b = body(&request);
    assert_eq!(b["grant_type"], "refresh_token");
    assert_eq!(b["refresh_token"], "1//0g");
    assert_eq!(b["client_id"], GOOGLE_CLIENT);
    assert!(!b.contains_key("client_secret"));
    // Google sends no new refresh token: the one kept stays.
    let answer = r#"{"access_token": "ya29.b", "expires_in": 3599, "token_type": "Bearer"}"#;
    assert_eq!(
        own.read_refresh(&HttpResponse::new(200, answer)),
        Answer::Ok(("ya29.b".into(), Some(3599)))
    );
    let revoked =
        r#"{"error": "invalid_grant", "error_description": "Token has been expired or revoked."}"#;
    assert_eq!(
        own.read_refresh(&HttpResponse::new(400, revoked)),
        Answer::Unauthorized
    );
    assert_eq!(
        own.read_refresh(&HttpResponse::new(200, "{}")),
        Answer::Failed
    );
    assert_eq!(
        own.read_refresh(&HttpResponse::new(503, "")),
        Answer::Unavailable
    );

    let desktop = drive::Drive {
        client: Some(desktop_client()),
    };
    let b = body(&desktop.refresh("1//0g").unwrap());
    assert_eq!(b["client_secret"], "GOCSPX-shipped");
    assert_eq!(b["refresh_token"], "1//0g");
    // Revoking needs no client.
    assert!(!body(&desktop.revoke("ya29.b").unwrap()).contains_key("client_secret"));

    let request = own.revoke("ya29.b").expect("a revoke request");
    assert_eq!(request.method, HttpMethod::Post);
    assert_eq!(request.url, "https://oauth2.googleapis.com/revoke");
    assert_eq!(body(&request)["token"], "ya29.b");
    assert!(header(&request, "Authorization").is_none());

    // Android's Play services: the system refreshes and revokes.
    let system = drive::Drive::default();
    assert_eq!(system.refresh("1//0g"), None);
    assert_eq!(system.revoke("ya29.b"), None);

    let request = drive::account_request("ya29.b");
    assert_eq!(request.method, HttpMethod::Get);
    assert_eq!(
        request.url,
        "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)"
    );
    assert_eq!(header(&request, "Authorization"), Some("Bearer ya29.b"));
    let answer = r#"{"user": {"kind": "drive#user", "displayName": "Magnus",
        "emailAddress": "magnus@example.org"}}"#;
    assert_eq!(
        drive::read_account(&HttpResponse::new(200, answer)),
        Some("magnus@example.org".into())
    );
    assert_eq!(drive::read_account(&HttpResponse::new(401, "{}")), None);
    assert_eq!(drive::read_account(&HttpResponse::new(200, "{}")), None);
}
