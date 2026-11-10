import Foundation
/// Parsed IDFON-LIVE/1 invite envelope (native/src/core.ts parseLiveInvite).
/// Shape: "IDFON-LIVE/1\naction=start\nmedia=video-call\nticket=<ticket>"
/// Optional `addr=` line (C20): the publisher's live EndpointAddr JSON,
/// base64 on the wire — the subscriber merges it into the ticket so the dial
/// does not race pkarr/DNS at call-setup time.
///
/// Kept self-contained (Foundation + `IncomingCallMode` only) so
/// `ios/Checks/LiveInviteCheck` can compile it with plain swiftc.
struct LiveInvite {
    let isStart: Bool
    let isStop: Bool
    /// media line value: nil = audio, "video" = one-way file share,
    /// "video-call" = live camera call.
    let media: String?
    let isCall: Bool // media=video-call (live camera call)
    let isReturn: Bool // holder response to an outgoing call
    let callMode: IncomingCallMode?
    let ticket: String
    /// The publisher's live `EndpointAddr` JSON (base64 on the wire, C20):
    /// the subscriber merges it into the ticket so the dial does not race
    /// pkarr/DNS at call-setup time. Absent from old peers → discovery.
    let addr: String?

    static func parse(_ text: String) -> LiveInvite? {
        guard text.hasPrefix("IDFON-LIVE/1\n") else { return nil }
        let body = text.dropFirst("IDFON-LIVE/1\n".count)
        guard body.hasPrefix("action=") else { return nil }
        var fields: [String: String] = [:]
        var lastKey: String?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if let eq = line.firstIndex(of: "=") {
                lastKey = String(line[..<eq])
                fields[lastKey!] = String(line[line.index(after: eq)...])
            } else if let key = lastKey, !line.isEmpty {
                // ticket values never contain newlines, but be tolerant
                fields[key]? += "\n" + line
            }
        }
        guard let action = fields["action"] else { return nil }
        let media = fields["media"]
        return LiveInvite(
            isStart: action == "start",
            isStop: action == "stop",
            media: media,
            isCall: media == "video-call",
            isReturn: fields["return"] == "1",
            callMode: fields["call_mode"].flatMap(IncomingCallMode.init(rawValue:)),
            ticket: fields["ticket"] ?? "",
            addr: fields["addr"]
                .flatMap { Data(base64Encoded: $0) }
                .flatMap { String(data: $0, encoding: .utf8) }
        )
    }

    static func build(
        action: String, ticket: String, call: Bool, callMode: IncomingCallMode = .bar,
        addr: String = "", isReturn: Bool = false
    ) -> String {
        let media = call ? "video-call" : "video"
        let mode = action == "start" && callMode.usesCallKit ? "\ncall_mode=call_kit" : ""
        let addrLine = addr.isEmpty ? "" : "\naddr=\(Data(addr.utf8).base64EncodedString())"
        let returnLine = isReturn ? "\nreturn=1" : ""
        return "IDFON-LIVE/1\naction=\(action)\nmedia=\(media)\nticket=\(ticket)\(addrLine)\(returnLine)\(mode)"
    }
}
