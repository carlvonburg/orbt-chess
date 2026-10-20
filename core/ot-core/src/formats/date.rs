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

    /// Accepts `YYYY-MM-DDTHH:MM:SS`, optional fraction, then `Z` or `±HH:MM`.
    fn from_str(s: &str) -> Result<Timestamp, String> {
        let bad = || format!("not an ISO 8601 date: {s}");
        let b = s.as_bytes();
        if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' {
            return Err(bad());
        }
        let num = |range: std::ops::Range<usize>| -> Result<i64, String> {
            s.get(range).and_then(|t| t.parse().ok()).ok_or_else(bad)
        };
        let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
        let (h, mi, sec) = (num(11..13)?, num(14..16)?, num(17..19)?);
        let mut i = 19;
        let mut millis = 0;
        if b.get(i) == Some(&b'.') {
            let start = i + 1;
            i = start;
            while i < b.len() && b[i].is_ascii_digit() {
                i += 1;
            }
            let frac = &s[start..i];
            let padded = format!("{frac:0<3}");
            millis = padded[..3].parse::<i64>().map_err(|_| bad())?;
        }
        let offset_secs = match &s[i..] {
            "Z" | "z" => 0,
            tz if tz.len() == 6 && (tz.starts_with('+') || tz.starts_with('-')) => {
                let sign = if tz.starts_with('-') { -1 } else { 1 };
                let oh: i64 = tz[1..3].parse().map_err(|_| bad())?;
                let om: i64 = tz[4..6].parse().map_err(|_| bad())?;
                sign * (oh * 3600 + om * 60)
            }
            _ => return Err(bad()),
        };
        let secs = days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + sec - offset_secs;
        Ok(Timestamp(secs * 1000 + millis))
    }
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
    }
}
