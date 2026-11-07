import Foundation

/// Bubble replay P0 (#202): what a tap on a spoken (`callTranscript`) bubble
/// does. Pure decision — checked by `Checks/BubbleTapCheck` (run as
/// `swiftc -o /tmp/bubbletapcheck <app>/BubbleTap.swift
/// <app>/Checks/BubbleTapCheck/main.swift && /tmp/bubbletapcheck`).
///
/// A caller turn never gets a silent re-synthesis: its own audio is P2 and a
/// cloned voice is P3 (explicit opt-in), so P0 says so instead.
enum BubbleTap {
    enum Action: Equatable {
        case play
        case stop
        case notice(String)
    }

    /// `reading` marks the bubble that is currently playing — a tap on it
    /// always stops, even mid-call. `callActive` is any live call, dial, or
    /// watched stream (`LiveCall.shared.state != .idle`).
    static func action(role: String, text: String, final: Bool, callActive: Bool, reading: Bool) -> Action {
        if reading { return .stop }
        if callActive { return .notice("Replay is off during a call") }
        if text.isEmpty || text.allSatisfy({ $0.isWhitespace }) { return .notice("Nothing to read") }
        if !final { return .notice("This turn is still speaking") }
        if role != "agent" { return .notice("No stored audio for this turn") }
        return .play
    }
}
