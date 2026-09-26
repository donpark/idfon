//! Platform adapter seam for media capture and rendering.
//!
//! idfon code depends on these traits and constructors. Only this module (and
//! the concrete adapter impls) references upstream `moq_media`/`moq_audio`
//! source and sink enums, so a moq change lands here instead of in every shell.
//!
//! Capture adapters are constructed once and consumed into a source; render
//! adapters are live sinks invoked per decoded frame.

use std::path::Path;
use std::time::Duration;

use moq_audio::{Format, Frame as AudioFrame};
use moq_media::publish::{AudioSource, VideoSource};
use moq_video::Frame as VideoFrame;
use n0_future::boxed::BoxStream;

/// Audio format the capture side produces / the playback side consumes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AudioInput {
    pub format: Format,
    pub sample_rate: u32,
    pub channels: u32,
}

/// Capture side: produces the [`AudioSource`] a publisher ingests.
pub trait AudioCapture: Send {
    fn into_source(self: Box<Self>) -> AudioSource;
}

/// Capture side: produces the [`VideoSource`] a publisher ingests.
pub trait VideoCapture: Send {
    fn into_source(self: Box<Self>) -> VideoSource;
}

/// Decoded video sink: platform renderer, disk artifact, or test double.
pub trait VideoRender: Send + Sync {
    fn present(&self, frame: VideoFrame);
    /// No live frames are available any more (peer camera off / track ended).
    fn clear(&self) {}
}

/// Decoded-audio sink: platform playback or the bundled device engine.
///
/// `write` takes interleaved PCM in `input()`'s layout, already gain-applied
/// by the caller. `buffered` is the sink's lead over the speaker (zero for
/// sinks that pace themselves).
pub trait AudioPlayback: Send {
    fn input(&self) -> AudioInput;
    fn write(&mut self, pcm: &[u8], pts_us: u64) -> anyhow::Result<()>;
    fn buffered(&self) -> Duration {
        Duration::ZERO
    }
    fn set_volume(&mut self, volume: f32) {
        let _ = volume;
    }
}

/// A frame-stream audio source (shell push or file decode).
pub fn audio_frames(input: AudioInput, frames: BoxStream<AudioFrame>) -> AudioSource {
    AudioSource::Frames {
        input: moq_audio::encode::Input {
            format: input.format,
            sample_rate: input.sample_rate,
            channels: input.channels,
        },
        frames,
    }
}

/// A frame-stream video source (shell push).
pub fn video_frames(frames: BoxStream<VideoFrame>) -> VideoSource {
    VideoSource::Frames(frames)
}

/// Bundled fallback: a decoded audio file (WAV/MP3/FLAC) as a capture source.
pub struct FileAudioCapture {
    input: moq_audio::encode::Input,
    frames: BoxStream<AudioFrame>,
}

impl FileAudioCapture {
    pub fn open(path: &Path, loop_playback: bool) -> anyhow::Result<Self> {
        let source = moq_media::audio_file::AudioFile::open(path, loop_playback)?;
        Ok(Self {
            input: source.input(),
            frames: source.into_stream(),
        })
    }
}

impl AudioCapture for FileAudioCapture {
    fn into_source(self: Box<Self>) -> AudioSource {
        AudioSource::Frames {
            input: self.input,
            frames: self.frames,
        }
    }
}

/// Bundled fallback: pre-encoded Annex-B H.264 as a capture source.
pub struct FileVideoCapture {
    source: VideoSource,
}

impl FileVideoCapture {
    pub fn annexb(path: &Path) -> anyhow::Result<Self> {
        let data = std::fs::read(path)
            .map_err(|err| anyhow::anyhow!("cannot read {}: {err}", path.display()))?;
        if !data.windows(4).any(|w| w == [0, 0, 0, 1]) {
            anyhow::bail!("video source must be Annex-B H.264 or a supported container");
        }
        let stream: BoxStream<bytes::Bytes> =
            Box::pin(n0_future::stream::iter([bytes::Bytes::from(data)]));
        Ok(Self {
            source: VideoSource::AnnexB(stream),
        })
    }
}

impl VideoCapture for FileVideoCapture {
    fn into_source(self: Box<Self>) -> VideoSource {
        self.source
    }
}

/// Bundled fallback: the platform default microphone via device capture.
pub struct DeviceAudioCapture {
    device: Option<String>,
}

impl DeviceAudioCapture {
    pub fn new(device: Option<String>) -> Self {
        Self { device }
    }
}

impl AudioCapture for DeviceAudioCapture {
    fn into_source(self: Box<Self>) -> AudioSource {
        let mut config = moq_audio::capture::Config::default();
        config.source = moq_audio::capture::Source::Microphone(self.device);
        AudioSource::Device(config)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn annexb_capture_is_a_video_source() {
        let dir = std::env::temp_dir().join("idfon-seam-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("clip.h264");
        std::fs::write(&path, [0u8, 0, 0, 1, 0x67, 0x42]).unwrap();
        let capture = FileVideoCapture::annexb(&path).unwrap();
        assert!(matches!(
            Box::new(capture).into_source(),
            VideoSource::AnnexB(_)
        ));
    }

    #[test]
    fn rejects_non_annexb() {
        let dir = std::env::temp_dir().join("idfon-seam-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("nope.bin");
        std::fs::write(&path, b"not video").unwrap();
        assert!(FileVideoCapture::annexb(&path).is_err());
    }
}