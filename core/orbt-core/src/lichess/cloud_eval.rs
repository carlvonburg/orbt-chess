//! Lichess cloud evaluations (no token needed): the request, the answer, and the session
//! cache. A 404 means Lichess has no eval for the position, which is remembered; other
//! failures (rate limit, server error, offline) are not, so the next look asks again.

use std::collections::HashMap;

use super::HOST;
use crate::chess::Epd;
use crate::http::{HttpRequest, HttpResponse, query_encode};

/// Lines asked for.
pub const MULTI_PV: u32 = 5;

#[derive(Clone, Debug, PartialEq, Eq, serde::Deserialize)]
pub struct Pv {
    /// UCI moves separated by spaces.
    pub moves: String,
    pub cp: Option<i32>,
    pub mate: Option<i32>,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Deserialize)]
pub struct CloudEval {
    pub depth: u32,
    pub pvs: Vec<Pv>,
}

impl CloudEval {
    /// The eval after `uci`, from White's point of view, if it starts one of the lines:
    /// "#3", "#-2", "+0.3", "-1.2".
    pub fn text_for(&self, uci: &str) -> Option<String> {
        let pv = self.pvs.iter().find(|pv| pv.moves.starts_with(uci))?;
        if let Some(mate) = pv.mate {
            return Some(format!("#{mate}"));
        }
        pv.cp.map(|cp| format!("{:+.1}", f64::from(cp) / 100.0))
    }
}

/// `GET /api/cloud-eval?fen=…&multiPv=5`.
pub fn request(epd: &Epd) -> HttpRequest {
    HttpRequest::get(format!(
        "{HOST}/api/cloud-eval?fen={}&multiPv={MULTI_PV}",
        query_encode(&epd.query_fen())
    ))
}

/// What to do for a position.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CloudEvalLookup {
    /// Answered before in this session (None: Lichess has no eval).
    Cached(Option<CloudEval>),
    /// Send this and pass the answer to `CloudEvals::on_response`.
    Fetch(HttpRequest),
}

/// The answers of this session, by position.
#[derive(Debug, Default)]
pub struct CloudEvals {
    cache: HashMap<Epd, Option<CloudEval>>,
}

impl CloudEvals {
    pub fn lookup(&self, epd: &Epd) -> CloudEvalLookup {
        match self.cache.get(epd) {
            Some(eval) => CloudEvalLookup::Cached(eval.clone()),
            None => CloudEvalLookup::Fetch(request(epd)),
        }
    }

    /// The answer to a `CloudEvalLookup::Fetch` (None: no answer, e.g. offline).
    pub fn on_response(&mut self, epd: &Epd, response: Option<&HttpResponse>) -> Option<CloudEval> {
        match response?.status {
            200 => {
                let eval = serde_json::from_slice(&response?.body).ok();
                self.cache.insert(epd.clone(), eval.clone());
                eval
            }
            404 => {
                self.cache.insert(epd.clone(), None);
                None
            }
            // Rate limited or a server error: ask again next time.
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chess::ChessPosition;

    fn start() -> Epd {
        ChessPosition::start().epd()
    }

    const ANSWER: &str = r#"{"fen":"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1","knodes":100,"depth":42,"pvs":[{"moves":"e2e4 e7e5","cp":25},{"moves":"d2d4 d7d5","cp":-7},{"moves":"g2g4 e7e5","mate":-12}]}"#;

    #[test]
    fn request_url() {
        assert_eq!(
            request(&start()).url,
            "https://lichess.org/api/cloud-eval?fen=rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR%20w%20KQkq%20-%200%201&multiPv=5"
        );
        assert!(request(&start()).headers.is_empty());
    }

    #[test]
    fn answers_and_text() {
        let mut evals = CloudEvals::default();
        let CloudEvalLookup::Fetch(_) = evals.lookup(&start()) else {
            panic!("not asked yet")
        };
        let eval = evals
            .on_response(&start(), Some(&HttpResponse::new(200, ANSWER)))
            .unwrap();
        assert_eq!(eval.depth, 42);
        assert_eq!(eval.text_for("e2e4").as_deref(), Some("+0.2"));
        assert_eq!(eval.text_for("d2d4").as_deref(), Some("-0.1"));
        assert_eq!(eval.text_for("g2g4").as_deref(), Some("#-12"));
        assert_eq!(eval.text_for("c2c4"), None);
        assert_eq!(evals.lookup(&start()), CloudEvalLookup::Cached(Some(eval)));
    }

    #[test]
    fn a_404_is_remembered_other_failures_are_not() {
        let mut evals = CloudEvals::default();
        let e4 = ChessPosition::start().play_san("e4").unwrap().1.epd();
        assert_eq!(
            evals.on_response(&e4, Some(&HttpResponse::new(429, Vec::new()))),
            None
        );
        assert_eq!(evals.on_response(&e4, None), None);
        assert!(matches!(evals.lookup(&e4), CloudEvalLookup::Fetch(_)));
        evals.on_response(&e4, Some(&HttpResponse::new(404, Vec::new())));
        assert_eq!(evals.lookup(&e4), CloudEvalLookup::Cached(None));
    }
}
