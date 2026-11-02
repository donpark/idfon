//! Clip loading: the one audio format the station plays.
//!
//! PCM WAV only (16-bit, the station's output rate), so the station carries no
//! decoder dependency. Convert before submitting:
//!
//! ```sh
//! ffmpeg -i station.mp3 -ar 24000 -ac 1 station.wav
//! afconvert -f WAVE -d LEI16@24000 -c 1 station.mp3 station.wav
//! ```
//!
//! shortcut: no MP3/ICY/HLS decoding here. A transport adapter (HLS) brings its
//! own demuxer and hands its frames to the same [`crate::Programme`] port.

use std::path::Path;

use anyhow::{ensure, Context, Result};

use crate::{FRAME_SAMPLES, OUTPUT_RATE};

/// A WAV clip as 24 kHz mono s16, padded to whole 20 ms frames so looping
/// never splits a sample.
pub(crate) fn read_wav(path: &Path) -> Result<Vec<i16>> {
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
                rate == OUTPUT_RATE,
                "resample to {OUTPUT_RATE} Hz first: `ffmpeg -i in -ar {OUTPUT_RATE} -ac 1 out.wav` \
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
    let remainder = pcm.len() % FRAME_SAMPLES;
    if remainder != 0 {
        pcm.resize(pcm.len() + FRAME_SAMPLES - remainder, 0);
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

    pub(crate) fn temp(name: &str, bytes: &[u8]) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "idfon-radio-{}-{name}.wav",
            std::process::id()
        ));
        std::fs::write(&path, bytes).expect("write fixture");
        path
    }

    #[test]
    fn reads_and_pads_a_24k_clip() {
        let path = temp("mono", &wav(&[1, 2, 3, 4, 5], OUTPUT_RATE, 1));
        let decoded = read_wav(&path).expect("decode");
        assert_eq!(&decoded[..5], &[1, 2, 3, 4, 5]);
        assert_eq!(decoded.len() % FRAME_SAMPLES, 0);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn mixes_stereo_down_to_mono() {
        let path = temp("stereo", &wav(&[100, 300, -100, 100], OUTPUT_RATE, 2));
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
}
