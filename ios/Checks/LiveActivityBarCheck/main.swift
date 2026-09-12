// Runnable layout/model check for LiveActivityBar (not part of the Xcode target).
// Compiles against the simulator SDK and runs headless via simctl:
//
//   SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
//   xcrun swiftc -sdk $SDK -target arm64-apple-ios17.0-simulator -o /tmp/labcheck-bin \
//     ios/Idfon/LiveActivityBar.swift ios/Idfon/OverlayWindow.swift ios/Idfon/LiveWaveformView.swift \
//     ios/Idfon/TransferCenter.swift ios/Checks/LiveActivityBarCheck/main.swift
//   xcrun simctl boot <udid>; xcrun simctl spawn <udid> /tmp/labcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import UIKit

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

// clock / compactText
check(LiveActivityBar.clock(222) == "03:42", "clock m:ss")
check(LiveActivityBar.clock(3723) == "1:02:03", "clock h:mm:ss")
var m = LiveActivityBarModel(peerId: "p1", handle: "@janedoe")
m.phase = .inCall; m.elapsed = 222
m.rows = [.init(id: "r1", name: "Archive.zip", kind: .transfer(fraction: 0.42, bytesPerSecond: 12_000_000))]
m.density = .compact
check(m.compactText == "03:42 @janedoe — 1 transfer", "compact text: \(m.compactText)")
m.rows.append(.init(id: "r2", name: "Demo.mp3", kind: .stream(position: 105, duration: 200, paused: false)))
check(m.compactText == "03:42 @janedoe — 1 transfer, 1 stream", "compact mixed: \(m.compactText)")
check(!m.isStaging, "inCall not staging")
var idle = LiveActivityBarModel(peerId: "p1", handle: "@janedoe"); idle.micOn = true
check(idle.isStaging, "idle+mic = staging")

// layout: expanded bar with tray at 393pt (iPhone) width
let bar = LiveActivityBar()
bar.translatesAutoresizingMaskIntoConstraints = false
let host = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 800))
host.addSubview(bar)
NSLayoutConstraint.activate([bar.topAnchor.constraint(equalTo: host.topAnchor), bar.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8), bar.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8)])
m.density = .expanded
bar.apply(m)
host.layoutIfNeeded()
print("expanded frame:", bar.frame)
check(bar.frame.width == 377, "expanded fills width")
check(bar.frame.height > 60 && bar.frame.height < 200, "expanded header+2 rows plausible height \(bar.frame.height)")
// header density: handle and timer on separate lines, neither truncates, header stays one control-row tall
func labels(_ v: UIView) -> [UILabel] { v.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? labels($0) } }
let handle = labels(bar).first { $0.text == "@janedoe" }!, timer = labels(bar).first { $0.text == "03:42" }!
print("handle frame:", handle.frame, "fits:", handle.intrinsicContentSize.width, "budget:", handle.superview!.superview!.frame.width - 16, "timer frame:", timer.frame)
check(handle.frame.width >= handle.intrinsicContentSize.width, "handle not truncated")
check(timer.frame.width >= timer.intrinsicContentSize.width, "timer not truncated")
check(handle.frame.minY < timer.frame.minY && handle.frame.minX == timer.frame.minX, "timer stacked under handle")
let headerBottom = handle.superview!.superview!.superview!.frame.maxY // textStack → identityStack → headerStack
print("header height:", headerBottom)
check(headerBottom == 60, "header stays 44 control + 8/8 margins tall: \(headerBottom)")
var intents: [LiveActivityBarIntent] = []
bar.onIntent = { intents.append($0) }
// tray row buttons exist
func buttons(_ v: UIView) -> [UIButton] { v.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons($0) } }
let visible = buttons(bar).filter { !$0.isHidden && $0.window == nil ? !$0.isHidden : true }.filter { b in var v: UIView? = b; while let x = v { if x.isHidden { return false }; v = x.superview }; return true }
print("visible buttons:", visible.map { $0.accessibilityLabel ?? $0.configuration?.title ?? "?" })
check(visible.count == 6, "mic cam end + cancel + pause stop") // 3 header, transfer: cancel, stream: pause+stop
func fire(_ b: UIButton) { for t in b.allTargets { for a in b.actions(forTarget: t, forControlEvent: .touchUpInside) ?? [] { _ = (t as AnyObject).perform(NSSelectorFromString(a)) } } }
fire(visible.first { $0.accessibilityLabel == "End" }!)
fire(visible.first { $0.configuration?.title == "Cancel" }!)
check(intents == [.end, .cancelRow("r1")], "intents \(intents)")

// compact pill hugs
let pill = LiveActivityBar(); pill.translatesAutoresizingMaskIntoConstraints = false
host.addSubview(pill)
NSLayoutConstraint.activate([pill.topAnchor.constraint(equalTo: host.topAnchor, constant: 100), pill.centerXAnchor.constraint(equalTo: host.centerXAnchor)])
m.density = .compact
pill.apply(m); host.layoutIfNeeded()
print("pill frame:", pill.frame, "radius", pill.layer.cornerRadius)
check(pill.frame.width < 377 && pill.frame.width > 100, "pill hugs content")
check(pill.layer.cornerRadius == pill.frame.height / 2, "pill capsule")

// incoming: answer/decline visible, verb hidden
m.phase = .incoming; m.density = .expanded; bar.apply(m); host.layoutIfNeeded()
let inc = buttons(bar).filter { b in var v: UIView? = b; while let x = v { if x.isHidden { return false }; v = x.superview }; return true }.map { $0.accessibilityLabel ?? $0.configuration?.title ?? "?" }
print("incoming buttons:", inc)
check(inc.contains("Answer") && inc.contains("Decline") && !inc.contains("End"), "incoming shows Answer/Decline")
m.phase = .idle; m.micOn = false; m.camOn = false; bar.apply(m)
check(bar.subviews.count > 0, "idle ok")

// §3 State 2: idle + a staging toggle → verb morphs Ping→Call
func visibleLabels() -> [String] {
    buttons(bar).filter { b in var v: UIView? = b; while let x = v { if x.isHidden { return false }; v = x.superview }; return true }
        .map { $0.accessibilityLabel ?? $0.configuration?.title ?? "?" }
}
m.phase = .idle; m.micOn = true; m.camOn = false; m.density = .expanded; bar.apply(m); host.layoutIfNeeded()
let staged = visibleLabels()
print("staging buttons:", staged)
check(staged.contains("Call") && !staged.contains("Ping"), "staging shows Call not Ping: \(staged)")
m.micOn = false; bar.apply(m); host.layoutIfNeeded()
let unstaged = visibleLabels()
check(unstaged.contains("Ping") && !unstaged.contains("Call"), "idle shows Ping not Call: \(unstaged)")

// §3 State 3: a call only carries the tracks it was published with, so a
// toggle for an absent track is hidden (both tracks shown otherwise).
m.phase = .inCall; m.density = .expanded; m.micOn = false; m.camOn = true
m.audioAvailable = false; m.videoAvailable = true; bar.apply(m); host.layoutIfNeeded()
let audioLess = visibleLabels()
print("audio-less buttons:", audioLess)
check(!audioLess.contains("Microphone") && audioLess.contains("Camera"), "audio-less call hides mic, keeps cam: \(audioLess)")
m.audioAvailable = true; m.videoAvailable = false; bar.apply(m); host.layoutIfNeeded()
let videoLess = visibleLabels()
print("video-less buttons:", videoLess)
check(videoLess.contains("Microphone") && !videoLess.contains("Camera"), "video-less call hides cam, keeps mic: \(videoLess)")
m.audioAvailable = true; m.videoAvailable = true; bar.apply(m); host.layoutIfNeeded()
let bothTracks = visibleLabels()
check(bothTracks.contains("Microphone") && bothTracks.contains("Camera"), "both toggles visible with both tracks: \(bothTracks)")

// §4 Session Tray registry (TransferCenter): begin/update/finish, per-peer rows,
// cancel routing, fraction clamping. The registry is @MainActor; the check runs
// on the main thread, so assume that isolation.
MainActor.assumeIsolated {
    let center = TransferCenter.shared
    var cancelled: [String] = []
    center.begin(id: "t1", peerId: "p1", name: "Voice message") { cancelled.append("t1") }
    center.begin(id: "t2", peerId: "p2", name: "Archive.zip") { cancelled.append("t2") }
    check(center.activePeerIds == ["p1", "p2"], "two peers active: \(center.activePeerIds)")
    center.update(id: "t1", fraction: 0.42, bytesPerSecond: 12_000_000)
    let t1 = center.rows(for: "p1")
    check(t1.count == 1 && t1[0].id == "t1" && t1[0].kind == .transfer(fraction: 0.42, bytesPerSecond: 12_000_000),
          "rows map a transfer: \(t1)")
    check(center.rows(for: "p3").isEmpty, "no rows for an uninvolved peer")
    center.update(id: "t1", fraction: 1.5, bytesPerSecond: 0)
    check(center.rows(for: "p1")[0].kind == .transfer(fraction: 1, bytesPerSecond: 0), "fraction clamped to 1")
    center.cancel(id: "t1")
    check(cancelled == ["t1"], "cancel routed to the producer: \(cancelled)")
    check(center.transfers.count == 2, "row stays until the producer finishes")
    center.finish(id: "t1")
    check(center.activePeerIds == ["p2"], "finish drops the peer: \(center.activePeerIds)")
    check(center.rows(for: "p2")[0].name == "Archive.zip", "other transfer untouched")
    center.finish(id: "t2")
    check(center.transfers.isEmpty, "all finished")
    center.finish(id: "t2")
    check(center.transfers.isEmpty, "finishing twice is a no-op")
}
print("ALL OK")
