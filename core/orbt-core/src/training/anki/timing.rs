// Ported from Anki, rslib/src/scheduler/timing.rs (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// Difference: Anki counts days from the collection's creation; this counts from a fixed epoch
// (1 Jan 2020, local time), so every device and repertoire agrees on day numbers. The day
// number needs the local calendar, so the platform computes it (as Anki takes the UTC offset
// from its caller) and passes the three values in.

pub const SECS_PER_DAY: i64 = 86_400;

/// "Today" for scheduling: the day number and when the next day starts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SchedTiming {
    /// Days since the epoch, rolling over at `ROLLOVER_HOUR`.
    pub days_elapsed: i64,
    /// Unix seconds when the next day starts.
    pub next_day_at: i64,
    /// Unix seconds.
    pub now: i64,
}

impl SchedTiming {
    pub const ROLLOVER_HOUR: i64 = 4;

    pub fn new(days_elapsed: i64, next_day_at: i64, now: i64) -> SchedTiming {
        SchedTiming {
            days_elapsed,
            next_day_at,
            now,
        }
    }

    pub fn secs_until_rollover(&self) -> i64 {
        (self.next_day_at - self.now).max(0)
    }

    /// Unix seconds when today started.
    pub fn day_start(&self) -> i64 {
        self.next_day_at - SECS_PER_DAY
    }

    /// Whole days from `secs` to the next day start (Anki `elapsed_days_since`).
    pub fn days_since(&self, secs: i64) -> i64 {
        ((self.next_day_at - secs) / SECS_PER_DAY).max(0)
    }

    /// Unix seconds when a day number starts (approximately, ignoring clock changes).
    pub fn start_of_day(&self, day: i64) -> i64 {
        self.day_start() + (day - self.days_elapsed) * SECS_PER_DAY
    }
}
