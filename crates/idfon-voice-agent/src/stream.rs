//! Stream backend: the idfon adapter for a talk-radio station.
//!
//! The station itself is [`idfon_radio`] — its schedule, its clips, its frames.
//! This backend only connects that programme to a one-way live call: it pumps
//! [`Programme::frame`] into the return leg, drains and drops the caller's leg,
//! and writes the JSONL record a soak is read from. Another transport (HLS,
//! HTTP) would consume the same programme port and leave this file alone.
//!
//! Advertised as `voice_route.mode = broadcast`: an idfon caller listens.

use std::{
    fs::OpenOptions,
    io::Write,
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

use anyhow::{ensure, Result};
use chrono::Local;
use idfon_live_media::AudioQueue;
use idfon_radio::{Event, Programme, ProgrammeConfig, FRAME_SAMPLES, FRAME_MS};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio::time::MissedTickBehavior;

use crate::{BackendFuture, VoiceBackend, VoiceBackendFactory, VoiceMedia};

/// Top the return leg up to this depth (~100 ms) each tick. Pacing off the
/// queue rather than a clock position cannot drift from the media publisher,
/// which drains at the same 20 ms cadence.
const TARGET_SAMPLES: usize = 2_400;
/// Cap one tick's top-up (0.5 s) so a stalled consumer cannot spin us.
const MAX_FRAMES_PER_TICK: usize = 25;
/// A tick later than this means the agent host itself stalled — part of the
/// call's quality record, not noise.
const LATE_MS: u128 = 40;
const HEARTBEAT: Duration = Duration::from_secs(1);

/// `backend: "stream"` — one factory per runner, one backend per call.
pub struct StreamFactory;

impl VoiceBackendFactory for StreamFactory {
    fn kind(&self) -> &str {
        "stream"
    }

    fn create(&self, params: &Value) -> Result<Box<dyn VoiceBackend>> {
        // The station's own file (`programme: "programme.json"`) wins; the
        // adapter keys (`schedule`/`file`/`loop`) stay for a bare config.
        let config = match params.get("programme").and_then(Value::as_str) {
            Some(path) => ProgrammeConfig::load(Path::new(path))?,
            None => ProgrammeConfig::parse(params, Path::new("."))?,
        };
        let topic = config.topic.clone();
        Ok(Box::new(StreamBackend {
            programme: Programme::open(config)?,
            // A caller may name the topic for this call (per-contact context);
            // the record says what the station is, unless the caller says more.
            topic: topic_from(params).or(topic),
            log: params.get("log").and_then(Value::as_str).map(PathBuf::from),
        }))
    }
}

/// The contact's topic wins over the station default: the caller pushes it as a
/// `topic=<value>` line in the live invite's per-contact context, so one agent
/// serves many topic contacts without a new wire field.
fn topic_from(params: &Value) -> Option<String> {
    params
        .get("caller_context")
        .and_then(Value::as_str)
        .and_then(|context| context.lines().find_map(|line| line.strip_prefix("topic=")))
        .map(str::trim)
        .filter(|topic| !topic.is_empty())
        .map(str::to_owned)
}

pub struct StreamBackend {
    programme: Programme,
    topic: Option<String>,
    log: Option<PathBuf>,
}

impl VoiceBackend for StreamBackend {
    fn name(&self) -> &str {
        "stream"
    }

    fn run(&mut self, media: VoiceMedia) -> BackendFuture<'_> {
        let mut record = Recorder::new(self.log.clone(), self.topic.clone());
        let programme = &mut self.programme;
        Box::pin(async move {
            // The station emits 24 kHz; a call carrying another rate would play
            // it fast. `voice_route.audio = "pcm24k"` is what keeps them equal.
            ensure!(
                programme.rate() == media.profile.sample_rate,
                "programme is {} Hz but the call carries {} Hz; set voice_route.audio = \"pcm24k\"",
                programme.rate(),
                media.profile.sample_rate
            );
            record.event(
                "start",
                [("rate", Value::from(programme.rate())), ("backend", Value::from("stream"))],
            );
            let result = run_call(
                programme,
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

/// Pump the programme into the return leg until the call stops.
async fn run_call(
    programme: &mut Programme,
    audio: &AudioQueue,
    stop: &AtomicBool,
    mut caller: mpsc::Receiver<Vec<i16>>,
    record: &mut Recorder,
) -> Result<()> {
    let mut frame = vec![0i16; FRAME_SAMPLES];
    let mut sent = 0u64;
    let mut tick = tokio::time::interval(Duration::from_millis(FRAME_MS as u64));
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
        let late = last.elapsed().saturating_sub(Duration::from_millis(FRAME_MS as u64));
        if late.as_millis() > LATE_MS {
            record.event("gap", [("late_ms", Value::from(late.as_millis() as u64))]);
        }
        last = Instant::now();
        programme.sync(Local::now().naive_local(), |event| record.note(event));
        let mut frames = 0;
        while programme.has_programme()
            && audio.queued_samples() < TARGET_SAMPLES
            && frames < MAX_FRAMES_PER_TICK
        {
            if !programme.frame(&mut frame) {
                record.event("eof", [("sent_s", Value::from(sent / programme.rate() as u64))]);
                return Ok(());
            }
            audio.push_samples(&frame);
            sent += frame.len() as u64;
            frames += 1;
        }
        if last_beat.elapsed() >= HEARTBEAT {
            last_beat = Instant::now();
            let queued_ms = audio.queued_samples() as u64 * 1_000 / programme.rate() as u64;
            record.event(
                "heartbeat",
                [
                    ("sent_s", Value::from(sent / programme.rate() as u64)),
                    ("queued_ms", Value::from(queued_ms)),
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

    /// Render a station event. The station says what happened; the record
    /// decides how it reads.
    fn note(&mut self, event: Event) {
        match event {
            Event::Schedule { slots } => {
                self.event("schedule", [("slots", Value::from(slots as u64))]);
            }
            Event::Slot(info) => {
                let mut fields: Vec<(&'static str, Value)> = vec![("at", Value::from(info.at))];
                for (key, value) in [
                    ("file", info.file),
                    ("title", info.title),
                    ("topic", info.topic),
                    ("origin", info.origin),
                    ("note", info.note),
                ] {
                    if let Some(value) = value {
                        fields.push((key, Value::from(value)));
                    }
                }
                self.event("slot", fields);
            }
            Event::Idle => {
                self.event("slot", [("at", Value::from("none"))]);
            }
            Event::Error { message } => {
                self.event("error", [("message", Value::from(message))]);
            }
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

#[cfg(test)]
mod tests {
    use super::*;
    use idfon_radio::FRAME_SAMPLES;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    fn wav(samples: &[i16], rate: u32) -> Vec<u8> {
        let data: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
        let mut bytes = Vec::new();
        bytes.extend(b"RIFF");
        bytes.extend((36 + data.len() as u32).to_le_bytes());
        bytes.extend(b"WAVEfmt ");
        bytes.extend(16u32.to_le_bytes());
        bytes.extend(1u16.to_le_bytes());
        bytes.extend(1u16.to_le_bytes());
        bytes.extend(rate.to_le_bytes());
        bytes.extend((rate * 2).to_le_bytes());
        bytes.extend(2u16.to_le_bytes());
        bytes.extend(16u16.to_le_bytes());
        bytes.extend(b"data");
        bytes.extend((data.len() as u32).to_le_bytes());
        bytes.extend(data);
        bytes
    }

    fn temp(name: &str, bytes: &[u8]) -> PathBuf {
        let path = std::env::temp_dir()
            .join(format!("idfon-stream-{}-{name}.wav", std::process::id()));
        std::fs::write(&path, bytes).expect("write fixture");
        path
    }

    fn programme(file: PathBuf, loop_fallback: bool) -> Programme {
        Programme::open(ProgrammeConfig {
            schedule: None,
            fallback: Some(file),
            loop_fallback,
            topic: None,
        })
        .expect("programme")
    }

    #[test]
    fn factory_accepts_a_bare_adapter_config() {
        let path = temp("factory", &wav(&[0; FRAME_SAMPLES], 24_000));
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
    fn factory_accepts_the_shipped_radio_config() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../agents/radio");
        let params: Value = serde_json::from_slice(
            &std::fs::read(dir.join("live.json")).expect("agents/radio/live.json"),
        )
        .expect("live.json is JSON");
        let route: idfon_protocol::VoiceRoute =
            serde_json::from_value(params["voice_route"].clone()).expect("voice_route");
        assert_eq!(route.mode, idfon_protocol::VoiceMode::Broadcast);
        assert_eq!(route.audio.as_deref(), Some("pcm24k"));
        // The shipped programme parses; its fallback is the operator's own clip,
        // so it is not opened here.
        let programme = idfon_radio::ProgrammeConfig::load(&dir.join("programme.json"))
            .expect("shipped programme");
        assert_eq!(programme.topic.as_deref(), Some("talk radio"));

        // The adapter builds around a programme whose clips exist.
        let clip = temp("config", &wav(&[0; FRAME_SAMPLES], 24_000));
        let programme_path = std::env::temp_dir().join(format!(
            "idfon-stream-{}-programme.json",
            std::process::id()
        ));
        std::fs::write(
            &programme_path,
            serde_json::json!({
                "file": clip.to_str().expect("utf8 path"),
                "topic": "talk radio",
            })
            .to_string(),
        )
        .expect("write programme");
        let mut params = params;
        params["programme"] = Value::from(programme_path.to_str().expect("utf8 path"));
        assert!(StreamFactory.create(&params).is_ok());
        let _ = std::fs::remove_file(clip);
        let _ = std::fs::remove_file(programme_path);
    }

    #[test]
    fn factory_needs_a_programme() {
        let error = match StreamFactory.create(&serde_json::json!({ "backend": "stream" })) {
            Ok(_) => panic!("a stream backend with nothing to play must decline"),
            Err(error) => error,
        };
        assert!(format!("{error}").contains("schedule"), "{error}");
    }

    #[test]
    fn the_callers_topic_beats_the_station_default() {
        let pushed = serde_json::json!({
            "topic": "config",
            "caller_context": "stt=client\ntopic=  tech news \n",
        });
        assert_eq!(topic_from(&pushed).as_deref(), Some("tech news"));
        assert_eq!(topic_from(&serde_json::json!({})), None);
    }

    #[tokio::test]
    async fn pumps_to_the_queue_target_and_stops() {
        let path = temp("pump", &wav(&vec![1; 24_000], 24_000));
        let mut programme = programme(path.clone(), true);
        let audio = AudioQueue::new();
        let stop = Arc::new(AtomicBool::new(false));
        let (_caller_tx, caller) = mpsc::channel(4);
        let stopper = Arc::clone(&stop);
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(200)).await;
            stopper.store(true, Ordering::Relaxed);
        });
        let mut record = Recorder::new(None, None);
        run_call(&mut programme, &audio, &stop, caller, &mut record)
            .await
            .expect("run");
        assert_eq!(audio.queued_samples(), TARGET_SAMPLES);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn ends_when_a_non_looping_fallback_runs_out() {
        let path = temp("short", &wav(&vec![1; FRAME_SAMPLES], 24_000));
        let mut programme = programme(path.clone(), false);
        let audio = AudioQueue::new();
        let stop = Arc::new(AtomicBool::new(false));
        let (_caller_tx, caller) = mpsc::channel(4);
        let mut record = Recorder::new(None, None);
        run_call(&mut programme, &audio, &stop, caller, &mut record)
            .await
            .expect("run");
        assert!(audio.queued_samples() <= TARGET_SAMPLES);
        let _ = std::fs::remove_file(path);
    }
}
