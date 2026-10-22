//! UCI, the text protocol of Stockfish and Leela: the commands we send and the lines the
//! engine answers with. Only what analysis needs; unknown tokens and lines are skipped, and
//! no input makes the parser panic (the engine's output is read on every search).

/// An evaluation from the point of view of the side it is given for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Score {
    /// Centipawns.
    Cp(i32),
    /// Moves to mate; negative when the side is mated.
    Mate(i32),
}

impl Score {
    /// The same evaluation from the other side's point of view.
    pub fn negated(self) -> Score {
        match self {
            Score::Cp(cp) => Score::Cp(cp.saturating_neg()),
            Score::Mate(n) => Score::Mate(n.saturating_neg()),
        }
    }

    /// "+0.3", "-1.2", "#3", "#-2", as `CloudEval::text_for` writes it.
    pub fn text(self) -> String {
        match self {
            Score::Cp(cp) => format!("{:+.1}", f64::from(cp) / 100.0),
            Score::Mate(n) => format!("#{n}"),
        }
    }
}

/// A score that is only a bound (the search failed high or low on this iteration).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Bound {
    Lower,
    Upper,
}

/// One `info` line. Missing fields are None; `multipv` is 1 when the engine leaves it out.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EngineInfo {
    pub depth: Option<u32>,
    pub seldepth: Option<u32>,
    pub multipv: u32,
    /// From the point of view of the side to move.
    pub score: Option<Score>,
    pub bound: Option<Bound>,
    /// Win, draw, loss per mille for the side to move (`UCI_ShowWDL`, Leela's default).
    pub wdl: Option<[u32; 3]>,
    pub nodes: Option<u64>,
    pub nps: Option<u64>,
    pub time_ms: Option<u64>,
    /// UCI moves.
    pub pv: Vec<String>,
}

/// A line the engine wrote.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EngineOutput {
    /// `id name …` or `id author …`.
    Id {
        key: String,
        value: String,
    },
    /// `option name … type …`: only the name is kept.
    Option {
        name: String,
    },
    UciOk,
    ReadyOk,
    Info(EngineInfo),
    /// `bestmove e2e4 [ponder e7e5]`; None for `bestmove (none)` (no legal move).
    BestMove(Option<String>),
    /// Anything else (`info string …`, banners, blank lines).
    Other,
}

/// Parses one line of engine output.
pub fn parse_line(line: &str) -> EngineOutput {
    let mut tokens = line.split_whitespace();
    match tokens.next() {
        Some("uciok") => EngineOutput::UciOk,
        Some("readyok") => EngineOutput::ReadyOk,
        Some("bestmove") => EngineOutput::BestMove(
            tokens
                .next()
                .filter(|m| *m != "(none)" && *m != "0000")
                .map(str::to_owned),
        ),
        Some("id") => match tokens.next() {
            Some(key) => EngineOutput::Id {
                key: key.to_owned(),
                value: tokens.collect::<Vec<_>>().join(" "),
            },
            None => EngineOutput::Other,
        },
        Some("option") => {
            if tokens.next() != Some("name") {
                return EngineOutput::Other;
            }
            let name: Vec<&str> = tokens.take_while(|t| *t != "type").collect();
            EngineOutput::Option {
                name: name.join(" "),
            }
        }
        Some("info") => {
            let tokens: Vec<&str> = tokens.collect();
            if tokens.first() == Some(&"string") {
                EngineOutput::Other
            } else {
                EngineOutput::Info(parse_info(&tokens))
            }
        }
        _ => EngineOutput::Other,
    }
}

fn parse_info(tokens: &[&str]) -> EngineInfo {
    let mut info = EngineInfo {
        multipv: 1,
        ..EngineInfo::default()
    };
    let number = |i: usize| tokens.get(i).and_then(|t| t.parse::<u64>().ok());
    let small = |i: usize| number(i).and_then(|n| u32::try_from(n).ok());
    let mut i = 0;
    while i < tokens.len() {
        match tokens[i] {
            "depth" => info.depth = small(i + 1),
            "seldepth" => info.seldepth = small(i + 1),
            "multipv" => info.multipv = small(i + 1).unwrap_or(1).max(1),
            "nodes" => info.nodes = number(i + 1),
            "nps" => info.nps = number(i + 1),
            "time" => info.time_ms = number(i + 1),
            "score" => {
                let value = tokens.get(i + 2).and_then(|t| t.parse::<i32>().ok());
                info.score = match (tokens.get(i + 1), value) {
                    (Some(&"cp"), Some(cp)) => Some(Score::Cp(cp)),
                    (Some(&"mate"), Some(n)) => Some(Score::Mate(n)),
                    _ => None,
                };
                i += 2;
                match tokens.get(i + 1) {
                    Some(&"lowerbound") => info.bound = Some(Bound::Lower),
                    Some(&"upperbound") => info.bound = Some(Bound::Upper),
                    _ => {}
                }
            }
            "wdl" => {
                if let (Some(w), Some(d), Some(l)) = (small(i + 1), small(i + 2), small(i + 3)) {
                    info.wdl = Some([w, d, l]);
                }
                i += 3;
            }
            "pv" => {
                info.pv = tokens[i + 1..].iter().map(|m| (*m).to_owned()).collect();
                break;
            }
            // The rest of the line is free text.
            "string" => break,
            _ => {}
        }
        i += 1;
    }
    info
}

/// A command to write to the engine, one line each.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EngineCommand {
    Uci,
    IsReady,
    SetOption {
        name: String,
        value: String,
    },
    UciNewGame,
    /// `position fen <fen> moves <uci…>`.
    Position {
        fen: String,
        moves: Vec<String>,
    },
    /// `go movetime <ms>`, or `go infinite` without a time.
    Go {
        movetime_ms: Option<u32>,
    },
    Stop,
    Quit,
}

impl EngineCommand {
    /// The line to write, without the newline.
    pub fn line(&self) -> String {
        match self {
            EngineCommand::Uci => "uci".into(),
            EngineCommand::IsReady => "isready".into(),
            EngineCommand::SetOption { name, value } => {
                format!("setoption name {name} value {value}")
            }
            EngineCommand::UciNewGame => "ucinewgame".into(),
            EngineCommand::Position { fen, moves } if moves.is_empty() => {
                format!("position fen {fen}")
            }
            EngineCommand::Position { fen, moves } => {
                format!("position fen {fen} moves {}", moves.join(" "))
            }
            EngineCommand::Go {
                movetime_ms: Some(ms),
            } => format!("go movetime {ms}"),
            EngineCommand::Go { movetime_ms: None } => "go infinite".into(),
            EngineCommand::Stop => "stop".into(),
            EngineCommand::Quit => "quit".into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_stockfish_info_line() {
        let line = "info depth 22 seldepth 31 multipv 2 score cp -17 upperbound nodes 2104330 nps 1050000 hashfull 412 tbhits 0 time 2004 pv d7d5 e4d5 d8d5";
        let EngineOutput::Info(info) = parse_line(line) else {
            panic!("not info")
        };
        assert_eq!(info.depth, Some(22));
        assert_eq!(info.seldepth, Some(31));
        assert_eq!(info.multipv, 2);
        assert_eq!(info.score, Some(Score::Cp(-17)));
        assert_eq!(info.bound, Some(Bound::Upper));
        assert_eq!(info.nodes, Some(2_104_330));
        assert_eq!(info.time_ms, Some(2004));
        assert_eq!(info.pv, ["d7d5", "e4d5", "d8d5"]);
    }

    #[test]
    fn parses_mate_wdl_and_bestmove() {
        let EngineOutput::Info(info) =
            parse_line("info depth 5 score mate -3 wdl 0 0 1000 pv a1a2")
        else {
            panic!("not info")
        };
        assert_eq!(info.score, Some(Score::Mate(-3)));
        assert_eq!(info.wdl, Some([0, 0, 1000]));
        assert_eq!(info.multipv, 1);
        assert_eq!(
            parse_line("bestmove e2e4 ponder e7e5"),
            EngineOutput::BestMove(Some("e2e4".into()))
        );
        assert_eq!(parse_line("bestmove (none)"), EngineOutput::BestMove(None));
        assert_eq!(
            parse_line("info string NNUE evaluation using nn.nnue"),
            EngineOutput::Other
        );
        assert_eq!(
            parse_line("option name Clear Hash type button"),
            EngineOutput::Option {
                name: "Clear Hash".into()
            }
        );
    }

    #[test]
    fn garbage_does_not_panic() {
        for line in [
            "",
            "info",
            "info score",
            "info score cp",
            "info wdl 1 2",
            "info multipv 0 pv",
            "id",
            "option",
            "bestmove",
        ] {
            let _ = parse_line(line);
        }
    }

    #[test]
    fn writes_commands() {
        assert_eq!(
            EngineCommand::Position {
                fen: "8/8/8/8/8/8/8/K1k5 w - - 0 1".into(),
                moves: vec!["a1a2".into()]
            }
            .line(),
            "position fen 8/8/8/8/8/8/8/K1k5 w - - 0 1 moves a1a2"
        );
        assert_eq!(
            EngineCommand::Go {
                movetime_ms: Some(6000)
            }
            .line(),
            "go movetime 6000"
        );
        assert_eq!(
            EngineCommand::SetOption {
                name: "MultiPV".into(),
                value: "3".into()
            }
            .line(),
            "setoption name MultiPV value 3"
        );
    }

    #[test]
    fn score_text_matches_cloud_evals() {
        assert_eq!(Score::Cp(25).text(), "+0.2");
        assert_eq!(Score::Cp(-120).text(), "-1.2");
        assert_eq!(Score::Mate(-2).text(), "#-2");
        assert_eq!(Score::Mate(3).negated(), Score::Mate(-3));
    }
}
