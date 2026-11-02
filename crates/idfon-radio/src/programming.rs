//! The schedule: which clip plays, and when.
//!
//! The schedule is data (`agents/radio/schedule.json`): slots carry a local
//! start time, the weekdays they start on, and the clip that fills the slot.
//! A slot holds the air until the next one starts, wrapping past midnight; with
//! no slot active the programme falls back to its fallback clip.
//!
//! Time is the station's own: this module knows nothing about transports,
//! calls, or who is listening.

use std::path::{Path, PathBuf};

use anyhow::{ensure, Context, Result};
use chrono::{Datelike, Days, NaiveDate, NaiveDateTime, NaiveTime, Weekday};
use serde_json::Value;

/// One programme slot. Fills the air from `at` until the next slot starts.
#[derive(Clone)]
pub struct Slot {
    pub at: NaiveTime,
    /// `None` = every day (the JSON omits `days`, or says `"*"`).
    pub days: Option<Vec<Weekday>>,
    pub clip: PathBuf,
    pub topic: Option<String>,
    pub title: Option<String>,
    /// How the clip got here: `submitted`, or the episode URL it was fetched
    /// from. Recorded so a soak log says where the audio came from.
    pub origin: Option<String>,
    /// The submitter's pitch. The schedule does not act on it; a radio jockey
    /// (elsewhere) reads it, and the log carries it with the slot.
    pub note: Option<String>,
}

#[derive(Clone)]
pub struct Schedule {
    slots: Vec<Slot>,
}

impl Schedule {
    pub fn load(path: &Path) -> Result<Self> {
        let bytes =
            std::fs::read(path).with_context(|| format!("read schedule {}", path.display()))?;
        let value: Value = serde_json::from_slice(&bytes)
            .with_context(|| format!("parse schedule {}", path.display()))?;
        // Slot `file` paths are relative to the schedule, so a content folder
        // beside it works wherever the repo is checked out.
        Self::parse(&value, path.parent().unwrap_or(Path::new(".")))
    }

    pub fn parse(value: &Value, base: &Path) -> Result<Self> {
        let entries = value
            .get("slots")
            .and_then(Value::as_array)
            .context("schedule has no `slots` array")?;
        let mut slots = Vec::with_capacity(entries.len());
        for entry in entries {
            let at = entry
                .get("at")
                .and_then(Value::as_str)
                .context("slot has no `at`")?;
            let at = NaiveTime::parse_from_str(at.trim(), "%H:%M")
                .with_context(|| format!("slot `at` must be HH:MM, got {at:?}"))?;
            let clip = entry
                .get("file")
                .and_then(Value::as_str)
                .filter(|file| !file.is_empty())
                .context("slot has no `file`")?;
            slots.push(Slot {
                at,
                days: days(entry.get("days"))?,
                clip: base.join(clip),
                topic: text(entry, "topic"),
                title: text(entry, "title"),
                origin: text(entry, "origin"),
                note: text(entry, "note"),
            });
        }
        Ok(Self { slots })
    }

    pub fn len(&self) -> usize {
        self.slots.len()
    }

    /// The slot whose start is the latest at or before `now` (within a day).
    pub fn active(&self, now: NaiveDateTime) -> Option<(&Slot, NaiveDateTime)> {
        let mut best: Option<(&Slot, NaiveDateTime)> = None;
        for date in [now.date().checked_sub_days(Days::new(1)), Some(now.date())]
            .into_iter()
            .flatten()
        {
            for slot in &self.slots {
                if !slot.starts_on(date) {
                    continue;
                }
                let start = date.and_time(slot.at);
                if start <= now && best.map_or(true, |(_, best)| start >= best) {
                    best = Some((slot, start));
                }
            }
        }
        best
    }

    /// When the next slot starts, for the record. None when nothing is queued.
    pub fn next_after(&self, now: NaiveDateTime) -> Option<NaiveDateTime> {
        let mut next: Option<NaiveDateTime> = None;
        for date in [Some(now.date()), now.date().checked_add_days(Days::new(1))]
            .into_iter()
            .flatten()
        {
            for slot in &self.slots {
                if !slot.starts_on(date) {
                    continue;
                }
                let start = date.and_time(slot.at);
                if start > now && next.map_or(true, |next| start < next) {
                    next = Some(start);
                }
            }
        }
        next
    }
}

impl Slot {
    /// `days` gates the *start*, so a slot that starts Monday 23:00 is still
    /// the active programme on Tuesday 00:30.
    fn starts_on(&self, date: NaiveDate) -> bool {
        self.days
            .as_ref()
            .is_none_or(|days| days.contains(&date.weekday()))
    }
}

fn days(value: Option<&Value>) -> Result<Option<Vec<Weekday>>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(any)) if any == "*" => Ok(None),
        Some(Value::Array(values)) => {
            let mut days = Vec::with_capacity(values.len());
            for value in values {
                days.push(
                    weekday(value.as_str().with_context(|| {
                        format!("slot `days` entries must be strings, got {value}")
                    })?)
                    .with_context(|| format!("unknown weekday in slot `days`: {value}"))?,
                );
            }
            ensure!(!days.is_empty(), "slot `days` must not be an empty array");
            Ok(Some(days))
        }
        Some(other) => anyhow::bail!("slot `days` must be \"*\" or an array, got {other}"),
    }
}

/// `mon`/`monday`, case-insensitive.
fn weekday(name: &str) -> Result<Weekday> {
    let name = name.trim().to_ascii_lowercase();
    Ok(match name.as_str() {
        "mon" | "monday" => Weekday::Mon,
        "tue" | "tuesday" => Weekday::Tue,
        "wed" | "wednesday" => Weekday::Wed,
        "thu" | "thursday" => Weekday::Thu,
        "fri" | "friday" => Weekday::Fri,
        "sat" | "saturday" => Weekday::Sat,
        "sun" | "sunday" => Weekday::Sun,
        _ => anyhow::bail!("unknown weekday {name:?}"),
    })
}

fn text(entry: &Value, key: &str) -> Option<String> {
    entry
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    fn schedule() -> Schedule {
        let json = serde_json::json!({
            "slots": [
                // `synthetic`/`note` are written by scripts/radio-program.mjs;
                // unknown keys must stay ignored, not rejected.
                { "at": "07:00", "days": ["mon"], "file": "a.wav", "topic": "tech",
                  "note": "pitch", "synthetic": true },
                { "at": "19:30", "file": "b.wav" },
                { "at": "23:00", "days": ["mon"], "file": "c.wav" }
            ]
        });
        Schedule::parse(&json, Path::new("/content")).expect("schedule")
    }

    fn at(day: u32, hour: u32, minute: u32) -> NaiveDateTime {
        NaiveDate::from_ymd_opt(2026, 11, day)
            .expect("date")
            .and_hms_opt(hour, minute, 0)
            .expect("time")
    }

    // 2026-11-02 is a Monday.
    #[test]
    fn the_latest_started_slot_wins() {
        let schedule = schedule();
        assert_eq!(schedule.active(at(2, 8, 0)).map(|(slot, _)| slot.clip.clone()),
                   Some(PathBuf::from("/content/a.wav")));
        assert_eq!(schedule.active(at(2, 20, 0)).map(|(slot, _)| slot.clip.clone()),
                   Some(PathBuf::from("/content/b.wav")));
    }

    #[test]
    fn a_slot_holds_until_the_next_start() {
        let schedule = schedule();
        // Before Monday 07:00 there is nothing yet on Monday, and Sunday's
        // every-day 19:30 slot still holds the air.
        assert_eq!(schedule.active(at(2, 6, 0)).map(|(slot, _)| slot.clip.clone()),
                   Some(PathBuf::from("/content/b.wav")));
    }

    #[test]
    fn days_gate_the_start_not_the_hold() {
        let schedule = schedule();
        // Monday 23:00 started on Monday, so it is still the programme at
        // Tuesday 00:30 even though Tuesday is not in `days`.
        assert_eq!(schedule.active(at(3, 0, 30)).map(|(slot, _)| slot.clip.clone()),
                   Some(PathBuf::from("/content/c.wav")));
        // An empty programme on a day with no start and no carry-over.
        let weekdays_only = Schedule::parse(
            &serde_json::json!({ "slots": [{ "at": "07:00", "days": ["mon"], "file": "a.wav" }] }),
            Path::new("/content"),
        )
        .expect("schedule");
        assert!(weekdays_only.active(at(4, 8, 0)).is_none());
    }

    #[test]
    fn reports_the_next_start() {
        let schedule = schedule();
        assert_eq!(schedule.next_after(at(2, 8, 0)), Some(at(2, 19, 30)));
        assert_eq!(schedule.next_after(at(2, 20, 0)), Some(at(2, 23, 0)));
        // Monday 23:30: Tuesday's every-day 19:30 comes first; the Monday-only
        // 07:00 start is a week out.
        assert_eq!(schedule.next_after(at(2, 23, 30)), Some(at(3, 19, 30)));
        assert_eq!(schedule.next_after(at(3, 20, 0)), Some(at(4, 19, 30)));
    }

    #[test]
    fn rejects_a_slot_without_a_time_or_file() {
        let no_time = serde_json::json!({ "slots": [{ "file": "a.wav" }] });
        assert!(Schedule::parse(&no_time, Path::new(".")).is_err());
        let no_file = serde_json::json!({ "slots": [{ "at": "07:00" }] });
        assert!(Schedule::parse(&no_file, Path::new(".")).is_err());
        let bad_time = serde_json::json!({ "slots": [{ "at": "7am", "file": "a.wav" }] });
        assert!(Schedule::parse(&bad_time, Path::new(".")).is_err());
    }
}
