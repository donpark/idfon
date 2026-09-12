// Runnable check for the mac Live Activity Bar + Session Tray registry
// (not part of the app target). AppKit views can be built on the host without a
// running app, so this needs no window:
//
//   swiftc -o /tmp/mac-labcheck mac/Sources/Idfon/LiveActivityBar.swift \
//     mac/Sources/Idfon/TransferCenter.swift mac/Checks/LiveActivityBarCheck/main.swift
//   /tmp/mac-labcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import AppKit

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

MainActor.assumeIsolated {
    // Formatters + compact pill text
    check(LiveActivityBar.clock(222) == "03:42", "clock m:ss")
    check(LiveActivityBar.clock(3723) == "1:02:03", "clock h:mm:ss")

    var m = LiveActivityBarModel(peerId: "p1", handle: "@janedoe")
    m.phase = .inCall
    m.elapsed = 222
    m.rows = [.init(id: "r1", name: "Archive.zip", kind: .transfer(fraction: 0.42, bytesPerSecond: 12_000_000))]
    m.density = .compact
    check(m.compactText == "03:42 @janedoe — 1 transfer", "compact text: \(m.compactText)")
    m.rows.append(.init(id: "r2", name: "Demo.mp3", kind: .stream(position: 105, duration: 200, paused: false)))
    check(m.compactText == "03:42 @janedoe — 1 transfer, 1 stream", "compact mixed: \(m.compactText)")

    // View visibility per state
    let bar = LiveActivityBar()
    bar.apply(m)
    var intents: [LiveActivityBarIntent] = []
    bar.onIntent = { intents.append($0) }

    func allButtons() -> [NSButton] {
        var found: [NSButton] = []
        func walk(_ v: NSView) {
            (v as? NSButton).map { found.append($0) }
            v.subviews.forEach(walk)
        }
        walk(bar)
        return found
    }
    func visibleIds() -> [String] {
        allButtons().filter { b in var v: NSView? = b; while let x = v { if x.isHidden { return false }; v = x.superview }; return true }
            .compactMap { $0.identifier?.rawValue }
    }
    func click(_ id: String) {
        guard let button = allButtons().first(where: { $0.identifier?.rawValue == id }) else { return }
        button.performClick(nil)
    }

    // In a call: stream toggles present and wired.
    m.phase = .inCall; m.density = .expanded; m.audioAvailable = true; m.videoAvailable = true
    m.micOn = false; m.camOn = false
    bar.apply(m)
    let inCall = visibleIds()
    print("in-call:", inCall)
    check(inCall.contains("mic") && inCall.contains("cam"), "in-call shows mic/cam: \(inCall)")
    intents.removeAll()
    click("mic"); click("cam")
    check(intents == [.toggleMic, .toggleCam], "in-call mic/cam emit toggles: \(intents)")

    // Idle and the ringing Bar have no stream toggles.
    m.phase = .idle; bar.apply(m)
    let idle = visibleIds()
    print("idle:", idle)
    check(!idle.contains("mic") && !idle.contains("cam"), "idle hides mic/cam: \(idle)")
    m.phase = .incoming; bar.apply(m)
    let incoming = visibleIds()
    print("incoming:", incoming)
    check(incoming.contains("answer") && incoming.contains("decline"), "incoming shows answer/decline: \(incoming)")
    check(!incoming.contains("mic") && !incoming.contains("cam"), "incoming hides mic/cam: \(incoming)")

    // A watch-only session publishes nothing, so it has no toggles.
    m.phase = .watching; m.audioAvailable = false; m.videoAvailable = false; bar.apply(m)
    let watching = visibleIds()
    print("watching:", watching)
    check(!watching.contains("mic") && !watching.contains("cam"), "watching hides mic/cam: \(watching)")
    intents.removeAll()
    click("verb")
    check(intents == [.end], "watching verb stops: \(intents)")

    // A track the session doesn't carry is hidden even mid-call.
    m.phase = .inCall; m.audioAvailable = false; m.videoAvailable = true; bar.apply(m)
    let audioLess = visibleIds()
    check(!audioLess.contains("mic") && audioLess.contains("cam"), "audio-less call hides mic: \(audioLess)")
    m.audioAvailable = true; m.videoAvailable = false; bar.apply(m)
    let videoLess = visibleIds()
    check(videoLess.contains("mic") && !videoLess.contains("cam"), "video-less call hides cam: \(videoLess)")

    // §4 Session Tray registry
    let center = TransferCenter.shared
    var cancelled: [String] = []
    center.begin(id: "t1", peerId: "p1", name: "Voice message") { cancelled.append("t1") }
    center.begin(id: "t2", peerId: "p2", name: "Archive.zip") { cancelled.append("t2") }
    check(center.activePeerIds == ["p1", "p2"], "two peers active: \(center.activePeerIds)")
    center.update(id: "t1", fraction: 0.42, bytesPerSecond: 12_000_000)
    let rows = center.rows(for: "p1")
    check(rows.count == 1 && rows[0].id == "t1"
            && rows[0].kind == .transfer(fraction: 0.42, bytesPerSecond: 12_000_000), "rows map a transfer: \(rows)")
    check(center.rows(for: "p3").isEmpty, "no rows for an uninvolved peer")
    center.update(id: "t1", fraction: 1.5, bytesPerSecond: 0)
    check(center.rows(for: "p1")[0].kind == .transfer(fraction: 1, bytesPerSecond: 0), "fraction clamped to 1")
    center.cancel(id: "t1")
    check(cancelled == ["t1"], "cancel routed to the producer: \(cancelled)")
    check(center.transfers.count == 2, "row stays until the producer finishes")
    center.finish(id: "t1")
    check(center.activePeerIds == ["p2"], "finish drops the peer: \(center.activePeerIds)")
    center.finish(id: "t2")
    check(center.transfers.isEmpty, "all finished")

    print("ALL OK")
}
