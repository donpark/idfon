import Foundation
import TygerVoice

/// ``TurnRules`` over the `idfon_voice_turn_*` C ABI — the Rust rules core
/// (`crates/idfon-voice/src/turns.rs`), one session per conversation. Events
/// cross as JSON; a finished turn's audio as an owned f32 buffer.
final class TurnRulesCABI: TurnRules {
    private let sess: UnsafeMutableRawPointer

    init(thresholdsJSON: String? = nil) {
        let raw = (thresholdsJSON ?? "").withCString { idfon_voice_turn_new($0) }
        guard let raw else {
            fatalError("idfon_voice_turn_new rejected the thresholds JSON")
        }
        sess = raw
    }

    deinit {
        idfon_voice_turn_free(sess)
    }

    func beginHop(user: [Float], agent: [Float], mode: String) -> Bool {
        mode.withCString { m in
            user.withUnsafeBufferPointer { u in
                agent.withUnsafeBufferPointer { a in
                    idfon_voice_turn_begin_hop(sess, u.baseAddress, a.baseAddress, u.count, m) != 0
                }
            }
        }
    }

    func switchMode(_ mode: String) -> Bool {
        mode.withCString { idfon_voice_turn_switch_mode(sess, $0) != 0 }
    }

    var prevState: Int {
        Int(idfon_voice_turn_prev_state(sess))
    }

    func onFrame(outputs: [Float], actDb: Double, left: Int, mode: String) -> FrameOutcome {
        var out = FrameOutcome()
        var audio: UnsafeMutablePointer<Float>?
        var audioLen = 0
        let body = mode.withCString { m in
            outputs.withUnsafeBufferPointer { o in
                idfon_voice_turn_on_frame(sess, o.baseAddress, actDb, left, m, &audio, &audioLen)
            }
        }
        guard let body else { return out }
        defer { rust_free_string(body) }
        let text = String(cString: body)
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return out
        }
        out.events = (json["events"] as? [[String: Any]]) ?? []
        out.reset = (json["reset"] as? Bool) ?? false
        if (json["final"] as? Bool) ?? false, let audio {
            out.finalAudio = Array(UnsafeBufferPointer(start: audio, count: audioLen))
            idfon_voice_turn_free_audio(audio, audioLen)
        } else if let audio {
            idfon_voice_turn_free_audio(audio, audioLen)
        }
        return out
    }

    func setWords(_ words: String) {
        words.withCString { idfon_voice_turn_set_words(sess, $0) }
    }

    func wordsEvent(mode: String) -> [String: Any]? {
        guard let body = mode.withCString({ idfon_voice_turn_words_event(sess, $0) }) else {
            return nil
        }
        defer { rust_free_string(body) }
        let data = String(cString: body).data(using: .utf8) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func reset() {
        idfon_voice_turn_reset(sess)
    }
}
