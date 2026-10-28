import CIdfon
import Foundation

/// The connection health check (docs/media-adaptation.md §B2.2): runs the
/// shared tracer (`media_health_check*`) and decodes its Progress JSON for
/// the shell. Presentation lives in the callers; this file is only the
/// runner and the models — the same contract any shell consumes.
final class HealthCheck {
    static let shared = HealthCheck()

    /// One leg of the check: what one endpoint measured over the window.
    struct Leg: Decodable {
        let rttMsMin: UInt64
        let rttMsMax: UInt64
        let lossPctMean: Double
        let goodputKbpsMean: UInt64?
        let audioUnderrunSamples: UInt64

        enum CodingKeys: String, CodingKey {
            case rttMsMin = "rtt_ms_min"
            case rttMsMax = "rtt_ms_max"
            case lossPctMean = "loss_pct_mean"
            case goodputKbpsMean = "goodput_kbps_mean"
            case audioUnderrunSamples = "audio_underrun_samples"
        }
    }

    /// One suggestion; `action` is the policy degradation it maps to.
    struct Tip: Decodable {
        let action: String
        let reason: String
    }

    struct Report: Decodable {
        let local: Leg
        let remote: Leg?
        let verdict: String
        let tips: [Tip]
    }

    enum Event {
        case sampling(elapsedMs: UInt64, totalMs: UInt64)
        case done(Report)
    }

    fileprivate var handler: ((Event) -> Void)?

    /// Run a check over the live session. `peerTicket` names the far end
    /// (its LiveTicket, what call setup already holds); pass `nil` for a
    /// one-sided check. `durationMs` is the sampling window.
    func run(peerTicket: String?, durationMs: UInt64 = 2_500, onEvent: @escaping (Event) -> Void) {
        handler = onEvent
        let start: UInt8
        if let peerTicket, !peerTicket.isEmpty {
            start = media_health_check_ticket(nil, healthCallback, durationMs, peerTicket)
        } else {
            start = media_health_check(nil, healthCallback, durationMs)
        }
        guard start == 0 else {
            self.handler = nil
            onEvent(.done(Report(
                local: Leg(rttMsMin: 0, rttMsMax: 0, lossPctMean: 0, goodputKbpsMean: nil, audioUnderrunSamples: 0),
                remote: nil,
                verdict: "unavailable",
                tips: []
            )))
            return
        }
    }
}

/// The C trampoline: the Rust runner calls this on its worker thread with
/// Progress JSON. No context is needed; the singleton routes it.
private func healthCallback(
    _ ctx: UnsafeRawPointer?,
    _ json: UnsafePointer<UInt8>?,
    _ len: Int,
    _ done: UInt8
) {
    guard let json else { return }
    let data = Data(bytes: json, count: len)
    struct Sampling: Decodable {
        let elapsedMs: UInt64
        let totalMs: UInt64
        enum CodingKeys: String, CodingKey {
            case elapsedMs = "elapsed_ms"
            case totalMs = "total_ms"
        }
    }
    struct Done: Decodable {
        let report: HealthCheck.Report
    }
    struct Envelope: Decodable {
        let kind: String
    }
    DispatchQueue.main.async {
        let decoder = JSONDecoder()
        let event: HealthCheck.Event
        if done != 0,
           let decoded = try? decoder.decode(Done.self, from: data) {
            event = .done(decoded.report)
        } else if let decoded = try? decoder.decode(Sampling.self, from: data) {
            event = .sampling(elapsedMs: decoded.elapsedMs, totalMs: decoded.totalMs)
        } else {
            return
        }
        HealthCheck.shared.handler?(event)
    }
}
