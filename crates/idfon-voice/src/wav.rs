//! Minimal PCM → WAV writer shared by the offline pipeline and tests.

use std::path::Path;

use crate::AudioFormat;

/// Wrap interleaved s16 samples in a canonical 44-byte RIFF/WAVE header.
pub fn pcm_wav_bytes(format: AudioFormat, samples: &[i16]) -> Vec<u8> {
    let mut pcm = Vec::with_capacity(samples.len() * 2);
    for sample in samples {
        pcm.extend_from_slice(&sample.to_le_bytes());
    }
    let data_len = pcm.len() as u32;
    let block_align = format.frame_bytes() as u16;
    let byte_rate = format.sample_rate * block_align as u32;

    let mut wav = Vec::with_capacity(44 + pcm.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&format.channels.to_le_bytes());
    wav.extend_from_slice(&format.sample_rate.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.extend_from_slice(&pcm);
    wav
}

pub fn write_pcm_wav(path: &Path, format: AudioFormat, samples: &[i16]) -> std::io::Result<()> {
    std::fs::write(path, pcm_wav_bytes(format, samples))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_matches_the_pcm_payload() {
        let bytes = pcm_wav_bytes(AudioFormat::PCM_48K_MONO, &[1, -1, 2, -2]);
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(
            u32::from_le_bytes(bytes[24..28].try_into().unwrap()),
            48_000
        );
        assert_eq!(u16::from_le_bytes(bytes[22..24].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 8);
        assert_eq!(bytes.len(), 52);
    }
}
