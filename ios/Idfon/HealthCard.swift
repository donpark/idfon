import Foundation
import UIKit

/// The per-call quality record (`idfon_media::health::CallRecord`) as the chat
/// shows it (docs/media-adaptation.md §C1/§C2).
///
/// The record is knowledge about one thread's call, so it lives with that
/// thread: stored beside the chat, keyed by peer, and never sent to the peer —
/// it carries local addresses, RTT and loss.
enum HealthCard {
    struct Record: Decodable {
        struct Context: Decodable { let videoOn: Bool; let stereo: Bool
            enum CodingKeys: String, CodingKey { case stereo, videoOn = "video_on" } }
        struct Audio: Decodable {
            let frames: Int, durationMs: Int, startupMs: Int
            let arrivalJitterMs: Double, maxGapMs: Int, stallsOver100ms: Int
            let missingFrames: Int, underrunSamples: Int
            enum CodingKeys: String, CodingKey {
                case frames
                case durationMs = "duration_ms", startupMs = "startup_ms"
                case arrivalJitterMs = "arrival_jitter_ms", maxGapMs = "max_gap_ms"
                case stallsOver100ms = "stalls_over_100ms", missingFrames = "missing_frames"
                case underrunSamples = "underrun_samples"
            }
        }
        struct Leg: Decodable {
            let rttMsMin: Int, rttMsMax: Int, lossPctMean: Double, goodputKbpsMean: Int?
            enum CodingKeys: String, CodingKey {
                case rttMsMin = "rtt_ms_min", rttMsMax = "rtt_ms_max"
                case lossPctMean = "loss_pct_mean", goodputKbpsMean = "goodput_kbps_mean"
            }
        }
        struct Tip: Decodable { let reason: String }
        struct Report: Decodable { let local: Leg; let verdict: String; let tips: [Tip]? }
        struct Point: Decodable {
            let tMs: Int, rttMs: Int, lossPct: Double, relay: Bool
            enum CodingKeys: String, CodingKey { case rttMs = "rtt_ms", tMs = "t_ms", lossPct = "loss_pct", relay }
        }
        struct Switch: Decodable {
            let tMs: Int, relay: Bool, localAddr: String
            enum CodingKeys: String, CodingKey { case relay, tMs = "t_ms", localAddr = "local_addr" }
        }

        let startedMs: UInt64, durationMs: Int
        let context: Context
        let audio: Audio
        let report: Report
        let timeline: [Point]
        let pathSwitches: [Switch]
        enum CodingKeys: String, CodingKey {
            case context, audio, report, timeline
            case startedMs = "started_ms", durationMs = "duration_ms", pathSwitches = "path_switches"
        }
    }

    // MARK: - Storage (per thread)

    private static var directory: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Idfon/health", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(_ peerId: String) -> URL {
        let safe = peerId.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }

    /// Keep the last call's record with its thread. Cheap: one small JSON.
    static func store(_ json: String, for peerId: String?) {
        guard let peerId, !peerId.isEmpty, !json.isEmpty else { return }
        try? json.write(to: file(peerId), atomically: true, encoding: .utf8)
    }

    static func storedJSON(for peerId: String?) -> String? {
        guard let peerId, let text = try? String(contentsOf: file(peerId), encoding: .utf8) else { return nil }
        return text.isEmpty ? nil : text
    }

    static func decode(_ json: String) -> Record? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// The running call's record, mid-call. Empty when nothing is sampled
    /// (the Rust side already knows; a `media_live_state()` gate here once hid
    /// a live record whose listen leg happened to read 0).
    static func liveJSON() -> String? {
        guard let ptr = media_health_live_report() else { return nil }
        defer { rust_free_string(ptr) }
        let json = String(cString: ptr)
        return json.isEmpty ? nil : json
    }

    /// The running call's record when there is one, else this thread's last.
    static func currentJSON(for peerId: String) -> String? {
        liveJSON() ?? storedJSON(for: peerId)
    }

    /// Post the card into a thread: one summary line, then the picture.
    /// Returns `<live|stored>: <summary>` so a device run can assert both
    /// which record was read and what the user sees; nil when there is none.
    @discardableResult
    static func post(peerId: String, conversation: String?) -> String? {
        let live = liveJSON()
        guard let json = live ?? storedJSON(for: peerId), let record = decode(json) else {
            ChatStore.shared.appendOutgoing(ChatMessage(
                id: UUID().uuidString, peerId: peerId,
                kind: .text("No call to report for this thread yet."),
                outgoing: true, timestamp: Date(), conversation: conversation))
            return nil
        }
        ChatStore.shared.appendOutgoing(ChatMessage(
            id: UUID().uuidString, peerId: peerId, kind: .text(summary(record)),
            outgoing: true, timestamp: Date(), conversation: conversation))
        let posted = "\(live != nil ? "live" : "stored"): \(summary(record))"
        guard let image = render(record), let url = write(image: image, peerId: peerId) else { return posted }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        ChatStore.shared.appendOutgoing(ChatMessage(
            id: UUID().uuidString, peerId: peerId,
            kind: .file(ticket: "", name: url.lastPathComponent, sizeBytes: size, localURL: url),
            outgoing: true, timestamp: Date(), conversation: conversation))
        return posted
    }

    // MARK: - Text

    /// One line, complete on its own: the image is the detail, not the only
    /// way to read the numbers (VoiceOver gets this line).
    static func summary(_ r: Record) -> String {
        let lost = Double(r.audio.missingFrames) * 20 / 1000
        let path = r.pathSwitches.last.map { $0.relay ? "relay" : "direct \($0.localAddr)" } ?? "no path"
        return String(
            format: "Call health · %@ — %@, max gap %.1f s, %.0f s lost, %d stalls, RTT %d–%d ms, %.2f %% loss · %@",
            r.report.verdict, span(r.durationMs), Double(r.audio.maxGapMs) / 1000, lost,
            r.audio.stallsOver100ms, r.report.local.rttMsMin, r.report.local.rttMsMax,
            r.report.local.lossPctMean, path)
    }

    /// A call shorter than a minute reads in seconds: "0.0 min" is not a
    /// length (a quick tap-and-hangup call showed exactly that).
    private static func span(_ ms: Int) -> String {
        let seconds = Double(ms) / 1_000
        return seconds < 60 ? String(format: "%.0f s", seconds) : String(format: "%.1f min", seconds / 60)
    }

    // MARK: - Image

    /// The timeline as a picture: rtt line, loss bars, path-switch markers.
    /// Semantic colours so it reads in either appearance.
    static func render(_ r: Record) -> UIImage? {
        let size = CGSize(width: 900, height: 340)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            UIColor.secondarySystemGroupedBackground.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            let title = "Call health · \(r.report.verdict)" as NSString
            title.draw(at: CGPoint(x: 32, y: 26), withAttributes: [
                .font: UIFont.systemFont(ofSize: 26, weight: .semibold),
                .foregroundColor: UIColor.label,
            ])

            let lost = Double(r.audio.missingFrames) * 20 / 1000
            let subtitle = String(
                format: "%@ · %@ · max gap %.1f s · %.0f s lost · RTT %d–%d ms · %.2f %% loss",
                r.context.videoOn ? "video" : "audio", span(r.durationMs),
                Double(r.audio.maxGapMs) / 1000, lost,
                r.report.local.rttMsMin, r.report.local.rttMsMax, r.report.local.lossPctMean) as NSString
            subtitle.draw(at: CGPoint(x: 32, y: 66), withAttributes: [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.secondaryLabel,
            ])

            let plot = CGRect(x: 32, y: 110, width: 836, height: 150)
            UIColor.tertiarySystemFill.setFill()
            UIBezierPath(roundedRect: plot, cornerRadius: 10).fill()

            guard r.durationMs > 0, !r.timeline.isEmpty else {
                let empty = "no timeline (call too short to sample)" as NSString
                empty.draw(at: CGPoint(x: plot.minX + 16, y: plot.midY - 8), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: UIColor.secondaryLabel,
                ])
                return
            }

            let rtts = r.timeline.map(\.rttMs)
            let lo = rtts.min() ?? 0, hi = rtts.max() ?? 0
            func x(_ tMs: Int) -> CGFloat {
                plot.minX + CGFloat(tMs) / CGFloat(r.durationMs) * plot.width
            }
            func y(_ rtt: Int) -> CGFloat {
                // Scale to the call's own range; a steady RTT is a line through
                // the middle, not a line lying on the floor.
                let level = hi > lo ? CGFloat(rtt - lo) / CGFloat(hi - lo) : 0.5
                return plot.maxY - 10 - level * (plot.height - 20)
            }

            // Loss as bars from the bottom edge.
            UIColor.systemOrange.withAlphaComponent(0.45).setFill()
            for p in r.timeline where p.lossPct > 0.5 {
                let h = min(plot.height - 12, CGFloat(p.lossPct) * 6)
                UIRectFill(CGRect(x: x(p.tMs) - 1.5, y: plot.maxY - h, width: 3, height: h))
            }

            // RTT line.
            let line = UIBezierPath()
            for (index, p) in r.timeline.enumerated() {
                let point = CGPoint(x: x(p.tMs), y: y(p.rttMs))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            UIColor.systemBlue.setStroke()
            line.lineWidth = 2
            line.stroke()

            // Path switches: where the network changed under the call.
            for s in r.pathSwitches {
                let sx = x(s.tMs)
                let marker = UIBezierPath()
                marker.move(to: CGPoint(x: sx, y: plot.minY))
                marker.addLine(to: CGPoint(x: sx, y: plot.maxY))
                marker.lineWidth = 1
                (s.relay ? UIColor.systemPurple : UIColor.systemTeal).setStroke()
                marker.stroke()
            }

            let footer = "idfon · call started \(Self.date(r.startedMs)) · path: "
                + (r.pathSwitches.last.map { $0.relay ? "relay" : "direct \($0.localAddr)" } ?? "unknown")
            (footer as NSString).draw(at: CGPoint(x: 32, y: 292), withAttributes: [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor.secondaryLabel,
            ])
        }
    }

    /// Write the picture beside the record so a chat row can own a URL.
    static func write(image: UIImage, peerId: String) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("call-health-\(stamp).png")
        guard let data = image.pngData() else { return nil }
        return (try? data.write(to: url)) != nil ? url : nil
    }

    private static func date(_ ms: UInt64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}
