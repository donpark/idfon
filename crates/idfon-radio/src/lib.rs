//! A talk-radio station's programme: the schedule, its clips, and the frames a
//! transport pumps.
//!
//! This crate is the station. It owns what plays and when, and it knows nothing
//! about who is listening: an idfon one-way call is one adapter, an HLS or HTTP
//! stream would be another. Both consume the same port — [`Programme::sync`]
//! against the clock, then [`Programme::frame`] until the queue is fed.
//!
//! Playback is call-relative — nothing plays until an adapter asks for a frame —
//! so this is a programme, not a timer.

mod clip;
pub mod menu;
pub mod programming;

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant, SystemTime},
};

use anyhow::{ensure, Context, Result};
use chrono::NaiveDateTime;
use serde_json::Value;

use programming::Schedule;

/// The station's output format: 24 kHz mono s16.
pub const OUTPUT_RATE: u32 = 24_000;
/// Frame duration an adapter paces against.
pub const FRAME_MS: u32 = 20;
/// Samples per frame.
pub const FRAME_SAMPLES: usize = (OUTPUT_RATE as usize / 1_000) * FRAME_MS as usize;
/// How often an edited schedule is picked up mid-programme.
const RELOAD_CHECK: Duration = Duration::from_secs(1);

/// What a station is: its schedule, its fallback clip, and whether the fallback
/// loops. Read from the station's own `programme.json`.
#[derive(Debug, Clone, Default)]
pub struct ProgrammeConfig {
    /// Slot table. Absent = the fallback plays always.
    pub schedule: Option<PathBuf>,
    /// What plays when no slot is active.
    pub fallback: Option<PathBuf>,
    /// `false` = the programme ends when a non-looping fallback runs out.
    pub loop_fallback: bool,
    /// What the station is about; a caller may override it per call.
    pub topic: Option<String>,
}

impl ProgrammeConfig {
    /// Read `programme.json`; relative paths resolve against the file.
    pub fn load(path: &Path) -> Result<Self> {
        let bytes =
            std::fs::read(path).with_context(|| format!("read programme {}", path.display()))?;
        let value: Value = serde_json::from_slice(&bytes)
            .with_context(|| format!("parse programme {}", path.display()))?;
        Self::parse(&value, path.parent().unwrap_or(Path::new(".")))
    }

    pub fn parse(value: &Value, base: &Path) -> Result<Self> {
        let path = |key: &str| {
            value
                .get(key)
                .and_then(Value::as_str)
                .filter(|path| !path.is_empty())
                .map(|path| base.join(path))
        };
        let config = Self {
            schedule: path("schedule"),
            fallback: path("file"),
            loop_fallback: value.get("loop").and_then(Value::as_bool).unwrap_or(true),
            topic: value
                .get("topic")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|topic| !topic.is_empty())
                .map(str::to_owned),
        };
        ensure!(
            config.schedule.is_some() || config.fallback.is_some(),
            "programme {} needs a `schedule` or a `file`",
            base.display()
        );
        Ok(config)
    }
}

/// What the programme is playing, for the adapter's record.
#[derive(Debug, Clone, Default)]
pub struct SlotInfo {
    /// Local start, `YYYY-MM-DD HH:MM`, or `fallback`.
    pub at: String,
    pub file: Option<String>,
    pub title: Option<String>,
    pub topic: Option<String>,
    /// `submitted`, `synthetic:<topic>`, or the source URL.
    pub origin: Option<String>,
    pub note: Option<String>,
}

/// Something the adapter may want to record. The station does not log; it says.
#[derive(Debug, Clone)]
pub enum Event {
    /// A schedule edit was loaded mid-programme.
    Schedule { slots: usize },
    /// The programme moved to a different clip.
    Slot(SlotInfo),
    /// Nothing is scheduled and there is no fallback: silence.
    Idle,
    /// A slot clip or a schedule edit could not be used.
    Error { message: String },
}

/// The programme: schedule plus fallback, resolved against the clock.
pub struct Programme {
    schedule_path: Option<PathBuf>,
    schedule: Option<Schedule>,
    modified: Option<SystemTime>,
    checked: Instant,
    fallback_path: Option<PathBuf>,
    fallback: Option<Arc<Vec<i16>>>,
    loop_fallback: bool,
    clips: HashMap<PathBuf, Arc<Vec<i16>>>,
    current: Option<Selection>,
    cursor: usize,
}

struct Selection {
    key: String,
    clip: Arc<Vec<i16>>,
    /// A slot loops to fill its air; the fallback loops only when configured.
    looping: bool,
}

impl Programme {
    /// Open a station. Both inputs load now, so a bad path fails before a
    /// transport starts rather than mid-programme.
    pub fn open(config: ProgrammeConfig) -> Result<Self> {
        let schedule = match &config.schedule {
            Some(path) => Some(Schedule::load(path)?),
            None => None,
        };
        let fallback = match &config.fallback {
            Some(path) => Some(Arc::new(clip::read_wav(path)?)),
            None => None,
        };
        let modified = config
            .schedule
            .as_deref()
            .and_then(|path| std::fs::metadata(path).ok())
            .and_then(|meta| meta.modified().ok());
        Ok(Self {
            schedule_path: config.schedule,
            schedule,
            modified,
            checked: Instant::now(),
            fallback_path: config.fallback,
            fallback,
            loop_fallback: config.loop_fallback,
            clips: HashMap::new(),
            current: None,
            cursor: 0,
        })
    }

    pub fn rate(&self) -> u32 {
        OUTPUT_RATE
    }

    pub fn has_programme(&self) -> bool {
        self.current.is_some()
    }

    /// Pick up a schedule edit and move to the clip `now` calls for. Reports
    /// changes through `log`: an adapter renders them, it does not decide them.
    pub fn sync<F: FnMut(Event)>(&mut self, now: NaiveDateTime, mut log: F) {
        self.reload(&mut log);
        let active = self
            .schedule
            .as_ref()
            .and_then(|schedule| schedule.active(now))
            .map(|(slot, start)| {
                (
                    slot.clip.clone(),
                    start,
                    slot.title.clone(),
                    slot.topic.clone(),
                    slot.origin.clone(),
                    slot.note.clone(),
                )
            });
        let mut next = None;
        if let Some((clip_path, start, title, topic, origin, note)) = active {
            if let Some(clip) = self.clip_for(&clip_path, &mut log) {
                next = Some((
                    format!("slot:{}", clip_path.display()),
                    Selection {
                        key: format!("slot:{}", clip_path.display()),
                        clip,
                        looping: true,
                    },
                    SlotInfo {
                        at: start.format("%Y-%m-%d %H:%M").to_string(),
                        file: Some(clip_path.display().to_string()),
                        title,
                        topic,
                        origin,
                        note,
                    },
                ));
            }
        }
        if next.is_none() {
            if let (Some(path), Some(clip)) = (&self.fallback_path, &self.fallback) {
                next = Some((
                    format!("fallback:{}", path.display()),
                    Selection {
                        key: format!("fallback:{}", path.display()),
                        clip: Arc::clone(clip),
                        looping: self.loop_fallback,
                    },
                    SlotInfo {
                        at: "fallback".to_owned(),
                        file: Some(path.display().to_string()),
                        ..SlotInfo::default()
                    },
                ));
            }
        }
        let key = next.as_ref().map(|(key, _, _)| key.as_str());
        let changed = key != self.current.as_ref().map(|current| current.key.as_str());
        if changed {
            self.cursor = 0;
            match next {
                Some((_, selection, info)) => {
                    log(Event::Slot(info));
                    self.current = Some(selection);
                }
                None => {
                    if self.current.take().is_some() {
                        log(Event::Idle);
                    }
                    self.current = None;
                }
            }
        }
    }

    /// Copy the next frame out. `false` means a non-looping fallback ran out and
    /// the programme is over; a slot always loops.
    pub fn frame(&mut self, out: &mut [i16]) -> bool {
        let Some(selection) = self.current.as_ref() else {
            return true;
        };
        let cursor = &mut self.cursor;
        if *cursor >= selection.clip.len() {
            if !selection.looping {
                return false;
            }
            *cursor = 0;
        }
        let end = (*cursor + out.len()).min(selection.clip.len());
        out[..end - *cursor].copy_from_slice(&selection.clip[*cursor..end]);
        *cursor = end;
        true
    }

    fn reload<F: FnMut(Event)>(&mut self, log: &mut F) {
        if self.checked.elapsed() < RELOAD_CHECK {
            return;
        }
        self.checked = Instant::now();
        let Some(path) = &self.schedule_path else {
            return;
        };
        let Ok(modified) = std::fs::metadata(path).and_then(|meta| meta.modified()) else {
            return;
        };
        if Some(modified) == self.modified {
            return;
        }
        match Schedule::load(path) {
            Ok(schedule) => {
                self.modified = Some(modified);
                log(Event::Schedule {
                    slots: schedule.len(),
                });
                self.schedule = Some(schedule);
            }
            // An editor may be mid-write; keep playing the last good schedule.
            Err(error) => log(Event::Error {
                message: format!("{error:#}"),
            }),
        }
    }

    fn clip_for<F: FnMut(Event)>(&mut self, path: &Path, log: &mut F) -> Option<Arc<Vec<i16>>> {
        if let Some(clip) = self.clips.get(path) {
            return Some(Arc::clone(clip));
        }
        match clip::read_wav(path) {
            Ok(pcm) => {
                let clip = Arc::new(pcm);
                self.clips.insert(path.to_path_buf(), Arc::clone(&clip));
                Some(clip)
            }
            Err(error) => {
                log(Event::Error {
                    message: format!("{error:#}"),
                });
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Local;
    use std::path::PathBuf;

    fn wav(samples: &[i16]) -> Vec<u8> {
        let data: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
        let mut bytes = Vec::new();
        bytes.extend(b"RIFF");
        bytes.extend((36 + data.len() as u32).to_le_bytes());
        bytes.extend(b"WAVEfmt ");
        bytes.extend(16u32.to_le_bytes());
        bytes.extend(1u16.to_le_bytes());
        bytes.extend(1u16.to_le_bytes());
        bytes.extend(OUTPUT_RATE.to_le_bytes());
        bytes.extend((OUTPUT_RATE * 2).to_le_bytes());
        bytes.extend(2u16.to_le_bytes());
        bytes.extend(16u16.to_le_bytes());
        bytes.extend(b"data");
        bytes.extend((data.len() as u32).to_le_bytes());
        bytes.extend(data);
        bytes
    }

    fn temp(name: &str, bytes: &[u8]) -> PathBuf {
        let path = std::env::temp_dir()
            .join(format!("idfon-radio-{}-{name}.wav", std::process::id()));
        std::fs::write(&path, bytes).expect("write fixture");
        path
    }

    #[test]
    fn an_active_slot_beats_the_fallback() {
        let fallback = temp("fallback", &wav(&[1; FRAME_SAMPLES]));
        let slot = temp("slot", &wav(&[2; FRAME_SAMPLES]));
        let schedule = Schedule::parse(
            &serde_json::json!({
                "slots": [{ "at": "00:00", "file": slot, "title": "night programme" }]
            }),
            Path::new("/"),
        )
        .expect("schedule");
        let mut programme = Programme {
            schedule_path: None,
            schedule: Some(schedule),
            modified: None,
            checked: Instant::now(),
            fallback_path: Some(fallback.clone()),
            fallback: Some(Arc::new(clip::read_wav(&fallback).expect("fallback"))),
            loop_fallback: true,
            clips: HashMap::new(),
            current: None,
            cursor: 0,
        };
        let mut events = Vec::new();
        programme.sync(Local::now().naive_local(), |event| events.push(event));
        assert!(matches!(events.last(), Some(Event::Slot(info)) if info.title.as_deref() == Some("night programme")));
        let mut frame = vec![0i16; FRAME_SAMPLES];
        assert!(programme.frame(&mut frame));
        assert_eq!(frame[0], 2);
        for path in [fallback, slot] {
            let _ = std::fs::remove_file(path);
        }
    }

    #[test]
    fn a_non_looping_fallback_runs_out() {
        let path = temp("short", &wav(&[3; FRAME_SAMPLES]));
        let programme = Programme::open(ProgrammeConfig {
            schedule: None,
            fallback: Some(path.clone()),
            loop_fallback: false,
            topic: None,
        })
        .expect("programme");
        let mut programme = programme;
        let mut events = Vec::new();
        programme.sync(Local::now().naive_local(), |event| events.push(event));
        let mut frame = vec![0i16; FRAME_SAMPLES];
        assert!(programme.frame(&mut frame));
        assert!(!programme.frame(&mut frame), "one frame, then done");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_programme_config_needs_something_to_play() {
        let value = serde_json::json!({ "loop": true });
        assert!(ProgrammeConfig::parse(&value, Path::new(".")).is_err());
    }
}
