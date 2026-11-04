// Runnable check for the Phonon bundle installer's dedupe:
//
//   swiftc -D PHONON_TTS -o /tmp/phononbundlecheck \
//     mac/Sources/Idfon/PhononBundle.swift mac/Checks/PhononBundleCheck/main.swift
//   /tmp/phononbundlecheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import CryptoKit
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// File identity; a fresh URL each time (a URL caches the values it read).
func inode(_ url: URL) -> NSObject? {
    (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileResourceIdentifierKey])
        .fileResourceIdentifier) as? NSObject
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("idfon-phononbundle-\(UUID().uuidString)")
defer { try? fm.removeItem(at: root) }
let served = root.appendingPathComponent("served")
let installed = root.appendingPathComponent("installed")

// A served bundle shaped like the real export: the flow LM's weights twice
// (same bytes, one 240 KB graph apart) plus a small file.
let weights = Data((0..<(1 << 20)).map { UInt8($0 % 251) })
let small = Data("graph".utf8)
func write(_ data: Data, _ path: String) {
    let url = served.appendingPathComponent(path)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}
write(weights, "flow-c414-t1.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
write(weights, "flow-c414-t48.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
write(small, "host.safetensors")
let manifest = """
{"built": 1, "files": [
 {"path": "flow-c414-t1.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "size": \(weights.count), "sha256": "\(sha(weights))"},
 {"path": "flow-c414-t48.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "size": \(weights.count), "sha256": "\(sha(weights))"},
 {"path": "host.safetensors", "size": \(small.count), "sha256": "\(sha(small))"}
]}
"""
try! Data(manifest.utf8).write(to: served.appendingPathComponent("bundle.json"))

let a = installed.appendingPathComponent("flow-c414-t1.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
let b = installed.appendingPathComponent("flow-c414-t48.mlpackage/Data/com.apple.CoreML/weights/weight.bin")

// 1. Fresh install: both paths, one inode.
let done = DispatchSemaphore(value: 0)
var installError: Error?
Task {
    do { _ = try await PhononBundle.install(from: served, to: installed) } catch { installError = error }
    done.signal()
}
done.wait()
check(installError == nil, "install succeeds: \(installError.map { "\($0)" } ?? "")")
check(fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path), "both flow paths installed")
check(inode(a) != nil && inode(a) == inode(b), "duplicate weights hardlinked to one file")
check(fm.fileExists(atPath: installed.appendingPathComponent("host.safetensors").path), "small file installed")
check(fm.fileExists(atPath: installed.appendingPathComponent("bundle.json").path), "bundle.json written")
let excluded = (try? installed.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup
check(excluded == true, "bundle excluded from backup")
// 2. A pre-dedupe install (two separate copies) relinks in place.
let separate = root.appendingPathComponent("separate")
try! fm.createDirectory(at: separate.appendingPathComponent("flow-c414-t1.mlpackage/Data/com.apple.CoreML/weights"),
                        withIntermediateDirectories: true)
try! fm.createDirectory(at: separate.appendingPathComponent("flow-c414-t48.mlpackage/Data/com.apple.CoreML/weights"),
                        withIntermediateDirectories: true)
try! weights.write(to: separate.appendingPathComponent("flow-c414-t1.mlpackage/Data/com.apple.CoreML/weights/weight.bin"))
try! weights.write(to: separate.appendingPathComponent("flow-c414-t48.mlpackage/Data/com.apple.CoreML/weights/weight.bin"))
try! small.write(to: separate.appendingPathComponent("host.safetensors"))
let c = separate.appendingPathComponent("flow-c414-t1.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
let d = separate.appendingPathComponent("flow-c414-t48.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
check(inode(c) != nil && inode(c) != inode(d), "two copies before relink")
let again = DispatchSemaphore(value: 0)
Task {
    do { _ = try await PhononBundle.install(from: served, to: separate) } catch { installError = error }
    again.signal()
}
again.wait()
check(installError == nil, "relink succeeds")
check(inode(c) == inode(d), "existing copies relinked")

// 3. Tampered file is re-fetched, not trusted by size alone.
let e = installed.appendingPathComponent("flow-c414-t1.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
try! Data(repeating: 0, count: weights.count).write(to: e)
let repair = DispatchSemaphore(value: 0)
Task {
    do { _ = try await PhononBundle.install(from: served, to: installed) } catch { installError = error }
    repair.signal()
}
repair.wait()
check(installError == nil, "repair succeeds")
check((try? Data(contentsOf: e)) == weights, "corrupt file replaced with the served bytes")

print("ALL OK")
