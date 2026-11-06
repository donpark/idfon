import CryptoKit
import Foundation
import XCTest
@testable import TygerVoice

/// The round trip from `scripts/pack-tyger-models.mjs` to the app's prefix load
/// path, offline: read the packed manifest, install it the way
/// `TygerModelStore.fetch` does (verify sha256 + size, write `name` under the
/// store root), and load the artifact from `<root>/prefix`. No network.
///
/// The check needs a pack, so it skips without one. To reproduce:
///
///   node scripts/pack-tyger-models.mjs --only prefix \
///       --root bench-results --out /tmp/tyger-prefix-dry
///   IDFON_PREFIX_PACK=/tmp/tyger-prefix-dry swift test --filter PrefixPackTests
///
/// The artifact and the step are gitignored, so the load half also needs
/// `bench-results/coreml/StudentStep.mlpackage` (`IDFON_BENCH` overrides).
final class PrefixPackTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let name: String
            let asset: String
            let sha256: String
            let bytes: Int
        }
        let url_base: String
        let files: [Entry]
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var bench: URL {
        ProcessInfo.processInfo.environment["IDFON_BENCH"].map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("bench-results")
    }

    /// `TygerModelStore.installPath`: only `coreml/` is stripped (it installs at the
    /// root). Every other tier keeps its manifest path, which is what puts the
    /// prefix at `<root>/prefix`.
    private func installPath(_ name: String) -> String {
        name.hasPrefix("coreml/") ? String(name.dropFirst("coreml/".count)) : name
    }

    func testPackedPrefixInstallsAtTheStoreRootAndLoads() throws {
        guard let dir = ProcessInfo.processInfo.environment["IDFON_PREFIX_PACK"] else {
            throw XCTSkip("IDFON_PREFIX_PACK not set (run the packer first)")
        }
        let pack = URL(fileURLWithPath: dir)
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: pack.appendingPathComponent("manifest.json")))
        XCTAssertFalse(manifest.files.isEmpty)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tyger-prefix-pack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // Every entry is content-verified and installed by `name`, as the store does.
        for entry in manifest.files {
            XCTAssertEqual(entry.sha256.count, 64, "\(entry.name): hash shape")
            XCTAssertGreaterThan(entry.bytes, 0, "\(entry.name): size")
            XCTAssertFalse(entry.name.hasPrefix("/"), "\(entry.name): relative")
            XCTAssertFalse(entry.name.split(separator: "/").contains(".."), "\(entry.name): relative")
            let data = try Data(contentsOf: pack.appendingPathComponent(entry.asset))
            XCTAssertEqual(data.count, entry.bytes, "\(entry.name): packed size")
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                           entry.sha256, "\(entry.name): packed hash")
            let dest = root.appendingPathComponent(installPath(entry.name))
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest)
        }

        // The names must reconstruct `prefix/<pkg>/…` (and the sidecar beside it), so
        // the loader sees exactly one package and its declared metadata.
        let packages = manifest.files.filter { $0.name.hasSuffix(".mlpackage/Manifest.json") }
        XCTAssertEqual(packages.count, 1, "one package per prefix tier")
        for entry in manifest.files { XCTAssertTrue(entry.name.hasPrefix("prefix/"), entry.name) }
        XCTAssertTrue(manifest.files.contains { $0.name == "prefix/metadata.json" })

        guard let artifact = TurnPrefix.artifact(in: root) else {
            return XCTFail("TurnPrefix.artifact found no package under <root>/prefix")
        }
        XCTAssertEqual(artifact.deletingLastPathComponent().lastPathComponent, "prefix")
        XCTAssertEqual(artifact.pathExtension, "mlpackage")

        let metaURL = root.appendingPathComponent("prefix/metadata.json")
        let meta = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
        XCTAssertNotNil(meta["prompt_id"] as? Int, "the loader refuses without a declared prompt_id")
        XCTAssertEqual(meta["chunk_mel_frames"] as? Int, 32)
        XCTAssertEqual(meta["total_mel_frames"] as? Int, 41)
        let cache = try XCTUnwrap(meta["cache_channel_shape"] as? [Any])
        XCTAssertEqual(cache.count, 4)
        XCTAssertEqual(cache[2] as? Int, 42, "the artifact's cache depth, not the shipping 70")

        let step = bench.appendingPathComponent("coreml/StudentStep.mlpackage")
        guard FileManager.default.fileExists(atPath: step.path) else {
            throw XCTSkip("step artifact not exported: \(step.lastPathComponent)")
        }
        let model = try TurnPrefixModel(artifactURL: artifact, stepURL: step)
        XCTAssertEqual(model.shape.batch, 2)
        XCTAssertEqual(model.shape.layers, 4)
        XCTAssertEqual(model.shape.cacheDepth, 42)
        XCTAssertEqual(model.shape.totalMelFrames, 41)
        XCTAssertEqual(model.shape.newMelFrames, 32, "the 320 ms hop")
        XCTAssertEqual(model.shape.tapRowsPerChunk, 4, "4 tap rows per hop")
        XCTAssertEqual(model.promptID, meta["prompt_id"] as? Int)
    }
}
