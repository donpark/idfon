// Runnable check for the app-owned JSON-render model + tool registry, the
// action-audit rotation, and background-fetch bookkeeping (not part of the
// Xcode target). Foundation-only, so it runs on the host:
//
//   swiftc -o /tmp/jrcheck ios/Idfon/JSONRenderModel.swift ios/Idfon/ActionAudit.swift \
//     ios/Idfon/BackgroundFetch.swift ios/Checks/JSONRenderCheck/main.swift
//   /tmp/jrcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) {
    if !cond { print("FAIL:", msg); exit(1) }
    print("ok:", msg)
}

let specJSON = """
{"root":"c","elements":{
  "c":{"type":"Card","props":{"title":"Peer"},"children":["t","u","b"]},
  "t":{"type":"Text","props":{"value":"hi"}},
  "u":{"type":"UnapprovedCustomComponent","props":{}},
  "b":{"type":"Button","props":{"label":"Sync","action":"idfon.peers"}}
}}
"""

// Decode + normalize: known components kept, unknown ones dropped.
let spec = try JSONRenderSpec.decode(Data(specJSON.utf8))
let normalized = try spec.normalized()
check(normalized.elements["t"] != nil, "known Text kept")
check(normalized.elements["b"]?.props?["action"]?.string == "idfon.peers", "Button action read")
check(normalized.elements["u"] == nil, "unknown component dropped")
check(normalized.elements["c"]?.children == ["t", "b"], "unknown child id removed from children")

// A cycle must terminate and keep both nodes.
let cycleJSON = """
{"root":"a","elements":{
  "a":{"type":"Row","children":["b"]},
  "b":{"type":"Row","children":["a"]}
}}
"""
let cycle = try JSONRenderSpec.decode(Data(cycleJSON.utf8)).normalized()
check(cycle.elements.count == 2, "cycle terminates with both nodes")

// Limits + root validation.
func throwsError<T>(_ body: () throws -> T, _ expected: JSONRenderError) -> Bool {
    do { _ = try body(); return false } catch let error as JSONRenderError { return error == expected } catch { return false }
}
check(throwsError({ try JSONRenderSpec.decode(Data(specJSON.utf8), limits: SpecLimits(maxBytes: 1, maxElements: 10, maxDepth: 4)) }, .tooLarge), "byte limit enforced")
check(throwsError({ try JSONRenderSpec.decode(Data(specJSON.utf8), limits: SpecLimits(maxBytes: 1024, maxElements: 2, maxDepth: 4)) }, .tooManyElements), "element limit enforced")
let deep = try JSONRenderSpec.decode(Data(specJSON.utf8))
let shallow = try deep.normalized(limits: SpecLimits(maxBytes: 1024, maxElements: 10, maxDepth: 0))
check(shallow.elements["t"] == nil, "depth limit drops deeper nodes")
check(throwsError({ try JSONRenderSpec.decode(Data(#"{"root":"x","elements":{"x":{"type":"Nope"}}}"#.utf8)) }, .badRoot), "unknown root rejected")

// Audit log rotation: bounded size, one prior file kept.
let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("idfon-audit-check-\(UUID().uuidString)")
let auditFile = tmp.appendingPathComponent("action-audit.ndjson")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
try Data(repeating: 0x41, count: 32).write(to: auditFile)
ActionAudit.rotateIfNeeded(at: auditFile, maxBytes: 1024)
check(FileManager.default.fileExists(atPath: auditFile.path), "audit under limit is not rotated")
try Data(repeating: 0x42, count: 2048).write(to: auditFile)
ActionAudit.rotateIfNeeded(at: auditFile, maxBytes: 1024)
let rotated = tmp.appendingPathComponent("action-audit.ndjson.1")
check(!FileManager.default.fileExists(atPath: auditFile.path), "audit at limit rotates away")
check(FileManager.default.fileExists(atPath: rotated.path), "rotated audit kept as .1")
try? FileManager.default.removeItem(at: tmp)

// Background-fetch bookkeeping: stale pending tasks and staged files expire.
let now = Date()
let fresh = ["id": "1", "account": "a", "path": "/p", "at": "\(now.timeIntervalSince1970)"]
let stale = ["id": "2", "account": "a", "path": "/q", "at": "\(now.timeIntervalSince1970 - 7200)"]
let legacy = ["id": "3", "account": "a", "path": "/r"]
let kept = BackgroundFetch.pruned([fresh, stale, legacy], now: now, ttl: 3600)
check(
    kept.count == 2 && kept.contains { $0["id"] == "1" } && kept.contains { $0["id"] == "3" },
    "stale pending dropped, fresh and legacy kept"
)
check(BackgroundFetch.isStale(modified: now.addingTimeInterval(-7200), now: now, ttl: 3600), "old staged file is stale")
check(!BackgroundFetch.isStale(modified: now, now: now, ttl: 3600), "fresh staged file is not stale")
check(!BackgroundFetch.isStale(modified: nil, now: now, ttl: 3600), "unknown mtime is not stale")

// Tool registry: unknown denied, sensitive gated, safe runs.
let registry = RenderToolRegistry()
registry.register(RenderTool(name: "safe", description: "safe", sensitive: false, run: { _ in "ran" }))
registry.register(RenderTool(name: "risky", description: "risky", sensitive: true, run: { _ in "ran" }))
var audits: [RenderAudit] = []
registry.audit = { audits.append($0) }

func runChecks() async {
    check(await registry.dispatch("nope") == .failure(.unknown("nope")), "unknown action never runs")
    check(await registry.dispatch("risky") == .failure(.denied("risky")), "sensitive action denied without confirmation")
    check(await registry.dispatch("safe") == .success("ran"), "safe action runs")
    registry.confirm = { _ in true }
    check(await registry.dispatch("risky") == .success("ran"), "sensitive action runs once confirmed")
    check(audits.contains { $0.action == "nope" && $0.outcome == "unknown" }, "unknown action audited")
    check(audits.contains { $0.action == "risky" && $0.outcome == "denied" }, "denied sensitive action audited")
    check(audits.contains { $0.action == "risky" && $0.outcome == "ok: ran" }, "confirmed action audited")
    check(audits.count == 4, "every dispatch audited")
    print("ALL OK")
    exit(0)
}

Task { await runChecks() }
dispatchMain()
