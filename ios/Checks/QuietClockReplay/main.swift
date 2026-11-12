// Replays real 16 kHz call audio through `QuietClock` (host tool, not part of
// the Xcode target). Reports every pause it would act on, in clip time:
//
//   swiftc -O -o /tmp/qcr ios/Idfon/QuietClock.swift \
//     ios/Checks/QuietClockReplay/main.swift -framework AVFAudio
//   /tmp/qcr clip.wav [channel]
//
// One line per pause: `pause start=…s quiet=…s` (the 240 ms end fires at
// start + the rule). The clock is primed with the clip's own 10th-percentile
// room level so it does not have to learn through the first second of speech.
import AVFAudio
import Foundation

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write(Data("usage: qcr <wav> [channel]\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
let channel = args.count > 2 ? (Int(args[2]) ?? 0) : 0

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let file: AVAudioFile
do { file = try AVAudioFile(forReading: url) } catch { die("read: \(error)") }
let format = file.processingFormat
guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
    die("buffer")
}
do { try file.read(into: buffer) } catch { die("decode: \(error)") }
guard let channels = buffer.floatChannelData, channel < Int(format.channelCount) else {
    die("channel \(channel) of \(format.channelCount)")
}
let rate = format.sampleRate
let n = Int(buffer.frameLength)
let samples = Array(UnsafeBufferPointer(start: channels[channel], count: n))

// The room: 10th percentile of 10 ms block RMS.
let blockN = max(1, Int(rate * 0.01))
var levels: [Float] = []
levels.reserveCapacity(n / blockN)
var i = 0
while i + blockN <= n {
    var power: Float = 0
    for j in i..<(i + blockN) { power += samples[j] * samples[j] }
    levels.append((power / Float(blockN)).squareRoot())
    i += blockN
}
levels.sort()
let floorRms = levels.isEmpty ? 0.002 : levels[levels.count / 10]
print("clip=\(url.lastPathComponent) rate=\(Int(rate)) ch=\(channel) dur=\(Double(n) / rate) floor_rms=\(floorRms)")

let clock = QuietClock()
clock.onPause = { start in print("pause start=\(start) q=0") }
clock.onResume = { quiet, _ in print("resume q=\(quiet)") }

// Prime with a second of the clip's room level, then run the clip as speech.
var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
let scale = floorRms * Float(3.0.squareRoot())
var preroll = [Float](repeating: 0, count: Int(rate))
for k in preroll.indices {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    preroll[k] = scale * (Float(Double(seed >> 11) / Double(1 << 53)) * 2 - 1)
}
clock.feed(preroll, sampleRate: rate)
clock.begin()
clock.feed(samples, sampleRate: rate)
clock.end()
