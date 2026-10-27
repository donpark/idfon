// Runnable check for ScratchSweep (the CoreAI compiler-scratch cleanup):
//
//   swiftc -o /tmp/scratchsweepcheck \
//     mac/Sources/Idfon/ScratchSweep.swift mac/Checks/ScratchSweepCheck/main.swift
//   /tmp/scratchsweepcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("idfon-scratchsweep-\(UUID().uuidString)")
let graph = tmp.appendingPathComponent("com.apple.MetalPerformanceShadersGraph")
try! fm.createDirectory(at: graph, withIntermediateDirectories: true)

func touch(_ url: URL, age: TimeInterval) {
    try! Data("x".utf8).write(to: url)
    try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
}
let old = graph.appendingPathComponent("mpsgraph-1-dead")
try! fm.createDirectory(at: old, withIntermediateDirectories: true)
touch(old.appendingPathComponent("scratch.bc.mlir"), age: 7200)
try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)
let fresh = graph.appendingPathComponent("mpsgraph-2-live-compile")
try! fm.createDirectory(at: fresh, withIntermediateDirectories: true)
touch(fresh.appendingPathComponent("scratch.bc.mlir"), age: 0)
let oldIr = tmp.appendingPathComponent("abc_main.ir")
touch(oldIr, age: 7200)
let freshIr = tmp.appendingPathComponent("def_main.ir")
touch(freshIr, age: 0)
let unrelated = tmp.appendingPathComponent("keepme.txt")
touch(unrelated, age: 7200)

ScratchSweep.sweep(olderThan: 3600, in: tmp)

check(!fm.fileExists(atPath: old.path), "stale mpsgraph workdir swept")
check(fm.fileExists(atPath: fresh.path), "fresh mpsgraph workdir kept (compile in flight)")
check(!fm.fileExists(atPath: oldIr.path), "stale _main.ir swept")
check(fm.fileExists(atPath: freshIr.path), "fresh _main.ir kept")
check(fm.fileExists(atPath: unrelated.path), "unrelated tmp files untouched")
try? fm.removeItem(at: tmp)
print("ALL OK")
