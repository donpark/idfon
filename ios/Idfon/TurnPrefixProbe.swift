import Darwin
import FluidAudio
import Foundation
import TygerVoice

/// `-turnprefixprobe [path]`: measure the 320 ms turn prefix on the device
/// without a call (#185). Loads through `TurnShadow.prefixModel` — the same
/// artifact lookup, step choice and initializer the shipping tier uses — runs
/// 2 warm-up + 24 synthetic 320 ms hops (swept sine mic, silence playback,
/// caches carried), optionally loads the ASR beside it, and writes a JSON
/// report. Absent the argument nothing runs; the probe changes no decision
/// logic, thresholds or model-loading semantics.
enum TurnPrefixProbe {
    private static let warmupHops = 2
    private static let measuredHops = 24

    static func run(arg: String?) {
        Task.detached(priority: .userInitiated) {
            let report = await measure()
            let url = reportURL(arg)
            write(report, to: url)
        }
    }

    private static func measure() async -> [String: Any] {
        let root = TygerModelStore.root
        let before = memory()
        var report: [String: Any] = [
            "probe": "turnprefix",
            "build": AppDelegate.buildStamp,
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "device": ["model": machine(), "os": ProcessInfo.processInfo.operatingSystemVersionString],
            "physicalMemoryBytes": Int64(ProcessInfo.processInfo.physicalMemory),
            "memoryMetric": "task_vm_info phys_footprint (resident_size also recorded)",
            "memory": [
                "beforeLoadBytes": Int64(before.footprint),
                "residentBeforeLoadBytes": Int64(before.resident),
            ],
            "asr": ["loaded": false],
        ]

        guard let artifact = TurnPrefix.artifact(in: root) else {
            report["prefix"] = [
                "root": root.path,
                "loadResult": "refused",
                "loadError": "no unique .mlpackage/.mlmodelc at \(root.path)/prefix",
            ]
            report["thermalState"] = thermal()
            return report
        }

        let artifactBytes = directoryBytes(artifact)
        let loadStart = DispatchTime.now().uptimeNanoseconds
        let model: TurnPrefixModel
        do {
            model = try TurnShadow.prefixModel(artifact: artifact, in: root)
        } catch {
            report["prefix"] = [
                "root": root.path,
                "artifact": artifact.lastPathComponent,
                "artifactBytes": Int64(artifactBytes),
                "loadResult": "refused",
                "loadError": String(describing: error),
            ]
            report["thermalState"] = thermal()
            return report
        }
        let loadMs = ms(loadStart)
        let afterLoad = memory()
        let s = model.shape
        report["prefix"] = [
            "root": root.path,
            "artifact": artifact.lastPathComponent,
            "artifactBytes": Int64(artifactBytes),
            "loadResult": "ok",
            "loadMs": loadMs,
            "cadenceMs": Double(TurnRuntime.hopSamples) / Double(TurnRuntime.sampleRate) * 1000,
            "batch": s.batch,
            "layers": s.layers,
            "cacheDepth": s.cacheDepth,
            "tapRowsPerChunk": s.tapRowsPerChunk,
            "totalMelFrames": s.totalMelFrames,
            "newMelFrames": s.newMelFrames,
            "hidden": s.hidden,
            "promptID": model.promptID,
            "stepModel": model.stepModelName,
        ]
        report["memory"] = [
            "beforeLoadBytes": Int64(before.footprint),
            "afterLoadBytes": Int64(afterLoad.footprint),
            "residentBeforeLoadBytes": Int64(before.resident),
            "residentAfterLoadBytes": Int64(afterLoad.resident),
        ]

        // Beside the prefix through FluidAudio's public manager path (the same
        // call the shipping ASR makes), not a private shortcut.
        #if NEMOTRON_MULTILINGUAL
        var asr: StreamingNemotronMultilingualAsrManager?
        #else
        var asr: StreamingNemotronAsrManager?
        #endif
        var asrStatus: [String: Any] = ["loaded": false]
        if #available(iOS 18.0, *) {
            let dir = NemotronStreamingAsr.modelDirectory()
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            if files.isEmpty {
                asrStatus["error"] = "no ASR files at \(dir.path)"
            } else {
                #if NEMOTRON_MULTILINGUAL
                let manager = StreamingNemotronMultilingualAsrManager()
                #else
                let manager = StreamingNemotronAsrManager()
                #endif
                do {
                    try await manager.loadModels(from: dir)
                    #if NEMOTRON_MULTILINGUAL
                    await manager.setLanguage(NemotronStreamingAsr.languageCode)
                    #endif
                    asr = manager
                    asrStatus = ["loaded": true, "directory": dir.path]
                } catch {
                    asrStatus["error"] = String(describing: error)
                }
            }
        } else {
            asrStatus["error"] = "iOS < 18 (Nemotron manager unavailable)"
        }
        let afterAsr = memory()
        report["asr"] = asrStatus
        var mem = report["memory"] as? [String: Any] ?? [:]
        mem["afterAsrBytes"] = Int64(afterAsr.footprint)
        mem["residentAfterAsrBytes"] = Int64(afterAsr.resident)
        report["memory"] = mem

        let hopSamples = TurnRuntime.hopSamples
        let silence = [Float](repeating: 0, count: hopSamples)
        let total = warmupHops + measuredHops
        let sines = (0..<total).map(sweepHop)
        for i in 0..<warmupHops {
            _ = model.encodePair(mic: sines[i], playback: silence)
        }
        var hopMs: [Double] = []
        hopMs.reserveCapacity(measuredHops)
        for i in warmupHops..<total {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = model.encodePair(mic: sines[i], playback: silence)
            hopMs.append(ms(start))
        }
        let afterRun = memory()
        mem["afterRunBytes"] = Int64(afterRun.footprint)
        mem["residentAfterRunBytes"] = Int64(afterRun.resident)
        report["memory"] = mem

        let sorted = hopMs.sorted()
        report["hops"] = [
            "warmup": warmupHops,
            "measured": measuredHops,
            "hopMs": hopMs,
            "p50Ms": percentile(sorted, 0.50),
            "p95Ms": percentile(sorted, 0.95),
            "maxMs": sorted.last ?? 0,
        ]
        report["thermalState"] = thermal()
        report["headroomAfterRunBytes"] = Int64(ProcessInfo.processInfo.physicalMemory)
            - Int64(afterRun.footprint)

        if let asr { await asr.cleanup() }
        return report
    }

    private static func sweepHop(_ index: Int) -> [Float] {
        let frequency = 200.0 + Double(index % 24) * 75.0
        return (0..<TurnRuntime.hopSamples).map {
            Float(0.1 * sin(2 * .pi * frequency * Double($0) / Double(TurnRuntime.sampleRate)))
        }
    }

    private static func reportURL(_ arg: String?) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var name = arg?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { name = "turnprefixprobe.json" }
        if name.hasPrefix("/") { return URL(fileURLWithPath: name) }
        if name.hasPrefix("Documents/") { name = String(name.dropFirst("Documents/".count)) }
        return docs.appendingPathComponent(name)
    }

    private static func write(_ report: [String: Any], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            idfonLog("turnprefixprobe: wrote \(url.path)")
        } catch {
            idfonLog("turnprefixprobe: write failed \(url.path): \(error)")
        }
    }

    /// The process footprint jetsam accounts against (and resident size for
    /// comparison), from `task_vm_info`.
    private static func memory() -> (footprint: UInt64, resident: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (UInt64(info.phys_footprint), UInt64(info.resident_size))
    }

    private static func directoryBytes(_ url: URL) -> UInt64 {
        guard let files = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in files {
            total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private static func ms(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(sorted.count - 1, max(0, rank))]
    }

    private static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func machine() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.machine", &value, &size, nil, 0)
        return String(cString: value)
    }
}
