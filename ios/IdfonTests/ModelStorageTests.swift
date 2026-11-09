import CryptoKit
import XCTest

@testable import Idfon

final class ModelStorageTests: XCTestCase {
    func testPurgeRemovesOnlyRetiredSpeechModelDirectories() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-cleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }

        let retired = [
            "fluidaudio/Models/kokoro/model.bin",
            "fluidaudio/Models/kokoro-82m-coreml/model.bin",
            "FluidAudio/Models/parakeet-redux/model.bin",
        ]
        let retained = [
            "phonon/voices/custom.safetensors",
            "FluidAudio/Models/nemotron-streaming/560ms/model.bin",
        ]
        for path in retired + retained {
            let file = support.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }

        LegacyModelCleanup.purge(in: support)

        for path in retired {
            XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent(path).path))
        }
        for path in retained {
            XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent(path).path))
        }
    }

    func testOnlyVoiceEnabledAgentsTriggerSpeechModelWarmup() {
        let human = "model-warmup-human-\(UUID().uuidString)"
        let agent = "model-warmup-agent-\(UUID().uuidString)"
        let mutedAgent = "model-warmup-muted-\(UUID().uuidString)"
        defer {
            ContactCallProfiles.remove(for: human)
            ContactCallProfiles.remove(for: agent)
            ContactCallProfiles.remove(for: mutedAgent)
        }
        ContactCallProfiles.set(kind: .human, voice: true, for: human)
        ContactCallProfiles.set(kind: .agent, voice: true, for: agent)
        ContactCallProfiles.set(kind: .agent, voice: false, for: mutedAgent)
        XCTAssertFalse(ContactCallProfiles.shouldPrewarmModels(human))
        XCTAssertTrue(ContactCallProfiles.shouldPrewarmModels(agent))
        XCTAssertFalse(ContactCallProfiles.shouldPrewarmModels(mutedAgent))
    }

    func testPre27PolicyPurgesTheTygerCacheOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pre27-tyger-\(UUID().uuidString)")
        let marker = root.appendingPathComponent("coreai/encoder.aimodel")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: marker)
        defer { try? FileManager.default.removeItem(at: root) }

        TygerModelStore.purgePre27Store(at: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testCoreMLTierRequiresNonemptyModelWeights() throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-package-\(UUID().uuidString).mlpackage")
        defer { try? FileManager.default.removeItem(at: package) }
        XCTAssertFalse(VoiceModelGate.hasCoreMLPackage(at: package))

        for path in ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel"] {
            let file = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }
        XCTAssertFalse(VoiceModelGate.hasCoreMLPackage(at: package))

        let weights = package.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        try FileManager.default.createDirectory(
            at: weights.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: weights)
        XCTAssertTrue(VoiceModelGate.hasCoreMLPackage(at: package))
    }

    func testDynamicCoreMLTierRequiresDebugMapping() throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynamic-model-\(UUID().uuidString).mlpackage")
        defer { try? FileManager.default.removeItem(at: package) }
        for path in ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel",
                     "Data/com.apple.CoreML/weights/weight.bin"] {
            let file = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }
        XCTAssertFalse(VoiceModelGate.hasCoreMLPackage(at: package, requiresDebugMapping: true))
        try Data([1]).write(to: package.appendingPathComponent("executorch_debug_handle_mapping.json"))
        XCTAssertTrue(VoiceModelGate.hasCoreMLPackage(at: package, requiresDebugMapping: true))
    }

    func testCoreAITraitsMustMatchCurrentStudentTraits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreai-traits-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let coreai = root.appendingPathComponent("coreai")
        try FileManager.default.createDirectory(at: coreai, withIntermediateDirectories: true)
        let sharedTraits = root.appendingPathComponent("student.traits.json")
        let installedTraits = coreai.appendingPathComponent("student.traits.json")
        try Data("{\"ep_thr\":0.75}".utf8).write(to: sharedTraits)
        try Data("{\"ep_thr\":0.90}".utf8).write(to: installedTraits)
        XCTAssertFalse(VoiceModelGate.coreAITraitsAreCurrent(in: coreai, shared: root))

        try Data(contentsOf: sharedTraits).write(to: installedTraits)
        XCTAssertTrue(VoiceModelGate.coreAITraitsAreCurrent(in: coreai, shared: root))
    }

    func testManifestRetiresOnlyAssetsAbsentFromItsTier() {
        func entry(_ name: String) -> TygerModelStore.Manifest.Entry {
            .init(name: name, asset: name, sha256: String(repeating: "a", count: 64), bytes: 1, platform: nil)
        }
        let installed = [entry("coreai/old-step.aimodel"), entry("coreai/student_step.aimodel")]
        let wanted = [entry("coreai/student_step.aimodel")]
        XCTAssertEqual(
            TygerModelStore.obsoleteAssets(installed: installed, wanted: wanted).map(\.name),
            ["coreai/old-step.aimodel"])
    }

    @MainActor
    func testModelProgressAggregatesCachedAndDownloadedBytes() async {
        let finished = expectation(description: "all progress updates delivered")
        finished.expectedFulfillmentCount = 3
        var completed: [Int64] = []
        let progress = TygerModelStore.Progress(tier: "coreai", total: 10) { _, bytes, _ in
            completed.append(bytes)
            finished.fulfill()
        }
        progress.set("cached", bytes: 6, notify: false)
        progress.publish()
        progress.set("asset", bytes: 2)
        progress.set("asset", bytes: 4)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(completed, [6, 8, 10])
    }

    func testExistingSmallAssetsAreCheckedBySizeAndHash() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-sidecar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let expected = Data("current traits".utf8)
        try expected.write(to: file)
        let entry = TygerModelStore.Manifest.Entry(
            name: "coreai/student.traits.json", asset: "asset",
            sha256: SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined(),
            bytes: expected.count, platform: nil)
        XCTAssertTrue(TygerModelStore.existingFileMatches(entry, at: file))

        try Data("stale traits!!".utf8).write(to: file)
        XCTAssertFalse(TygerModelStore.existingFileMatches(entry, at: file))
    }
}
