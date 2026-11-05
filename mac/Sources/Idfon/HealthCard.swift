import AppKit
import CIdfon
import Foundation

/// The per-call quality record (`idfon_media::health::CallRecord`) as the mac
/// shows it (docs/media-adaptation.md §C1/§C2) — the AppKit twin of
/// `ios/Idfon/HealthCard.swift`.
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
        directory.appendingPathComponent("\(peerId.replacingOccurrences(of: "/", with: "_")).json")
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

    /// The running call's record, mid-call. Empty when nothing is sampled (the
    /// Rust side already knows).
    static func liveJSON() -> String? {
        guard let pointer = media_health_live_report() else { return nil }
        defer { rust_free_string(pointer) }
        let json = String(cString: pointer)
        return json.isEmpty ? nil : json
    }

    static func decode(_ json: String) -> Record? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// Post the card into a thread: one summary line, then the picture.
    /// Returns `<live|stored>: <summary>` for the automation marker.
    @MainActor
    @discardableResult
    static func post(peerId: String, conversation: String?, store chats: ChatStore) -> String? {
        let live = liveJSON()
        guard let json = live ?? storedJSON(for: peerId), let record = decode(json) else {
            chats.appendOutgoing(ChatMessage(id: UUID().uuidString, peerId: peerId,
                                             kind: .text("No call to report for this thread yet."),
                                             outgoing: true, conversation: conversation))
            return nil
        }
        chats.appendOutgoing(ChatMessage(id: UUID().uuidString, peerId: peerId,
                                         kind: .text(summary(record)), outgoing: true,
                                         conversation: conversation))
        let posted = "\(live != nil ? "live" : "stored"): \(summary(record))"
        guard let image = render(record), let url = write(image: image, peerId: peerId) else { return posted }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        chats.appendOutgoing(ChatMessage(id: UUID().uuidString, peerId: peerId,
                                         kind: .file(ticket: "", name: url.lastPathComponent,
                                                     sizeBytes: size, localURL: url),
                                         outgoing: true, conversation: conversation))
        return posted
    }

    // MARK: - Text

    /// One line, complete on its own: the image is the detail, not the only
    /// way to read the numbers (VoiceOver gets this line).
    static func summary(_ record: Record) -> String {
        let lost = Double(record.audio.missingFrames) * 20 / 1000
        let path = record.pathSwitches.last.map { $0.relay ? "relay" : "direct \($0.localAddr)" } ?? "no path"
        return String(
            format: "Call health · %@ — %@, max gap %.1f s, %.0f s lost, %d stalls, RTT %d–%d ms, %.2f %% loss · %@",
            record.report.verdict, span(record.durationMs), Double(record.audio.maxGapMs) / 1000, lost,
            record.audio.stallsOver100ms, record.report.local.rttMsMin, record.report.local.rttMsMax,
            record.report.local.lossPctMean, path)
    }

    /// A call shorter than a minute reads in seconds: "0.0 min" is not a length.
    private static func span(_ ms: Int) -> String {
        let seconds = Double(ms) / 1_000
        return seconds < 60 ? String(format: "%.0f s", seconds) : String(format: "%.1f min", seconds / 60)
    }

    // MARK: - Image

    private static let size = NSSize(width: 900, height: 340)

    /// The timeline as a picture: rtt line, loss bars, path-switch markers.
    /// Semantic colours so it reads in either appearance. AppKit coordinates
    /// are bottom-up, so every top-left rect goes through `box(_:)`.
    static func render(_ record: Record) -> NSImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        func box(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: x, y: size.height - top - h, width: w, height: h)
        }
        func draw(_ text: String, _ rect: NSRect, _ attributes: [NSAttributedString.Key: Any]) {
            (text as NSString).draw(in: rect, withAttributes: attributes)
        }

        NSColor.controlBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()

        draw("Call health · \(record.report.verdict)", box(32, 26, 836, 34), [
            .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        let lost = Double(record.audio.missingFrames) * 20 / 1000
        draw(String(
            format: "%@ · %@ · max gap %.1f s · %.0f s lost · RTT %d–%d ms · %.2f %% loss",
            record.context.videoOn ? "video" : "audio", span(record.durationMs),
            Double(record.audio.maxGapMs) / 1000, lost,
            record.report.local.rttMsMin, record.report.local.rttMsMax,
            record.report.local.lossPctMean), box(32, 66, 836, 22), [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])

        let plot = box(32, 110, 836, 150)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: plot, xRadius: 10, yRadius: 10).fill()

        guard record.durationMs > 0, !record.timeline.isEmpty else {
            draw("no timeline (call too short to sample)", box(plot.minX + 16, 172, 600, 20), [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let image = NSImage(size: size)
            image.addRepresentation(rep)
            return image
        }

        let rtts = record.timeline.map(\.rttMs)
        let lo = rtts.min() ?? 0, hi = rtts.max() ?? 0
        func x(_ tMs: Int) -> CGFloat {
            plot.minX + CGFloat(tMs) / CGFloat(record.durationMs) * plot.width
        }
        // Top-left y inside the plot: 10pt inset, high RTT at the top.
        func top(_ rtt: Int) -> CGFloat {
            let level = hi > lo ? CGFloat(rtt - lo) / CGFloat(hi - lo) : 0.5
            return plot.height - 10 - level * (plot.height - 20)
        }

        // Loss as bars from the bottom edge.
        NSColor.systemOrange.withAlphaComponent(0.45).setFill()
        for point in record.timeline where point.lossPct > 0.5 {
            let h = min(plot.height - 12, CGFloat(point.lossPct) * 6)
            NSRect(x: x(point.tMs) - 1.5, y: plot.minY, width: 3, height: h).fill()
        }

        // RTT line.
        let line = NSBezierPath()
        for (index, point) in record.timeline.enumerated() {
            let at = NSPoint(x: x(point.tMs), y: plot.maxY - top(point.rttMs))
            if index == 0 { line.move(to: at) } else { line.line(to: at) }
        }
        NSColor.systemBlue.setStroke()
        line.lineWidth = 2
        line.stroke()

        // Path switches: where the network changed under the call.
        for change in record.pathSwitches {
            let marker = NSBezierPath()
            let sx = x(change.tMs)
            marker.move(to: NSPoint(x: sx, y: plot.minY))
            marker.line(to: NSPoint(x: sx, y: plot.maxY))
            marker.lineWidth = 1
            (change.relay ? NSColor.systemPurple : NSColor.systemTeal).setStroke()
            marker.stroke()
        }

        let path = record.pathSwitches.last.map { $0.relay ? "relay" : "direct \($0.localAddr)" } ?? "unknown"
        draw("idfon · call started \(date(record.startedMs)) · path: \(path)", box(32, 292, 836, 22), [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Write the picture beside the record so a chat row can own a URL.
    static func write(image: NSImage, peerId: String) -> URL? {
        guard let rep = image.representations.first as? NSBitmapImageRep,
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("call-health-\(stamp).png")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    private static func date(_ ms: UInt64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}
