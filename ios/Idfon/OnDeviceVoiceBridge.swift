import AVFAudio
import Foundation

/// C ABI that lets the Rust `idfon-voice` seam drive the Swift on-device
/// provider (`OnDeviceVoice`). Symbols are declared `extern "C"` in
/// `crates/idfon-voice/src/apple_ffi.rs` and referenced by
/// `native/vendor/iroh-c-ffi/src/voice.rs`.
///
/// Contract: s16 little-endian mono PCM. The Rust side frees every pointer with
/// the matching `idfon_apple_voice_free*` function.

/// Synthesize UTF-8 `text`; returns s16 mono samples and their sample rate.
@_cdecl("idfon_apple_voice_tts")
func idfon_apple_voice_tts(
    _ text: UnsafePointer<CChar>?,
    _ outSampleRate: UnsafeMutablePointer<UInt32>?,
    _ outLen: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<UInt8>? {
    guard let text, let outSampleRate, let outLen else { return nil }
    Automation.mark("voice: c-tts in")
    guard let result = OnDeviceVoice.shared.synthesizePCM(String(cString: text)) else {
        Automation.mark("voice: c-tts nil")
        return nil
    }
    Automation.mark("voice: c-tts out bytes=\(result.data.count)")
    outSampleRate.pointee = result.rate
    outLen.pointee = result.data.count
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: result.data.count)
    result.data.copyBytes(to: buffer, count: result.data.count)
    return buffer
}

/// Transcribe s16 mono PCM at `sampleRate`; writes a UTF-8 string to `outText`.
@_cdecl("idfon_apple_voice_stt")
func idfon_apple_voice_stt(
    _ pcm: UnsafePointer<UInt8>?,
    _ pcmLen: Int,
    _ sampleRate: UInt32,
    _ outText: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let pcm, let outText, pcmLen > 0 else { return -1 }
    Automation.mark("voice: c-stt in bytes=\(pcmLen)")
    let data = Data(bytes: pcm, count: pcmLen)
    guard let transcript = OnDeviceVoice.shared.transcribePCM(data, sampleRate: sampleRate) else {
        Automation.mark("voice: c-stt nil")
        return -2
    }
    Automation.mark("voice: c-stt out chars=\(transcript.count)")
    let utf8 = Array(transcript.utf8)
    let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count + 1)
    for (index, byte) in utf8.enumerated() { pointer[index] = CChar(bitPattern: byte) }
    pointer[utf8.count] = 0
    outText.pointee = pointer
    return 0
}

@_cdecl("idfon_apple_voice_free")
func idfon_apple_voice_free(_ pointer: UnsafeMutablePointer<UInt8>?, _ len: Int) {
    pointer?.deallocate()
}

@_cdecl("idfon_apple_voice_free_text")
func idfon_apple_voice_free_text(_ pointer: UnsafeMutablePointer<CChar>?) {
    pointer?.deallocate()
}

extension OnDeviceVoice {
    /// Blocking wrapper for the C ABI: synthesize and convert to s16 mono PCM.
    /// AVSpeechSynthesizer is not thread-safe, so the call is made on main
    /// while the calling (Rust) thread waits.
    func synthesizePCM(_ text: String) -> (rate: UInt32, data: Data)? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("idfon-ffi-tts.wav")
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        let start = {
            self.synthesize(text, to: url) { result in
                if case .success = result { ok = true }
                semaphore.signal()
            }
        }
        if Thread.isMainThread { start() } else { DispatchQueue.main.async(execute: start) }
        guard semaphore.wait(timeout: .now() + 30) == .success, ok else { return nil }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        do { try file.read(into: buffer) } catch { return nil }
        guard let channels = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        let channelCount = max(1, Int(format.channelCount))
        var data = Data(capacity: count * 2)
        for frame in 0..<count {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            let value = max(-1, min(1, sum / Float(channelCount)))
            var sample = Int16(value * 32767).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return (UInt32(format.sampleRate.rounded()), data)
    }

    /// Blocking wrapper for the C ABI: write s16 PCM to a WAV and transcribe it.
    func transcribePCM(_ data: Data, sampleRate: UInt32) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("idfon-ffi-stt.wav")
        guard let wav = Self.pcmWav(data, sampleRate: sampleRate) else { return nil }
        do { try wav.write(to: url) } catch { return nil }
        Automation.mark("voice: c-stt wav bytes=\(wav.count) rate=\(sampleRate)")

        let semaphore = DispatchSemaphore(value: 0)
        var transcript: String?
        let start = {
            self.transcribe(url: url) { result in
                if case .success(let value) = result { transcript = value }
                semaphore.signal()
            }
        }
        if Thread.isMainThread { start() } else { DispatchQueue.main.async(execute: start) }
        guard semaphore.wait(timeout: .now() + 30) == .success else { return nil }
        return transcript
    }

    /// `-bargein`: play a synthesized answer and, while it plays, listen on the
    /// voice-processing (AEC) microphone. Speech over playback that passes the
    /// Rust barge-in and echo filters stops playback and engages.
    func runBargeInExercise(timeout: TimeInterval = 40) {
        Automation.mark("voice: bargein start")
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let phrase = "Here is a longer answer that keeps talking for a while so "
            + "you have time to interrupt me by speaking over the top of it."
        guard let pcm = synthesizePCM(phrase),
              let wav = Self.pcmWav(pcm.data, sampleRate: pcm.rate)
        else {
            Automation.mark("voice: FAIL bargein synth")
            Automation.mark("voice: done")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("idfon-bargein.wav")
        guard (try? wav.write(to: url)) != nil,
              let player = try? AVAudioPlayer(contentsOf: url)
        else {
            Automation.mark("voice: FAIL bargein player")
            Automation.mark("voice: done")
            return
        }
        self.bargeInPlayer = player
        Automation.mark("voice: bargein prepared seconds=\(player.duration)")

        let handle: (String) -> Void = { [weak self] text in
            guard let self, player.isPlaying else { return }
            let cancellable = idfon_voice_is_cancellable(text, 1, 0) != 0
            let echo = idfon_voice_is_echo(phrase, text) != 0
            if cancellable && !echo {
                player.stop()
                self.bargeInPlayer = nil
                self.stopSystemTranscriber()
                Automation.mark("voice: bargein engaged transcript=\(text)")
                Automation.mark("voice: PASS")
                Automation.mark("voice: done")
                self.finishListening(.success(text))
            } else {
                Automation.mark("voice: bargein ignored echo=\(echo) text=\(text)")
            }
        }

        // iOS 26+ shares the SpeechAnalyzer path with macOS; older iOS uses the
        // legacy SFSpeechRecognizer fallback.
        if #available(iOS 26.0, *) {
            let transcriber = SystemSpeechTranscriber()
            systemTranscriber = transcriber
            Task {
                do {
                    try await transcriber.start(
                        onText: { text, _ in handle(text) },
                        onError: { message in
                            Automation.mark("voice: FAIL bargein listen \(message)")
                            Automation.mark("voice: done")
                        }
                    )
                } catch {
                    Automation.mark("voice: FAIL bargein listen \(error.localizedDescription)")
                    Automation.mark("voice: done")
                }
            }
        } else {
            startListening(configureSession: false, onPartial: handle) { _ in }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            player.play()
            Automation.mark("voice: bargein playing")
            // Fail fast if playback finishes without an interruption.
            DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 1) { [self] in
                guard let current = self.bargeInPlayer, !current.isPlaying else { return }
                self.bargeInPlayer = nil
                self.stopSystemTranscriber()
                Automation.mark("voice: FAIL bargein no interruption")
                Automation.mark("voice: done")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.bargeInPlayer != nil else { return }
            self.bargeInPlayer = nil
            self.stopSystemTranscriber()
            Automation.mark("voice: FAIL bargein no interruption")
            Automation.mark("voice: done")
        }
    }

    /// Minimal 16-bit mono RIFF/WAVE wrapper (the same bytes the Rust seam
    /// writes), avoiding AVAudioFile format conversion.
    static func pcmWav(_ pcm: Data, sampleRate: UInt32) -> Data? {
        guard pcm.count % 2 == 0 else { return nil }
        var wav = Data(capacity: 44 + pcm.count)
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        let dataLen = UInt32(pcm.count)
        let byteRate = sampleRate * 2
        wav.append(contentsOf: Array("RIFF".utf8))
        append(36 + dataLen)
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        append(16)
        append16(1)
        append16(1)
        append(sampleRate)
        append(byteRate)
        append16(2)
        append16(16)
        wav.append(contentsOf: Array("data".utf8))
        append(dataLen)
        wav.append(pcm)
        return wav
    }
}
