// Runnable check for the health card (not part of the Xcode target): the
// record JSON `idfon_media::health::CallRecord` produces must decode, fold to
// one summary line, and render. UIKit only, so it builds for Mac Catalyst and
// runs on the host — no simulator, no device:
//
//   xcrun swiftc -target arm64-apple-ios17.0-macabi \
//     -o /tmp/hccheck ios/Idfon/HealthCard.swift ios/Checks/HealthCardCheck/main.swift
//   /tmp/hccheck
//
// Prints "ALL OK" or the first failing assertion (exit 1). The fixture is
// serde's own field names, pinned on the Rust side by
// `idfon-media/src/health.rs` `record_json_shape_is_the_shell_contract`.
import Foundation
import UIKit

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

// --- Stubs for the app-side symbols HealthCard touches (`post`) ------------

struct ChatMessage {
    init(id: String, peerId: String, kind: MessageKind, outgoing: Bool,
         timestamp: Date, conversation: String? = nil, mergedIds: [String]? = nil) {}
}
enum MessageKind { case text(String), file(ticket: String, name: String, sizeBytes: Int, localURL: URL?) }
final class ChatStore {
    static let shared = ChatStore()
    private(set) var appended: [String] = []
    func appendOutgoing(_ message: ChatMessage) {}
}

// --- Stand-in for the Rust seam --------------------------------------------

/// What `media_health_live_report()` would answer; nil = no call running.
var liveReport: String?
func media_live_state() -> UInt8 { liveReport == nil ? 0 : 2 }
func media_health_live_report() -> UnsafeMutablePointer<CChar>? {
    guard let liveReport else { return nil }
    return strdup(liveReport)
}
func rust_free_string(_ pointer: UnsafeMutablePointer<CChar>) { free(pointer) }

// --- Fixture: a 92 s call that lost its Wi-Fi path at 51 s -----------------

let stored = """
{"started_ms":1762353000000,"duration_ms":92000,\
"context":{"video_on":false,"stereo":false},\
"audio":{"frames":4600,"duration_ms":92000,"startup_ms":380,\
"arrival_jitter_ms":2.5,"max_gap_ms":640,"stalls_over_100ms":2,\
"missing_frames":31,"underrun_samples":0},\
"report":{"local":{"rtt_ms_min":18,"rtt_ms_max":146,"loss_pct_mean":0.42,\
"goodput_kbps_mean":2100,"audio_underrun_samples":0},"remote":null,\
"verdict":"fair","tips":[{"action":"lower_video","reason":"loss above 1% on a video call"}]},\
"timeline":[\
{"t_ms":0,"rtt_ms":18,"min_rtt_ms":15,"loss_pct":0.0,"goodput_kbps":2100,"relay":false},\
{"t_ms":500,"rtt_ms":22,"min_rtt_ms":15,"loss_pct":0.1,"goodput_kbps":2050,"relay":false},\
{"t_ms":51000,"rtt_ms":146,"min_rtt_ms":40,"loss_pct":3.2,"goodput_kbps":540,"relay":true},\
{"t_ms":91500,"rtt_ms":71,"min_rtt_ms":40,"loss_pct":0.4,"goodput_kbps":900,"relay":true}],\
"path_switches":[\
{"t_ms":0,"path":"PathId(0)","relay":false,"local_addr":"192.168.1.42","remote_addr":"192.168.1.7:50000"},\
{"t_ms":51000,"path":"PathId(1)","relay":true,"local_addr":"relay","remote_addr":"relay:4433"}]}
"""

let record = HealthCard.decode(stored)
check(record != nil, "the record JSON decodes")
guard let record else { exit(1) }

let summary = HealthCard.summary(record)
check(summary.hasPrefix("Call health · fair"), "summary leads with the verdict")
check(summary.contains("1.5 min"), "summary reports minutes")
check(summary.contains("max gap 0.6 s"), "summary reports the largest arrival gap")
check(summary.contains("RTT 18–146 ms"), "summary reports the round-trip span")
check(summary.contains("relay"), "summary names the path the call ended on")

let image = HealthCard.render(record)
check(image != nil, "the timeline renders")
check(image?.size == CGSize(width: 900, height: 340), "the picture is the expected size")

let url = HealthCard.write(image: image!, peerId: "peer-1")
check(url != nil, "the picture writes beside the record")
let bytes = url.flatMap { try? Data(contentsOf: $0) } ?? Data()
check(bytes.count > 1_000, "the written picture is a real PNG (\(bytes.count) bytes)")
check(bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]), "the bytes are a PNG magic header")

// A call too short to sample still renders (the empty-timeline branch).
let shortJSON = """
{"started_ms":1762353000000,"duration_ms":400,\
"context":{"video_on":true,"stereo":true},\
"audio":{"frames":2,"duration_ms":40,"startup_ms":380,"arrival_jitter_ms":0.0,\
"max_gap_ms":0,"stalls_over_100ms":0,"missing_frames":0,"underrun_samples":0},\
"report":{"local":{"rtt_ms_min":18,"rtt_ms_max":20,"loss_pct_mean":0.0,\
"goodput_kbps_mean":null,"audio_underrun_samples":0},"remote":null,\
"verdict":"good","tips":[]},"timeline":[],"path_switches":[]}
"""
let shortRecord = HealthCard.decode(shortJSON)
check(shortRecord != nil, "a record with no timeline and no goodput decodes")
check(shortRecord.map { HealthCard.render($0) != nil } == true, "an empty timeline still renders")
check(HealthCard.summary(shortRecord!).contains("0 s,"), "a short call reads in seconds, not 0.0 min")

// --- Where the card reads from ---------------------------------------------

HealthCard.store(stored, for: "peer-1")
check(HealthCard.currentJSON(for: "peer-1") == stored, "a stored thread record is readable")
liveReport = stored
check(HealthCard.currentJSON(for: "peer-none") != nil, "mid-call the live record wins")
let midCall = HealthCard.post(peerId: "peer-1", conversation: nil)
check(midCall?.hasPrefix("live: ") == true, "a running call posts as live")
check(midCall?.contains("Call health · fair") == true, "the marker carries what the thread shows")
liveReport = nil
check(HealthCard.post(peerId: "peer-1", conversation: nil)?.hasPrefix("stored: ") == true,
      "after hangup the file is the source")
check(HealthCard.post(peerId: "peer-none", conversation: nil) == nil, "a thread with no call reports none")

print("ALL OK")
