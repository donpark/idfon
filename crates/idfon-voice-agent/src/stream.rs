//! Stream backend: a one-way audio source over a live call.
//!
//! Advertised as `voice_route.mode = broadcast` (a radio station, a talk-radio
//! topic contact). It plays audio into the return leg and never listens: the
//! caller's leg is read and dropped.
//!
//! What plays is a *programme*, not a file: `schedule` names a slot table
//! ([`crate::programming`]), the active slot holds the air until the next one
//! starts, and `file` is the fallback that loops when no slot is active. The
//! JSONL record is what makes a walk-around soak comparable afterwards — a
//! heartbeat a second, every slot change, and any tick that arrived late.
//!
//! PCM WAV only (16-bit, 24 kHz — the live-call profile), so no decoder
//! dependency. Convert a recording first:
//!
//! ```sh
//! ffmpeg -i station.mp3 -ar 24000 -ac 1 station.wav
//! afconvert -f WAVE -d LEI16@24000 -c 1 station.mp3 station.wav
//! ```
//!
//! then `{ "backend": "stream", "file": "station.wav" }`, or programme it with
//! `scripts/radio-program.mjs` (submissions and found episodes, see
//! `docs/live-radio.md`).
//!
//! shortcut: no MP3/ICY/HLS decoding, so a live station must be recorded first;
//! upgrade when soaking against a live stream (rather than a replayed clip) is
//! worth a decode dependency.

use std::{
    collections::HashMap,
    fs::OpenOptions,
    io::Write,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant, SystemTime},
};

use anyhow::{ensure, Context, Result};
use chrono::{Local, NaiveDateTime};
use idfon_live_media::{AudioQueue, CHUNK_SAMPLES};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio::time::MissedTickBehavior;

use crate::programming::Schedule;
use crate::{BackendFuture, VoiceBackend, VoiceBackendFactory, VoiceMedia};

/// The live-call audio profile (`docs/audio-media.md`).
const RATE: u32 = 24_000;
const TICK_MS: u64 = 20;
/// Top the return leg up to this depth (~100 ms) each tick. Pacing off the
/// queue rather than the clip's clock position cannot drift from the media
/// publisher, which drains at the same 20 ms cadence.
const TARGET_SAMPLES: usize = 2_400;
/// Cap one tick's top-up (0.5 s) so a stalled consumer cannot spin us.
const MAX_FRAMES_PER_TICK: usize = 25;
/// A tick later than this means the agent host itself stalled — part of the
/// call's quality record, not noise.
const LATE_MS: u128 = 40;
const HEARTBEAT: Duration = Duration::from_secs(1);
/// How often the schedule file is stat-ed for edits mid-call.
const RELOAD_CHECK: Duration = Duration::from_secs(1);

/// `backend: "stream"` — one factory per runner, one backend per call.
pub struct StreamFactory;

impl VoiceBackendFactory for StreamFactory {
    fn kind(&self) -> &str {
        "stream"
    }

    fn create(&self, params: &Value) -> Result<Box<dyn VoiceBackend>> {
        // `file`, not `source`: `source` is already the turn-provenance tag in
        // `VoiceAgentConfig` and would be silently overwritten here.
        let file = param_path(params, "file");
        let schedule_path = param_path(params, "schedule");
        ensure!(
            file.is_some() || schedule_path.is_some(),
            "stream backend needs a `file` (fallback) or `schedule`"
        );
        // Both are loaded now so a bad path declines the call (the handler then
        // treats the control as a text turn) instead of failing mid-call.
        let schedule = match &schedule_path {
            Some(path) => Some(Schedule::load(path)?),
            None => None,
        };
        let fallback = match &file {
            Some(path) => Some(Arc::new(read_wav(path)?)),
            None => None,
        };
        Ok(Box::new(StreamBackend {
            schedule_path,
            schedule,
            modified: None,
            file,
            fallback,
            topic: topic_from(params),
            loop_forever: params.get("loop").and_then(Value::as_bool).unwrap_or(true),
            log: params.get("log").and_then(Value::as_str).map(PathBuf::from),
        }))
    }
}

fn param_path(params: &Value, key: &str) -> Option<PathBuf> {
    params
        .get(key)
        .and_then(Value::as_str)
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
}

/// The contact's topic wins over the config default: the caller pushes it as a
/// `topic=<value>` line in the live invite's per-contact context, so one agent
/// serves many topic contacts without a new wire field.
fn topic_from(params: &Value) -> Option<String> {
    let pushed = params
        .get("caller_context")
        .and_then(Value::as_str)
        .and_then(|context| context.lines().find_map(|line| line.strip_prefix("topic=")))
        .map(str::trim)
        .filter(|topic| !topic.is_empty());
    pushed
        .map(str::to_owned)
        .or_else(|| params.get("topic").and_then(Value::as_str).map(str::to_owned))
}

pub struct StreamBackend {
    schedule_path: Option<PathBuf>,
    schedule: Option<Schedule>,
    /// Schedule mtime at the last load, for the mid-call reload.
    modified: Option<SystemTime>,
    file: Option<PathBuf>,
    fallback: Option<Arc<Vec<i16>>>,
    topic: Option<String>,
    loop_forever: bool,
    log: Option<PathBuf>,
}

impl VoiceBackend for StreamBackend {
    fn name(&self) -> &str {
        "stream"
    }

    fn run(&mut self, media: VoiceMedia) -> BackendFuture<'_> {
        let mut record = Recorder::new(self.log.clone(), self.topic.clone());
        let mut program = Program {
            schedule_path: self.schedule_path.clone(),
            schedule: self.schedule.clone(),
            modified: self.modified,
            file: self.file.clone(),
            fallback: self.fallback.as_ref().map(Arc::clone),
            loop_forever: self.loop_forever,
            clips: HashMap::new(),
            checked: Instant::now(),
            current: None,
            cursor: 0,
        };
        Box::pin(async move {
            // The clips are 24 kHz; a call carrying another rate would play
            // them fast. `voice_route.audio = "pcm24k"` is what keeps them equal.
            if media.profile.sample_rate != RATE {
                anyhow::bail!(
                    "stream source is {RATE} Hz but the call carries {} Hz; \
                     set voice_route.audio = \"pcm24k\"",
                    media.profile.sample_rate
                );
            }
            record.event(
                "start",
                [
                    ("slots", Value::from(program.schedule.as_ref().map_or(0, Schedule::len) as u64)),
                    ("fallback", Value::from(program.file.is_some())),
                    ("loop", Value::from(program.loop_forever)),
                    ("rate", Value::from(RATE)),
                ],
            );
            let result = run_call(
                &mut program,
                &media.audio,
                &media.stop,
                media.caller,
                &mut record,
            )
            .await;
            record.event("stop", []);
            result
        })
    }
}

/// What the call is playing right now, and why (for the record).
struct Selection {
    key: String,
    clip: Arc<Vec<i16>>,
    /// A slot loops to fill its air; the fallback loops only when `loop` is on.
    looping: bool,
    fields: Vec<(&'static str, Value)>,
}

/// The programme: schedule plus the fallback, resolved against the clock.
struct Program {
    schedule_path: Option<PathBuf>,
    schedule: Option<Schedule>,
    modified: Option<SystemTime>,
    file: Option<PathBuf>,
    fallback: Option<Arc<Vec<i16>>>,
    loop_forever: bool,
    clips: HashMap<PathBuf, Arc<Vec<i16>>>,
    checked: Instant,
    current: Option<Selection>,
    cursor: usize,
}

impl Program {
    /// Re-read an edited schedule, then move to the clip `now` calls for.
    fn sync(&mut self, now: NaiveDateTime, record: &mut Recorder) {
        self.reload(record);
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
            if let Some(clip) = self.clip_for(&clip_path, record) {
                let mut fields = vec![(
                    "at",
                    Value::from(start.format("%Y-%m-%d %H:%M").to_string()),
                )];
                for (key, value) in [
                    ("title", title),
                    ("topic", topic),
                    ("origin", origin),
                    ("note", note),
                    ("file", Some(clip_path.display().to_string())),
                ] {
                    if let Some(value) = value {
                        fields.push((key, Value::from(value)));
                    }
                }
                next = Some(Selection {
                    key: format!("slot:{}", clip_path.display()),
                    clip,
                    looping: true,
                    fields,
                });
            }
        }
        if next.is_none() {
            if let (Some(path), Some(clip)) = (&self.file, &self.fallback) {
                next = Some(Selection {
                    key: format!("fallback:{}", path.display()),
                    clip: Arc::clone(clip),
                    looping: self.loop_forever,
                    fields: vec![("at", Value::from("fallback"))],
                });
            }
        }
        let changed = next.as_ref().map(|next| &next.key) != self.current.as_ref().map(|now| &now.key);
        if changed {
            self.cursor = 0;
            match &next {
                Some(selection) => record.event("slot", selection.fields.clone()),
                None => record.event("slot", [("at", Value::from("none"))]),
            }
            self.current = next;
        }
    }

    fn reload(&mut self, record: &mut Recorder) {
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
                record.event("schedule", [("slots", Value::from(schedule.len() as u64))]);
                self.schedule = Some(schedule);
            }
            // An agent may be mid-write; keep playing the last good schedule.
            Err(error) => record.event(
                "error",
                [("message", Value::from(format!("{error:#}")))],
            ),
        }
    }

    fn clip_for(&mut self, path: &Path, record: &mut Recorder) -> Option<Arc<Vec<i16>>> {
        if let Some(clip) = self.clips.get(path) {
            return Some(Arc::clone(clip));
        }
        match read_wav(path) {
            Ok(pcm) => {
                let clip = Arc::new(pcm);
                self.clips.insert(path.to_path_buf(), Arc::clone(&clip));
                Some(clip)
            }
            Err(error) => {
                record.event("error", [("message", Value::from(format!("{error:#}")))]);
                None
            }
        }
    }

    fn has_programme(&self) -> bool {
        self.current.is_some()
    }

    /// Copy the next chunk out; `false` means the fallback ran out (the call
    /// ends) — a slot always loops.
    fn fill_into(&mut self, out: &mut [i16]) -> bool {
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
}

/// Feed the return leg from the programme until the call stops.
async fn run_call(
    program: &mut Program,
    audio: &AudioQueue,
    stop: &AtomicBool,
    mut caller: mpsc::Receiver<Vec<i16>>,
    record: &mut Recorder,
) -> Result<()> {
    let mut frame = vec![0i16; CHUNK_SAMPLES];
    let mut sent = 0u64;
    let mut tick = tokio::time::interval(Duration::from_millis(TICK_MS));
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut last = Instant::now();
    let mut last_beat = Instant::now();
    loop {
        tick.tick().await;
        // One-way: read the caller's leg and drop it. Not reading it would
        // back-pressure the media consumer; mixing it in is not a broadcast.
        while caller.try_recv().is_ok() {}
        if stop.load(Ordering::Relaxed) {
            return Ok(());
        }
        let late = last.elapsed().saturating_sub(Duration::from_millis(TICK_MS));
        if late.as_millis() > LATE_MS {
            record.event("gap", [("late_ms", Value::from(late.as_millis() as u64))]);
        }
        last = Instant::now();
        program.sync(Local::now().naive_local(), record);
        let mut frames = 0;
        while program.has_programme()
            && audio.queued_samples() < TARGET_SAMPLES
            && frames < MAX_FRAMES_PER_TICK
        {
            if !program.fill_into(&mut frame) {
                record.event("eof", [("sent_s", Value::from(sent / RATE as u64))]);
                return Ok(());
            }
            audio.push_samples(&frame);
            sent += frame.len() as u64;
            frames += 1;
        }
        if last_beat.elapsed() >= HEARTBEAT {
            last_beat = Instant::now();
            record.event(
                "heartbeat",
                [
                    ("sent_s", Value::from(sent / RATE as u64)),
                    ("queued_ms", Value::from(audio.queued_samples() as u64 / 24)),
                ],
            );
        }
    }
}

/// JSONL soak record: one object per line, `t_ms` monotonic from the call.
struct Recorder {
    file: Option<std::fs::File>,
    started: Instant,
    topic: Option<String>,
}

impl Recorder {
    fn new(log: Option<PathBuf>, topic: Option<String>) -> Self {
        let file = log.and_then(|path| {
            OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .map_err(|error| eprintln!("[stream] cannot open log {}: {error}", path.display()))
                .ok()
        });
        Self {
            file,
            started: Instant::now(),
            topic,
        }
    }

    fn event(&mut self, event: &str, fields: impl IntoIterator<Item = (&'static str, Value)>) {
        let Some(file) = self.file.as_mut() else {
            return;
        };
        let mut object = serde_json::Map::new();
        object.insert("t_ms".into(), (self.started.elapsed().as_millis() as u64).into());
        object.insert("event".into(), event.into());
        if let Some(topic) = &self.topic {
            object.insert("topic".into(), topic.as_str().into());
        }
        for (key, value) in fields {
            object.insert(key.into(), value);
        }
        let _ = writeln!(file, "{}", Value::Object(object));
    }
}

/// A WAV clip as 24 kHz mono s16, padded to whole 20 ms frames so looping
/// never splits a sample.
fn read_wav(path: &Path) -> Result<Vec<i16>> {
    let bytes = std::fs::read(path).with_context(|| format!("read {}", path.display()))?;
    ensure!(
        bytes.len() > 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WAVE",
        "{} is not a RIFF/WAVE file",
        path.display()
    );
    let mut channels = None;
    let mut data = None;
    let mut pos = 12;
    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let size = u32::from_le_bytes(bytes[pos + 4..pos + 8].try_into()?) as usize;
        let body = pos + 8;
        let end = body
            .checked_add(size)
            .filter(|end| *end <= bytes.len())
            .with_context(|| format!("{} has a truncated chunk", path.display()))?;
        if id == b"fmt " {
            ensure!(size >= 16, "{} has a short fmt chunk", path.display());
            let kind = u16::from_le_bytes(bytes[body..body + 2].try_into()?);
            let of_channels = u16::from_le_bytes(bytes[body + 2..body + 4].try_into()?);
            let rate = u32::from_le_bytes(bytes[body + 4..body + 8].try_into()?);
            let bits = u16::from_le_bytes(bytes[body + 14..body + 16].try_into()?);
            ensure!(kind == 1, "only PCM WAV is supported (format {kind})");
            ensure!(bits == 16, "only 16-bit PCM is supported ({bits} bits)");
            ensure!(of_channels >= 1, "WAV declares zero channels");
            ensure!(
                rate == RATE,
                "resample to {RATE} Hz first: `ffmpeg -i in -ar {RATE} -ac 1 out.wav` \
                 (got {rate} Hz)"
            );
            channels = Some(of_channels as usize);
        } else if id == b"data" {
            data = Some(&bytes[body..end]);
        }
        pos = end + (size & 1); // chunks are word-aligned
    }
    let channels = channels.with_context(|| format!("{} has no fmt chunk", path.display()))?;
    let data = data.with_context(|| format!("{} has no data chunk", path.display()))?;
    let mut pcm: Vec<i16> = data
        .chunks_exact(2 * channels)
        .map(|frame| {
            let sum: i32 = (0..channels)
                .map(|channel| i16::from_le_bytes([frame[2 * channel], frame[2 * channel + 1]]) as i32)
                .sum();
            (sum / channels as i32) as i16
        })
        .collect();
    ensure!(!pcm.is_empty(), "{} has no samples", path.display());
    let remainder = pcm.len() % CHUNK_SAMPLES;
    if remainder != 0 {
        pcm.resize(pcm.len() + CHUNK_SAMPLES - remainder, 0);
    }
    Ok(pcm)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wav(samples: &[i16], rate: u32, channels: u16) -> Vec<u8> {
        let data: Vec<u8> = samples.iter().flat_map(|sample| sample.to_le_bytes()).collect();
        let mut bytes = Vec::new();
        bytes.extend(b"RIFF");
        bytes.extend((36 + data.len() as u32).to_le_bytes());
        bytes.extend(b"WAVEfmt ");
        bytes.extend(16u32.to_le_bytes());
        bytes.extend(1u16.to_le_bytes());
        bytes.extend(channels.to_le_bytes());
        bytes.extend(rate.to_le_bytes());
        bytes.extend((rate * u32::from(channels) * 2).to_le_bytes());
        bytes.extend((channels * 2).to_le_bytes());
        bytes.extend(16u16.to_le_bytes());
        bytes.extend(b"data");
        bytes.extend((data.len() as u32).to_le_bytes());
        bytes.extend(data);
        bytes
    }

    fn temp(name: &str, bytes: &[u8]) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "idfon-stream-{}-{name}.wav",
            std::process::id()
        ));
        std::fs::write(&path, bytes).expect("write fixture");
        path
    }

    fn program_for(file: Option<PathBuf>, loop_forever: bool) -> Program {
        let fallback = file.as_ref().map(|path| Arc::new(read_wav(path).expect("clip")));
        Program {
            schedule_path: None,
            schedule: None,
            modified: None,
            file,
            fallback,
            loop_forever,
            clips: HashMap::new(),
            checked: Instant::now(),
            current: None,
            cursor: 0,
        }
    }

    #[test]
    fn reads_and_pads_a_24k_clip() {
        let path = temp("mono", &wav(&[1, 2, 3, 4, 5], RATE, 1));
        let decoded = read_wav(&path).expect("decode");
        assert_eq!(&decoded[..5], &[1, 2, 3, 4, 5]);
        assert_eq!(decoded.len() % CHUNK_SAMPLES, 0);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn mixes_stereo_down_to_mono() {
        let path = temp("stereo", &wav(&[100, 300, -100, 100], RATE, 2));
        assert_eq!(read_wav(&path).expect("decode")[..2], [200, 0]);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn rejects_a_rate_the_call_cannot_carry() {
        let path = temp("44k", &wav(&[1, 2], 44_100, 1));
        let error = read_wav(&path).expect_err("44.1 kHz must be refused");
        assert!(format!("{error}").contains("resample"), "{error}");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn factory_accepts_the_live_config_shape() {
        let path = temp("factory", &wav(&[0; CHUNK_SAMPLES], RATE, 1));
        let params = serde_json::json!({
            "backend": "stream",
            "file": path,
            "loop": false,
            "topic": "talk radio",
            "log": "/dev/null",
        });
        assert_eq!(StreamFactory.kind(), "stream");
        assert!(StreamFactory.create(&params).is_ok());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn factory_needs_a_file_or_a_schedule() {
        let error = match StreamFactory.create(&serde_json::json!({ "backend": "stream" })) {
            Ok(_) => panic!("a stream backend with nothing to play must decline"),
            Err(error) => error,
        };
        assert!(format!("{error}").contains("schedule"), "{error}");
    }

    #[test]
    fn the_shipped_radio_config_builds() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../agents/radio");
        let mut params: Value = serde_json::from_slice(
            &std::fs::read(dir.join("live.json")).expect("agents/radio/live.json"),
        )
        .expect("live.json is JSON");
        let route: idfon_protocol::VoiceRoute =
            serde_json::from_value(params["voice_route"].clone()).expect("voice_route");
        assert_eq!(route.mode, idfon_protocol::VoiceMode::Broadcast);
        assert_eq!(route.audio.as_deref(), Some("pcm24k"));
        // The committed `file` is the operator's own clip; the seed schedule is
        // ours, so point the fallback at a fixture and keep the real schedule.
        let clip = temp("config", &wav(&[0; CHUNK_SAMPLES], RATE, 1));
        params["file"] = Value::from(clip.to_str().expect("utf8 path"));
        params["schedule"] = Value::from(dir.join("schedule.json").to_str().expect("utf8 path"));
        assert!(StreamFactory.create(&params).is_ok());
        let _ = std::fs::remove_file(clip);
    }

    #[test]
    fn a_schedule_only_station_builds() {
        // The shape `scripts/radio-program.mjs config` writes for a roster
        // instance: no `file`, paths absolute, the topic carried in the config.
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../agents/radio");
        let params = serde_json::json!({
            "backend": "stream",
            "schedule": dir.join("schedule.json"),
            "topic": "tech talk",
            "loop": true,
            "log": std::env::temp_dir().join("idfon-radio-test-soak.jsonl"),
            "broadcast": "idfon-radio",
            "voice_route": { "mode": "broadcast", "audio": "pcm24k" },
        });
        assert!(StreamFactory.create(&params).is_ok());
    }

    #[test]
    fn the_callers_topic_beats_the_config_default() {
        let pushed = serde_json::json!({
            "topic": "config",
            "caller_context": "stt=client\ntopic=  tech news \n",
        });
        assert_eq!(topic_from(&pushed).as_deref(), Some("tech news"));
        let default = serde_json::json!({ "topic": "config" });
        assert_eq!(topic_from(&default).as_deref(), Some("config"));
    }

    #[test]
    fn an_active_slot_beats_the_fallback() {
        let fallback = temp("fallback", &wav(&[1; CHUNK_SAMPLES], RATE, 1));
        let slot = temp("slot", &wav(&[2; CHUNK_SAMPLES], RATE, 1));
        let schedule = Schedule::parse(
            &serde_json::json!({
                "slots": [{ "at": "00:00", "file": slot, "title": "night programme" }]
            }),
            Path::new("/"),
        )
        .expect("schedule");
        let mut program = program_for(Some(fallback.clone()), true);
        program.schedule = Some(schedule);
        let mut record = Recorder::new(None, None);
        program.sync(Local::now().naive_local(), &mut record);
        let selection = program.current.as_ref().expect("a slot is always active");
        assert!(selection.key.starts_with("slot:"), "{}", selection.key);
        let mut frame = vec![0i16; CHUNK_SAMPLES];
        assert!(program.fill_into(&mut frame));
        assert_eq!(frame[0], 2);
        for path in [fallback, slot] {
            let _ = std::fs::remove_file(path);
        }
    }

    #[tokio::test]
    async fn pumps_to_the_queue_target_and_stops() {
        let path = temp("pump", &wav(&vec![1; RATE as usize], RATE, 1));
        let mut program = program_for(Some(path.clone()), true);
        let audio = AudioQueue::new();
        let stop = Arc::new(AtomicBool::new(false));
        let (_caller_tx, caller) = mpsc::channel(4);
        let stopper = Arc::clone(&stop);
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(200)).await;
            stopper.store(true, Ordering::Relaxed);
        });
        let mut record = Recorder::new(None, None);
        run_call(&mut program, &audio, &stop, caller, &mut record)
            .await
            .expect("run");
        assert_eq!(audio.queued_samples(), TARGET_SAMPLES);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn ends_when_a_non_looping_fallback_runs_out() {
        let path = temp("short", &wav(&vec![1; CHUNK_SAMPLES], RATE, 1));
        let mut program = program_for(Some(path.clone()), false);
        let audio = AudioQueue::new();
        let stop = Arc::new(AtomicBool::new(false));
        let (_caller_tx, caller) = mpsc::channel(4);
        let mut record = Recorder::new(None, None);
        run_call(&mut program, &audio, &stop, caller, &mut record)
            .await
            .expect("run");
        assert!(audio.queued_samples() <= TARGET_SAMPLES);
        let _ = std::fs::remove_file(path);
    }
}
