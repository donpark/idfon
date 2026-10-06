// Runnable check for the macOS model-store path + migration logic:
//
//   swiftc -o /tmp/modelstorecheck \
//     mac/Sources/Idfon/ModelStore.swift mac/Checks/ModelStoreCheck/main.swift
//   /tmp/modelstorecheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

let fm = FileManager.default
let home = fm.temporaryDirectory.appendingPathComponent("idfon-modelstore-\(UUID().uuidString)")
setenv("IDFON_HOME", home.path, 1)
defer { try? fm.removeItem(at: home) }

check(ModelStore.root.path == home.appendingPathComponent("models").path, "root under IDFON_HOME")
check(ModelStore.directory(named: "parakeet-redux-coreml").path
    .hasSuffix("models/parakeet-redux-coreml"), "repo directory joins root")

// migrate moves once and never overwrites.
let src = home.appendingPathComponent("legacy/repo")
let dst = ModelStore.directory(named: "repo")
try! fm.createDirectory(at: src, withIntermediateDirectories: true)
try! Data("x".utf8).write(to: src.appendingPathComponent("f"))
check(ModelStore.migrate(from: src, to: dst) == dst, "migrate moves source")
check(fm.fileExists(atPath: dst.appendingPathComponent("f").path), "migrated file present")
check(!fm.fileExists(atPath: src.path), "source removed")
check(ModelStore.migrate(from: src, to: dst) == nil, "second migrate is a no-op")

print("ALL OK")
