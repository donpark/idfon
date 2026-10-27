import Foundation

/// CoreAI's runtime compiler leaves `mpsgraph-*` workdirs (and `<x>_main.ir`
/// IR dumps) in tmp and orphans them when the process dies mid-compile —
/// ~4 GB per encoder load, the 2026-10-27 disk incident. iOS kills apps
/// mid-compile routinely, so sweep stale scratch at launch: age-gated, so a
/// compile in flight is never touched.
enum ScratchSweep {
    static func sweep(olderThan: TimeInterval = 3600,
                      in tmp: URL = URL(fileURLWithPath: NSTemporaryDirectory())) {
        let fm = FileManager.default
        var targets = (try? fm.contentsOfDirectory(
            at: tmp.appendingPathComponent("com.apple.MetalPerformanceShadersGraph"),
            includingPropertiesForKeys: nil)) ?? []
        targets += ((try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("_main.ir") }
        var removed = 0
        var bytes: Int64 = 0
        for url in targets {
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { continue }
            if Date().timeIntervalSince(date) > olderThan {
                bytes += sizeOf(url)
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        // The sweep's findings are diagnostic evidence (the 2026-10-27 disk
        // incident class): how much stale scratch this device carries.
        if removed > 0 {
            Diag.log("scratchsweep", ["removed": removed, "freed_bytes": bytes])
        }
    }

    private static func sizeOf(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if isDir.boolValue {
            let children = (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil)) ?? []
            return children.reduce(0) { $0 + sizeOf($1) }
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(size)
    }
}
