//! Trial metrics for a voice agent: per-turn latency and a rough cost estimate.
//!
//! The point of running many providers through idfon is comparison, so record
//! what a caller actually experiences — STT latency, TTS latency, audio
//! produced — plus an **estimated** cost. Prices drift; they are data, clearly
//! marked as estimates, and unknown providers report `None` rather than a
//! fabricated number.

use serde::Serialize;

/// One voice turn's timings.
#[derive(Debug, Serialize)]
pub struct TurnMetrics {
    /// `stt_provider` | `tts_provider` (best effort from config).
    pub provider: String,
    pub stt_ms: u64,
    pub tts_first_ms: u64,
    pub tts_total_ms: u64,
    /// Milliseconds of caller audio transcribed.
    pub caller_audio_ms: u64,
    /// Milliseconds of speech synthesized.
    pub tts_audio_ms: u64,
    pub tts_chars: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub est_cost_usd: Option<f64>,
}

impl TurnMetrics {
    /// Log one structured turn-metrics event so a call can be compared against
    /// another provider's. Grep the unified log for `target=idfon.voice.metrics`.
    pub fn log(&self) {
        tracing::info!(
            target: "idfon.voice.metrics",
            provider = %self.provider,
            stt_ms = self.stt_ms,
            tts_first_ms = self.tts_first_ms,
            tts_total_ms = self.tts_total_ms,
            caller_audio_ms = self.caller_audio_ms,
            tts_audio_ms = self.tts_audio_ms,
            tts_chars = self.tts_chars,
            est_cost_usd = ?self.est_cost_usd,
            "voice-metrics"
        );
    }

    pub fn cost_estimate(&self) -> Option<f64> {
        estimate_cost(&self.provider, self.caller_audio_ms, self.tts_chars)
    }
}

/// Rough per-unit estimates (USD). `stt_per_min`, `tts_per_1k_chars`.
fn prices(provider: &str) -> Option<(f64, f64)> {
    let provider = provider.to_ascii_lowercase();
    if provider.contains("deepgram") {
        return Some((0.0043, 0.0150));
    }
    if provider.contains("elevenlabs") {
        return Some((0.0, 0.1800));
    }
    if provider.contains("openai") || provider.contains("gateway") || provider.contains("whisper") {
        return Some((0.0060, 0.0150));
    }
    None
}

/// Estimate combined cost; `None` when we have no price for the provider.
pub fn estimate_cost(provider: &str, caller_audio_ms: u64, tts_chars: usize) -> Option<f64> {
    // A split engine label is `stt|tts`; price the halves separately.
    if let Some((stt_part, tts_part)) = provider.split_once('|') {
        let stt = prices(stt_part).map(|(per_min, _)| per_min * caller_audio_ms as f64 / 60_000.0);
        let tts = prices(tts_part)
            .map(|(_, per_1k)| per_1k * tts_chars as f64 / 1_000.0);
        return match (stt, tts) {
            (None, None) => None,
            (a, b) => Some(a.unwrap_or(0.0) + b.unwrap_or(0.0)),
        };
    }
    let (per_min, per_1k) = prices(provider)?;
    Some(per_min * caller_audio_ms as f64 / 60_000.0 + per_1k * tts_chars as f64 / 1_000.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn estimates_and_unknowns() {
        let known = estimate_cost("deepgram", 60_000, 1_000).unwrap();
        assert!(known > 0.0);
        assert!(estimate_cost("mystery", 60_000, 1_000).is_none());
        let split = estimate_cost("deepgram|elevenlabs", 60_000, 1_000).unwrap();
        assert!(split > known);
    }
}
