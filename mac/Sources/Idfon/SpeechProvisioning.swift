import Foundation

/// A model the client can provision on device.
enum SpeechModel: String {
    case kokoroAne = "kokoro-ane"

    /// Path inside the pack that must exist; locating it gives us the
    /// directory the engine loads from.
    var markerPath: String { "kokoro-82m-coreml/ANE/vocab.json" }

    /// Direct-download base URL for a locally hosted pack
    /// (`scripts/serve-speech-pack.sh`). Set the env var or launch flag; e.g.
    /// `http://192.168.1.20:8788/kokoro-ane/`.
    var directBaseURL: URL? {
        let raw = ProcessInfo.processInfo.environment[Self.directEnv]
            ?? Self.launchArg(Self.directFlag) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.hasSuffix("/") ? trimmed : trimmed + "/")
    }

    private static let directEnv = "IDFON_KOKORO_PACK_URL"
    private static let directFlag = "-speechpackurl"

    private static func launchArg(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: flag), args.count > index + 1 {
            return args[index + 1]
        }
        return nil
    }
}

/// Resolves a model directory from a directly downloaded pack, else `nil` (the
/// engine's own FluidAudio cache/download path).
///
/// The Apple-managed `BAAssetPackManager` path used on iOS needs a managed
/// downloader extension + app group; mac uses the direct pack only.
enum SpeechProvisioning {
    static func directory(for model: SpeechModel) async -> URL? {
        if let base = model.directBaseURL {
            return await directPackDirectory(base: base, model: model)
        }
        return nil
    }

    private struct PackManifest: Decodable {
        struct Entry: Decodable {
            let path: String
            let bytes: Int
        }
        let files: [Entry]
    }

    /// Pulls the pack's files into the app cache and returns the models root.
    /// Idempotent: files already present at the right size are skipped.
    private static func directPackDirectory(base: URL, model: SpeechModel) async -> URL? {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let root = caches.appendingPathComponent("idfon/speech-packs/\(model.rawValue)", isDirectory: true)
        let marker = root.appendingPathComponent(model.markerPath)
        if fm.fileExists(atPath: marker.path) {
            Automation.mark("voice: speech pack \(model.rawValue) cached")
            return root
        }
        guard let manifest = await fetchManifest(base: base) else { return nil }
        Automation.mark("voice: speech pack \(model.rawValue) downloading \(manifest.files.count) files")
        for entry in manifest.files {
            let dest = root.appendingPathComponent(entry.path)
            if let size = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int,
               size == entry.bytes {
                continue
            }
            guard let url = URL(string: entry.path, relativeTo: base),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                Automation.mark("voice: speech pack fetch failed \(entry.path)")
                return nil
            }
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: dest, options: .atomic)
        }
        guard fm.fileExists(atPath: marker.path) else {
            Automation.mark("voice: speech pack \(model.rawValue) incomplete")
            return nil
        }
        Automation.mark("voice: speech pack \(model.rawValue) ready")
        return root
    }

    private static func fetchManifest(base: URL) async -> PackManifest? {
        guard let url = URL(string: "manifest.json", relativeTo: base),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            Automation.mark("voice: speech pack manifest fetch failed")
            return nil
        }
        guard let manifest = try? JSONDecoder().decode(PackManifest.self, from: data) else {
            Automation.mark("voice: speech pack manifest malformed")
            return nil
        }
        return manifest
    }
}
