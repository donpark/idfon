import Foundation
import XCTest
@testable import TygerVoice
@testable import TygerVoiceCoreAI

/// The AOT gate: an `.aimodelc` built by a newer toolchain than the runtime
/// understands must be *rejected*, because the Core AI loader segfaults instead
/// of throwing (2026-11-01: `coreai-build 3605.6.3` emits MPSGraph package 7.1.5,
/// iOS 27.0.x accepts ≤ 7.0.80 — the app died inside MPSGraph on a live call).
@available(macOS 27.0, *)
final class CoreAIPackageTests: XCTestCase {
    private func manifestPackage(_ version: String, at kid: URL) throws {
        let pkg = kid.appendingPathComponent("main-test-delegates/MPSGraph/mpsExecutable.mpsgraphpackage")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let plist: [String: Any] = ["Package Version": [version: ["Callables": [String: Any]()]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: pkg.appendingPathComponent("manifest.plist"))
    }

    private func tier(version: String, in root: URL) throws -> URL {
        let dir = root.appendingPathComponent("coreai")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["tyger_encoder_float32.aimodel", "tyger_step_float32.aimodel"] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
            let compiled = dir.appendingPathComponent(name.replacingOccurrences(of: ".aimodel", with: ".compiled.aimodel"))
            let kid = compiled.appendingPathComponent("child.h16s.aimodelc")
            try FileManager.default.createDirectory(at: kid, withIntermediateDirectories: true)
            try manifestPackage(version, at: kid)
        }
        return dir
    }

    func testNewerPackageIsNotLoadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coreai-gate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try tier(version: "7.1.5", in: root)
        XCTAssertFalse(CoreAITurnModel.loadable(in: dir), "7.1.5 exceeds the 7.0.80 runtime ceiling")
        XCTAssertThrowsError(try CoreAITurnModel(directory: dir))
    }

    func testOlderPackageIsLoadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coreai-gate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try tier(version: "7.0.63", in: root)
        XCTAssertTrue(CoreAITurnModel.loadable(in: dir))
    }
}
