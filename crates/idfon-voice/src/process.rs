//! Local command engine: shell out to a model's CLI for STT/TTS.
//!
//! Open-source models (Kokoro TTS, Parakeet ASR, whisper.cpp, …) ship
//! with all sorts of interfaces, so the honest common denominator is "run this
//! command". A command reads a WAV and prints (or writes) a transcript (STT),
//! or reads text and writes a WAV (TTS):
//!
//! ```json
//! { "provider": "command",
//!   "stt_cmd": "whisper {input}",
//!   "tts_cmd": "kokoro-tts {text} {output}" }
//! ```
//!
//! Placeholders: `{input}` (STT input WAV), `{text}` (TTS input text file),
//! `{output}` (a file the command may write; for STT it is read when present,
//! else stdout is used). Shell is `/bin/sh -c`, so pipes and args work.
//! Commands block; the holder runs a multi-thread runtime.
#![cfg(feature = "gateway")]

use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{anyhow, Context, Result};
use serde_json::Value;

use crate::stub::EnergyEndpointer;
use crate::wav::pcm_wav_bytes;
use crate::{
    AudioFormat, Endpointer, PcmChunk, SttSession, TranscriptEvent, TtsSession, VoiceEngine,
};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

fn temp_path(tag: &str, extension: &str) -> std::path::PathBuf {
    let id = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "idfon-voice-{}-{tag}-{id}.{extension}",
        std::process::id()
    ))
}

fn shell_quote(path: &std::path::Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', "'\\''"))
}

fn run_transcribe(cmd: &str, format: AudioFormat, pcm: &[i16]) -> Result<String> {
    let input = temp_path("stt-in", "wav");
    let output = temp_path("stt-out", "txt");
    std::fs::write(&input, pcm_wav_bytes(format, pcm)).context("write STT input")?;
    let expanded = cmd
        .replace("{input}", &shell_quote(&input))
        .replace("{output}", &shell_quote(&output));
    let result = Command::new("/bin/sh").arg("-c").arg(&expanded).output();
    let _ = std::fs::remove_file(&input);
    let result = result.context("run STT command")?;
    if !result.status.success() {
        let _ = std::fs::remove_file(&output);
        return Err(anyhow!(
            "STT command failed: {}",
            String::from_utf8_lossy(&result.stderr).trim()
        ));
    }
    // Prefer a file the command wrote; else stdout.
    let text = std::fs::read_to_string(&output)
        .ok()
        .filter(|text| !text.trim().is_empty())
        .unwrap_or_else(|| String::from_utf8_lossy(&result.stdout).to_string());
    let _ = std::fs::remove_file(&output);
    Ok(text.trim().to_string())
}

fn run_synthesize(cmd: &str, format: AudioFormat, text: &str) -> Result<PcmChunk> {
    let text_path = temp_path("tts-in", "txt");
    let output = temp_path("tts-out", "wav");
    std::fs::write(&text_path, text).context("write TTS input")?;
    let expanded = cmd
        .replace("{text}", &shell_quote(&text_path))
        .replace("{output}", &shell_quote(&output));
    let result = Command::new("/bin/sh").arg("-c").arg(&expanded).output();
    let _ = std::fs::remove_file(&text_path);
    let result = result.context("run TTS command")?;
    if !result.status.success() {
        let _ = std::fs::remove_file(&output);
        return Err(anyhow!(
            "TTS command failed: {}",
            String::from_utf8_lossy(&result.stderr).trim()
        ));
    }
    let bytes = std::fs::read(&output).context("read TTS output")?;
    let _ = std::fs::remove_file(&output);
    Ok(PcmChunk {
        format,
        samples: pcm_samples(&bytes),
    })
}

/// Pull s16le samples out of a WAV (or raw PCM if there is no RIFF header).
fn pcm_samples(bytes: &[u8]) -> Vec<i16> {
    let data = if bytes.len() > 44 && &bytes[0..4] == b"RIFF" {
        // Find the `data` chunk rather than assuming a 44-byte header.
        let mut offset = 12;
        let mut found: Option<&[u8]> = None;
        while offset + 8 <= bytes.len() {
            let id = &bytes[offset..offset + 4];
            let size =
                u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().unwrap()) as usize;
            let start = offset + 8;
            if id == b"data" {
                found = Some(&bytes[start..(start + size).min(bytes.len())]);
                break;
            }
            offset = start + size + (size & 1);
        }
        found.unwrap_or(&bytes[44..])
    } else {
        bytes
    };
    data.chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
        .collect()
}

/// A [`VoiceEngine`] that shells out to local commands.
pub struct ProcessVoiceEngine {
    stt_cmd: Option<String>,
    tts_cmd: Option<String>,
}

impl ProcessVoiceEngine {
    pub fn from_config(value: &Value, _format: AudioFormat) -> Result<Self> {
        Ok(Self {
            stt_cmd: value
                .get("stt_cmd")
                .and_then(|v| v.as_str())
                .map(str::to_owned),
            tts_cmd: value
                .get("tts_cmd")
                .and_then(|v| v.as_str())
                .map(str::to_owned),
        })
    }
}

impl VoiceEngine for ProcessVoiceEngine {
    fn name(&self) -> &str {
        "command"
    }

    fn stt(&self, format: AudioFormat) -> Result<Box<dyn SttSession>> {
        Ok(Box::new(ProcessStt {
            cmd: self
                .stt_cmd
                .clone()
                .ok_or_else(|| anyhow!("command engine has no `stt_cmd`"))?,
            format,
            pcm: Vec::new(),
        }))
    }

    fn tts(&self, _voice: &str, format: AudioFormat) -> Result<Box<dyn TtsSession>> {
        Ok(Box::new(ProcessTts {
            cmd: self
                .tts_cmd
                .clone()
                .ok_or_else(|| anyhow!("command engine has no `tts_cmd`"))?,
            format,
            pending: String::new(),
        }))
    }

    fn endpointer(&self, format: AudioFormat) -> Result<Box<dyn Endpointer>> {
        Ok(Box::new(EnergyEndpointer::new(format)))
    }
}

struct ProcessStt {
    cmd: String,
    format: AudioFormat,
    pcm: Vec<i16>,
}

impl SttSession for ProcessStt {
    fn push(&mut self, pcm: &[i16]) -> Result<Vec<TranscriptEvent>> {
        self.pcm.extend_from_slice(pcm);
        Ok(Vec::new())
    }

    fn flush(&mut self) -> Result<Option<String>> {
        let pcm = std::mem::take(&mut self.pcm);
        if pcm.is_empty() {
            return Ok(None);
        }
        let text = run_transcribe(&self.cmd, self.format, &pcm)?;
        Ok(if text.is_empty() { None } else { Some(text) })
    }

    fn finish(&mut self) -> Result<Option<String>> {
        self.flush()
    }
}

struct ProcessTts {
    cmd: String,
    format: AudioFormat,
    pending: String,
}

impl TtsSession for ProcessTts {
    fn push_text(&mut self, delta: &str) -> Result<Vec<PcmChunk>> {
        self.pending.push_str(delta);
        let mut chunks = Vec::new();
        while let Some(index) = self
            .pending
            .char_indices()
            .find(|(_, c)| matches!(c, '.' | '!' | '?' | '\n'))
            .map(|(index, _)| index)
        {
            let sentence: String = self.pending.drain(..=index).collect();
            if !sentence.trim().is_empty() {
                chunks.push(run_synthesize(&self.cmd, self.format, &sentence)?);
            }
        }
        Ok(chunks)
    }

    fn finish(&mut self) -> Result<Vec<PcmChunk>> {
        let text = std::mem::take(&mut self.pending);
        if text.trim().is_empty() {
            return Ok(Vec::new());
        }
        Ok(vec![run_synthesize(&self.cmd, self.format, &text)?])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pcm_samples_reads_data_chunk() {
        let wav = pcm_wav_bytes(AudioFormat::PCM_24K_MONO, &[1, -2, 3]);
        assert_eq!(pcm_samples(&wav), vec![1, -2, 3]);
        assert_eq!(pcm_samples(&[1, 0, 2, 0]), vec![1, 2]);
    }

    #[test]
    fn command_engine_echoes_stdout_as_transcript() {
        // `cat {input}` prints the WAV; we only assert the command ran and the
        // STT path produced *some* text (non-empty stdout), not its content.
        let engine = ProcessVoiceEngine::from_config(
            &serde_json::json!({ "stt_cmd": "printf hello" }),
            AudioFormat::PCM_24K_MONO,
        )
        .unwrap();
        let mut stt = engine.stt(AudioFormat::PCM_24K_MONO).unwrap();
        stt.push(&[1, 2, 3]).unwrap();
        assert_eq!(stt.flush().unwrap().as_deref(), Some("hello"));
    }
}
