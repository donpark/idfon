import AVFAudio
import CIdfon

/// Plays decoded call audio from the Rust bridge (`media_audio_set_playback_cb`)
/// on the call capture engine's playback bus (`AudioMeter`), which is the
/// VoiceProcessingIO echo reference: remote audio on any other graph cannot be
/// echo-cancelled (docs/audio-media.md; macOS port of the iOS
/// `AudioIO`/`AudioPlaybackSink` fix). Rust paces frames through its jitter
/// buffer (`seam::PacedPlayback`) and never drops, so each chunk is scheduled
/// as it arrives.
final class AudioPlaybackSink {
    static let shared = AudioPlaybackSink()
    /// The bridge's decode format: interleaved f32 mono @ 48 kHz.
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    /// Output gain (0..1) from the audio-settings volume slider. The bundled
    /// device playback applies `media_audio_set_volume` itself; the shell path
    /// renders raw, so the gain is applied here instead.
    static var gain: Float = 1

    func register() {
        _ = media_audio_set_playback_cb(nil, audioPlaybackCallback)
    }

    fileprivate func enqueue(_ data: Data) {
        let frames = data.count / 4
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        if let dst = buffer.floatChannelData?[0] {
            data.withUnsafeBytes { raw in
                guard let src = raw.bindMemory(to: Float.self).baseAddress else { return }
                dst.update(from: src, count: frames)
            }
        }
        if Self.gain != 1, let dst = buffer.floatChannelData?[0] {
            for index in 0..<frames { dst[index] *= Self.gain }
        }
        AudioMeter.playStream(buffer)
    }
}

/// C trampoline for `media_audio_set_playback_cb`; the buffer is borrowed, so
/// copy before returning (documented contract).
private let audioPlaybackCallback: @convention(c) (
    UnsafeRawPointer?, UnsafePointer<UInt8>?, Int, UInt32, UInt32, UInt64
) -> Void = { _, data, len, _, _, _ in
    guard let data, len > 0 else { return }
    AudioPlaybackSink.shared.enqueue(Data(bytes: data, count: len))
}
