// Runnable check for the Phonon bundle installer's dedupe:
//
//   swiftc -D PHONON_TTS -o /tmp/phononbundlecheck \
//     mac/Sources/Idfon/PhononPack.swift mac/Checks/PhononPackCheck/main.swift
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
// (same bytes, one 240 KB graph apart) plus a small file. Files come from the
// content-addressed tree (`sha256/<hash>`), so one blob serves both paths.
let weights = Data((0..<(1 << 20)).map { UInt8($0 % 251) })
let small = Data("graph".utf8)
// Phonon's model metadata: a listed file at `bundle.json`. The index must
// never overwrite it ("bundle.json has no dims", 2026-11-01).
let meta = Data(#"{"dims":{"d":512},"ctx":32,"languages":["en"]}"#.utf8)
for data in [weights, small, meta] {
    let url = served.appendingPathComponent("sha256/\(sha(data))")
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}
let manifest = """
{"built": 1, "files": [
 {"path": "bundle.json", "size": \(meta.count), "sha256": "\(sha(meta))"},
 {"path": "flow-c414-t1.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "size": \(weights.count), "sha256": "\(sha(weights))"},
 {"path": "flow-c414-t48.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "size": \(weights.count), "sha256": "\(sha(weights))"},
 {"path": "host.safetensors", "size": \(small.count), "sha256": "\(sha(small))"}
]}
"""
try! Data(manifest.utf8).write(to: served.appendingPathComponent("pack.json"))

let a = installed.appendingPathComponent("flow-c414-t1.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
let b = installed.appendingPathComponent("flow-c414-t48.mlpackage/Data/com.apple.CoreML/weights/weight.bin")

// 1. Fresh install: both paths, one inode.
let done = DispatchSemaphore(value: 0)
var installError: Error?
Task {
    do { _ = try await PhononPack.download(from: served, to: installed) } catch { installError = error }
    done.signal()
}
done.wait()
check(installError == nil, "install succeeds: \(installError.map { "\($0)" } ?? "")")
check(fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path), "both flow paths installed")
check(inode(a) != nil && inode(a) == inode(b), "duplicate weights hardlinked to one file")
check(fm.fileExists(atPath: installed.appendingPathComponent("host.safetensors").path), "small file installed")
check((try? Data(contentsOf: installed.appendingPathComponent("bundle.json"))) == meta,
      "bundle.json is the model metadata, not the index")
check((try? Data(contentsOf: installed.appendingPathComponent("pack.json"))) == Data(manifest.utf8),
      "index installed as pack.json")
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
try! meta.write(to: separate.appendingPathComponent("bundle.json"))
try! Data(manifest.utf8).write(to: separate.appendingPathComponent("pack.json"))
let c = separate.appendingPathComponent("flow-c414-t1.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
let d = separate.appendingPathComponent("flow-c414-t48.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
check(inode(c) != nil && inode(c) != inode(d), "two copies before relink")
let again = DispatchSemaphore(value: 0)
Task {
    do { _ = try await PhononPack.download(from: served, to: separate) } catch { installError = error }
    again.signal()
}
again.wait()
check(installError == nil, "relink succeeds")
check(inode(c) == inode(d), "existing copies relinked")

// 3. Every launch verifies the pack, whatever the `built` stamp says: a
// damaged file is re-fetched, not loaded.
let e = installed.appendingPathComponent("flow-c414-t1.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
func run(_ label: String, from base: URL = served, into dir: URL? = nil) {
    let done = DispatchSemaphore(value: 0)
    installError = nil
    Task {
        do { _ = try await PhononPack.download(from: base, to: dir ?? installed) }
        catch { installError = error }
        done.signal()
    }
    done.wait()
    check(installError == nil, "\(label) succeeds")
}
try! Data(repeating: 0, count: weights.count).write(to: e)
run("damaged pack, same built")
check((try? Data(contentsOf: e)) == weights, "damaged file replaced with the served bytes")
check(inode(e) == inode(installed.appendingPathComponent("flow-c414-t48.mlpackage/Data/com.apple.CoreML/weights/weight.bin")),
      "repair keeps the dedupe")
try! Data(manifest.replacingOccurrences(of: "\"built\": 1", with: "\"built\": 2").utf8)
    .write(to: served.appendingPathComponent("pack.json"))
run("new built")
check((try? Data(contentsOf: e)) == weights, "new built stamp replaces the pack")
check(inode(e) == inode(installed.appendingPathComponent("flow-c414-t48.mlpackage/Data/com.apple.CoreML/weights/weight.bin")),
      "replaced pack is still deduped")

// 3b. Offline: an intact pack is still returned, a damaged one is refused.
let nowhere = URL(fileURLWithPath: root.appendingPathComponent("nowhere").path)
run("offline, intact pack", from: nowhere)
try! Data(repeating: 0, count: weights.count).write(to: e)
installError = nil
let offline = DispatchSemaphore(value: 0)
Task {
    do { _ = try await PhononPack.download(from: nowhere, to: installed) } catch { installError = error }
    offline.signal()
}
offline.wait()
check(installError != nil, "offline, damaged pack is refused")
run("repair after offline refusal")
check((try? Data(contentsOf: e)) == weights, "served bytes come back")

// 3c. The local (no pack URL) path asks the same question.
check(PhononPack.verified(at: installed), "installed pack verifies")
try! Data(repeating: 0, count: weights.count).write(to: e)
check(!PhononPack.verified(at: installed), "damaged pack does not verify")
run("repair")
check(PhononPack.verified(at: installed), "repaired pack verifies")

// 4. The compiled copies Core ML writes are relinked too, and a bundle with
// no compiled models yet is a no-op.
let compiledA = installed.appendingPathComponent("flow-c414-t1.mlmodelc/weights/weight.bin")
let compiledB = installed.appendingPathComponent("flow-c414-t48.mlmodelc/weights/weight.bin")
for path in [compiledA, compiledB] {
    try! fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! weights.write(to: path)
}
check(inode(compiledA) != inode(compiledB), "two compiled copies before relink")
PhononPack.relinkCompiled(at: installed)
check(inode(compiledA) == inode(compiledB), "compiled weights relinked")
check((try? Data(contentsOf: compiledB)) == weights, "relinked compiled weights intact")
let bare = root.appendingPathComponent("bare")
try! fm.createDirectory(at: bare, withIntermediateDirectories: true)
PhononPack.relinkCompiled(at: bare)
check(true, "relink without a manifest or compiled models is a no-op")

print("ALL OK")
