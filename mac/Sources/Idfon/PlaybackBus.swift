import AVFAudio
import Foundation

/// A consumer of everything the agent's side plays — the turn-taker's second
/// ear (the agent's own voice, so its echo is not mistaken for the caller).
/// Mirrors iOS's `AudioIO` playback observers; mac producers fan in here until
/// the single-owner audio port converges the two apps.
protocol AudioPlaybackObserver: AnyObject {
    func audioPlayback(samples: [Float], rate: Double)
}

/// The registry. Producers notify at schedule/play time: the tag timeline is
/// the post timeline (the same stand-in as the tyger relay's TYGER_TAG_LAG_MS).
enum PlaybackBus {
    private static let lock = NSLock()
    private static let observers = NSHashTable<AnyObject>.weakObjects()

    static func add(_ observer: AudioPlaybackObserver) {
        lock.lock(); observers.add(observer); lock.unlock()
    }

    static func remove(_ observer: AudioPlaybackObserver) {
        lock.lock(); observers.remove(observer); lock.unlock()
    }

    /// Copy-under-lock, call outside it: an observer must not deadlock a producer.
    static func notify(samples: [Float], rate: Double) {
        guard !FeedbackEar.active else { return }  // voice feedback stays out of the second ear
        lock.lock()
        let all = observers.allObjects
        lock.unlock()
        for observer in all {
            (observer as? AudioPlaybackObserver)?.audioPlayback(samples: samples, rate: rate)
        }
    }

    /// An AVAudioPCMBuffer's first channel (bus-format buffers are what play).
    static func notify(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        notify(samples: Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength))),
               rate: buffer.format.sampleRate)
    }

    /// Wav bytes -> mono f32 samples. Parses the RIFF header our own synths
    /// write (PCM s16 LE); multichannel input takes channel 0.
    static func wavSamples(_ wav: Data) -> (samples: [Float], rate: Double)? {
        guard wav.count > 44, wav.withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }) == 0x4646_4952 else {
            return nil // "RIFF"
        }
        var offset = 12
        var rate = 0.0
        var channels = 1
        var bits = 16
        var data: Data?
        while offset + 8 <= wav.count {
            let id = wav.subdata(in: offset..<(offset + 4))
            let size = Int(wav.subdata(in: (offset + 4)..<(offset + 8)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            let body = (offset + 8)..<(min(offset + 8 + size, wav.count))
            if id == Data("fmt ".utf8) {
                let fmt = wav.subdata(in: body)
                channels = Int(fmt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self) })
                rate = Double(fmt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
                bits = Int(fmt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 14, as: UInt16.self) })
            } else if id == Data("data".utf8) {
                data = wav.subdata(in: body)
            }
            offset += 8 + size + (size % 2)
        }
        guard let data, bits == 16, rate > 0, channels >= 1 else { return nil }
        let frames = data.count / 2 / channels
        var samples = [Float](repeating: 0, count: frames)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let pcm = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                samples[i] = Float(pcm[i * channels]) / 32768
            }
        }
        return (samples, rate)
    }
}
