import Foundation

/// Whether a call-teardown message names the call it should end
/// (donpark/idfon#60).
///
/// Stops carry the call generation's ticket — the dialer's publish ticket,
/// known to both sides (the caller generated it, the callee received it in
/// the start invite). A stop with a **non-empty** ticket ends the call only
/// when it matches the current generation; an **empty** ticket is a legacy
/// sender (core.ts, watch-only) that carries no generation, so the old
/// terminate behavior is kept. A stop naming an older call is ignored — that
/// is what keeps an out-of-order straggler from cutting off a fresh ring.
enum CallStopCorrelation {
    static func names(_ stopTicket: String, current: String?) -> Bool {
        stopTicket.isEmpty || stopTicket == current
    }
}
