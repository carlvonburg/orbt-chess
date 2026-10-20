// Ported from Anki, rslib/src/scheduler/states/interval_kind.rs (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

use super::SECS_PER_DAY;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum IntervalKind {
    Secs(i64),
    Days(i64),
}

impl IntervalKind {
    /// Converts second-based intervals that pass the day boundary into days.
    pub fn maybe_as_days(self, secs_until_rollover: i64) -> IntervalKind {
        match self {
            IntervalKind::Secs(secs) if secs >= secs_until_rollover => {
                IntervalKind::Days((secs - secs_until_rollover) / SECS_PER_DAY + 1)
            }
            other => other,
        }
    }

    /// Revlog encoding: positive days, negative seconds.
    pub fn as_revlog_interval(self) -> i64 {
        match self {
            IntervalKind::Days(days) => days,
            IntervalKind::Secs(secs) => -secs,
        }
    }
}
