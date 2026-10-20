//! ISO 8601 dates in UTC with milliseconds ("2026-10-20T10:04:12.515Z"). No timezone database: these are instants, and only UTC is written.

use std::fmt;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// An instant, in milliseconds since 1970.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Timestamp(pub i64);

impl Timestamp {
    pub fn from_secs(secs: i64) -> Timestamp {
        Timestamp(secs * 1000)
    }

    pub fn secs(self) -> i64 {
        self.0.div_euclid(1000)
    }
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

impl fmt::Display for Timestamp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let millis = self.0.rem_euclid(1000);
        let secs = self.0.div_euclid(1000);
        let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
        let (y, m, d) = civil_from_days(days);
        write!(
            f,
            "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{millis:03}Z",
            rem / 3600,
            rem % 3600 / 60,
            rem % 60
        )
    }
}

impl std::str::FromStr for Timestamp {
    type Err = String;

    /// Accepts `YYYY-MM-DDTHH:MM:SS`, optional fraction, then `Z` or `±HH:MM`. Works on bytes
    /// and checks every field's range: the text comes from files that may be corrupt.
    fn from_str(s: &str) -> Result<Timestamp, String> {
        parse(s.as_bytes()).ok_or_else(|| format!("not an ISO 8601 date: {s}"))
    }
}

/// The number in `b[range]`, if it is all ASCII digits and within `min..=max`.
fn number(b: &[u8], range: std::ops::Range<usize>, min: i64, max: i64) -> Option<i64> {
    let digits = b.get(range)?;
    if !digits.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let n = digits.iter().fold(0, |n, &d| n * 10 + i64::from(d - b'0'));
    (min..=max).contains(&n).then_some(n)
}

fn days_in_month(y: i64, m: i64) -> i64 {
    match m {
        2 if y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

fn parse(b: &[u8]) -> Option<Timestamp> {
    let separators = [(4, b'-'), (7, b'-'), (10, b'T'), (13, b':'), (16, b':')];
    if separators.iter().any(|&(i, c)| b.get(i) != Some(&c)) {
        return None;
    }
    let y = number(b, 0..4, 0, 9999)?;
    let mo = number(b, 5..7, 1, 12)?;
    let d = number(b, 8..10, 1, days_in_month(y, mo))?;
    let h = number(b, 11..13, 0, 23)?;
    let mi = number(b, 14..16, 0, 59)?;
    let sec = number(b, 17..19, 0, 59)?;
    let mut i = 19;
    let mut millis = 0;
    if b.get(i) == Some(&b'.') {
        i += 1;
        let start = i;
        while b.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        // Milliseconds from the first three digits, padded with zeros.
        for k in 0..3 {
            let digit = if start + k < i {
                b[start + k] - b'0'
            } else {
                0
            };
            millis = millis * 10 + i64::from(digit);
        }
    }
    let offset_secs = match &b[i..] {
        b"Z" | b"z" => 0,
        [sign @ (b'+' | b'-'), _, _, b':', _, _] => {
            let tz = &b[i..];
            let secs = number(tz, 1..3, 0, 23)? * 3600 + number(tz, 4..6, 0, 59)? * 60;
            if *sign == b'-' { -secs } else { secs }
        }
        _ => return None,
    };
    let secs = days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + sec - offset_secs;
    Some(Timestamp(secs * 1000 + millis))
}

impl Serialize for Timestamp {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for Timestamp {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Timestamp, D::Error> {
        let s = String::deserialize(deserializer)?;
        s.parse().map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::Timestamp;

    #[test]
    fn round_trips() {
        let t: Timestamp = "2026-10-20T10:04:12.515Z".parse().unwrap();
        assert_eq!(t.to_string(), "2026-10-20T10:04:12.515Z");
        assert_eq!(t.secs(), 1_792_490_652);
        let plain: Timestamp = "2026-10-20T12:04:12+02:00".parse().unwrap();
        assert_eq!(plain.0, t.0 - 515);
        assert_eq!(Timestamp(0).to_string(), "1970-01-01T00:00:00.000Z");
        assert_eq!(
            "2024-02-29T23:59:59.9Z"
                .parse::<Timestamp>()
                .unwrap()
                .to_string(),
            "2024-02-29T23:59:59.900Z"
        );
        assert_eq!(
            "2026-10-20T10:04:12.Z".parse::<Timestamp>().unwrap().0,
            t.0 - 515
        );
    }

    #[test]
    fn rejects_malformed_dates_without_panicking() {
        for bad in [
            "2026-10-20T10:04:12+0\u{e9}00",
            "2026-10-20T10:04:12+\u{e9}:00",
            "2026-10-20T10:04:12.5\u{e9}Z",
            "\u{e9}026-10-20T10:04:12Z",
            "2026-13-20T10:04:12Z",
            "2026-00-20T10:04:12Z",
            "2026-02-29T10:04:12Z",
            "2026-04-31T10:04:12Z",
            "2026-10-20T24:04:12Z",
            "2026-10-20T10:60:12Z",
            "2026-10-20T10:04:60Z",
            "2026-10-20T10:04:12+24:00",
            "2026-10-20T10:04:12+02:60",
            "2026-+1-20T10:04:12Z",
            "2026-10-20T10:04:12",
            "2026-10-20T10:04:12ZZ",
            "2026-10-20 10:04:12Z",
            "",
        ] {
            assert!(bad.parse::<Timestamp>().is_err(), "{bad}");
        }
    }
}
