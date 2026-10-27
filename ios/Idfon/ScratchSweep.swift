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
        for url in targets {
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { continue }
            if Date().timeIntervalSince(date) > olderThan {
                try? fm.removeItem(at: url)
            }
        }
    }
}
