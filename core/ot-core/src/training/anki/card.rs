// Mirrors Anki's card scheduling fields (rslib/src/card/mod.rs) and revlog entry
// (rslib/src/revlog/mod.rs), https://github.com/ankitects/anki.
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

use serde::{Deserialize, Serialize};

use super::RevlogReviewKind;
use crate::chess::Epd;

/// FSRS memory state: stability in days, difficulty 1...10.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct MemoryState {
    pub stability: f64,
    pub difficulty: f64,
}

/// The f32 FSRS works in, read back as the shortest decimal, so files hold "2.3065" and
/// not "2.306499958038330".
fn widen(x: f32) -> f64 {
    x.to_string().parse().unwrap_or(f64::from(x))
}

impl MemoryState {
    /// Anki's revlog "factor" under FSRS: (D - 1) / 9 + 0.1.
    pub fn difficulty_shifted(&self) -> f64 {
        (self.difficulty - 1.0) / 9.0 + 0.1
    }

    pub(crate) fn to_fsrs(self) -> fsrs::MemoryState {
        fsrs::MemoryState {
            stability: self.stability as f32,
            difficulty: self.difficulty as f32,
        }
    }

    pub(crate) fn from_fsrs(m: fsrs::MemoryState) -> MemoryState {
        MemoryState {
            stability: widen(m.stability),
            difficulty: widen(m.difficulty),
        }
    }
}

macro_rules! int_enum {
    ($name:ident { $($variant:ident = $value:expr),+ $(,)? }) => {
        #[derive(
            Clone, Copy, Debug, PartialEq, Eq, Hash, ::serde::Serialize, ::serde::Deserialize,
        )]
        #[serde(into = "i64", try_from = "i64")]
        pub enum $name {
            $($variant),+
        }

        impl From<$name> for i64 {
            fn from(v: $name) -> i64 {
                match v {
                    $($name::$variant => $value),+
                }
            }
        }

        impl TryFrom<i64> for $name {
            type Error = String;

            fn try_from(v: i64) -> Result<$name, String> {
                match v {
                    $(x if x == $value => Ok($name::$variant),)+
                    other => Err(format!("invalid {} {}", stringify!($name), other)),
                }
            }
        }
    };
}

int_enum!(CardType {
    New = 0,
    Learn = 1,
    Review = 2,
    Relearn = 3,
});

int_enum!(CardQueue {
    Suspended = -1,
    New = 0,
    Learn = 1,
    Review = 2,
    DayLearn = 3,
});

pub(crate) use int_enum;

/// The study state of one card: a position where it's your move. A card that was never
/// studied is New and has no stored `Card`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Card {
    pub id: i64,
    pub ctype: CardType,
    pub queue: CardQueue,
    /// Learn queue: unix seconds. Review and day-learn queues: day number. New: position.
    pub due: i64,
    /// Days.
    pub interval: i64,
    /// Permille, 2500 = 2.5.
    pub ease_factor: i64,
    pub reps: i64,
    pub lapses: i64,
    pub remaining_steps: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub memory: Option<MemoryState>,
    /// Unix seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_review_time: Option<i64>,
    /// New-queue position before the card was first studied.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original_position: Option<i64>,
    /// Unix seconds when the card was first studied (Anki: card creation).
    pub added: i64,
    /// Anki's "leech" tag.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub leech: Option<bool>,
}

impl Card {
    pub fn new(id: i64, position: i64, added: i64) -> Card {
        Card {
            id,
            ctype: CardType::New,
            queue: CardQueue::New,
            due: position,
            interval: 0,
            ease_factor: 0,
            reps: 0,
            lapses: 0,
            remaining_steps: 0,
            memory: None,
            last_review_time: None,
            original_position: None,
            added,
            leech: None,
        }
    }

    /// Stable id from the position (FNV-1a, 63 bits), so every device agrees.
    pub fn id_for(epd: &Epd) -> i64 {
        let mut hash: u64 = 0xCBF2_9CE4_8422_2325;
        for byte in epd.as_str().bytes() {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01B3);
        }
        (hash & 0x7FFF_FFFF_FFFF_FFFF) as i64
    }

    /// Anki's `restore_queue_after_bury_or_suspend`: the queue follows the card type; a
    /// learning card whose due is a timestamp is intraday, otherwise interday.
    pub fn restore_queue(&mut self) {
        self.queue = match self.ctype {
            CardType::New => CardQueue::New,
            CardType::Learn | CardType::Relearn => {
                if self.due > 1_000_000_000 {
                    CardQueue::Learn
                } else {
                    CardQueue::DayLearn
                }
            }
            CardType::Review => CardQueue::Review,
        };
    }

    /// Anki: interval ≥ 21 days.
    pub fn is_mature(&self) -> bool {
        matches!(self.ctype, CardType::Review | CardType::Relearn) && self.interval >= 21
    }

    pub fn is_learning(&self) -> bool {
        matches!(self.queue, CardQueue::Learn | CardQueue::DayLearn)
    }

    /// Probability of recall at `now` (unix seconds), from FSRS.
    pub fn retrievability(&self, now: f64) -> Option<f64> {
        let memory = self.memory?;
        let last = self.last_review_time?;
        let days = (now - last as f64).max(0.0) / 86_400.0;
        Some(f64::from(fsrs::current_retrievability(
            memory.to_fsrs(),
            days as f32,
            fsrs::DEFAULT_PARAMETERS[20],
        )))
    }
}

/// One answer, as in Anki's revlog table.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RevlogEntry {
    /// Milliseconds since 1970 when answered; the key.
    pub id: i64,
    /// The card's EPD.
    pub cid: Epd,
    /// 1 again, 2 hard, 3 good, 4 easy; 0 for a manual change.
    pub ease: i64,
    /// After the answer: positive days, negative seconds.
    pub ivl: i64,
    pub last_ivl: i64,
    /// FSRS difficulty shifted, ×1000; or the ease factor in permille.
    pub factor: i64,
    /// Answer time in milliseconds, capped.
    pub time: i64,
    #[serde(rename = "type")]
    pub kind: RevlogReviewKind,
}

impl RevlogEntry {
    pub fn has_rating(&self) -> bool {
        self.ease > 0
    }

    /// Cramming entries don't affect scheduling.
    pub fn is_cramming(&self) -> bool {
        self.kind == RevlogReviewKind::Filtered && self.factor == 0
    }
}
