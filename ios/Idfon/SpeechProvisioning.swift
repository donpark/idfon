import Foundation
#if canImport(BackgroundAssets)
import BackgroundAssets
#endif

/// A model the client can provision on device.
enum SpeechModel: String {
    case kokoroAne = "kokoro-ane"
    case whistle = "whistle"

    /// BackgroundAssets asset-pack identifier, configured by the host app
    /// (env for now). Unset keeps the engine's own download/cache path, so
    /// nothing changes until the packs are actually hosted.
    var assetPackID: String? {
        let value = ProcessInfo.processInfo.environment[assetPackEnv]
        return (value?.isEmpty == false) ? value : nil
    }

    private var assetPackEnv: String {
        switch self {
        case .kokoroAne: return "IDFON_KOKORO_PACK"
        case .whistle: return "IDFON_WHISTLE_PACK"
        }
    }

    /// A file that must exist inside the pack. FluidAudio caches the Kokoro
    /// chain under `kokoro-82m-coreml/ANE/` (`Repo.kokoroAne.folderName`), and
    /// `KokoroAneManager` is given the *models root* — the directory that
    /// contains `kokoro-82m-coreml/`. Locating the marker lets us hand back
    /// that root.
    var markerPath: String {
        switch self {
        case .kokoroAne: return "kokoro-82m-coreml/ANE/vocab.json"
        case .whistle: return "whistle.cact"
        }
    }

    /// Direct-download base URL for a locally hosted pack
    /// (`scripts/serve-speech-pack.sh`). Set `IDFON_KOKORO_PACK_URL` or pass
    /// `-speechpackurl <url>`; e.g. `http://192.168.1.20:8788/kokoro-ane/`.
    /// The app pulls `manifest.json` and the listed files into its caches.
    var directBaseURL: URL? {
        let raw = ProcessInfo.processInfo.environment[directEnv]
            ?? Self.launchArg(directFlag) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.hasSuffix("/") ? trimmed : trimmed + "/")
    }

    private var directEnv: String {
        switch self {
        case .kokoroAne: return "IDFON_KOKORO_PACK_URL"
        case .whistle: return "IDFON_WHISTLE_PACK_URL"
        }
    }

    private var directFlag: String {
        switch self {
        case .kokoroAne: return "-speechpackurl"
        case .whistle: return "-whistlepackurl"
        }
    }

    private static func launchArg(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: flag), args.count > index + 1 {
            return args[index + 1]
        }
        return nil
    }
}

/// Resolves a model directory, preferring a provisioned pack over the engine's
/// own download:
///
/// 1. an Apple-managed asset pack when `IDFON_KOKORO_PACK` names one and it is
///    available (iOS 26+);
/// 2. a directly downloaded pack when `IDFON_KOKORO_PACK_URL` is set;
/// 3. otherwise `nil` — the engine's own cache/download path (FluidAudio).
enum SpeechProvisioning {
    static func directory(for model: SpeechModel) async -> URL? {
        #if canImport(BackgroundAssets)
        if #available(iOS 26.0, *), let id = model.assetPackID,
           let directory = await assetPackDirectory(id: id, model: model) {
            return directory
        }
        #endif
        if let base = model.directBaseURL {
            return await directPackDirectory(base: base, model: model)
        }
        return nil
    }

    #if canImport(BackgroundAssets)
    // NOTE: this SDK exposes the new API only under its refined ObjC names
    // (`__BAAssetPackManager` etc.); the friendly Swift overlay isn't loaded,
    // so calling `BAAssetPackManager` directly fails to compile.
    @available(iOS 26.0, *)
    private static func assetPackDirectory(id: String, model: SpeechModel) async -> URL? {
        let manager = __BAAssetPackManager.shared
        let pack: __BAAssetPack? = await withCheckedContinuation { continuation in
            if #available(iOS 27.0, *) {
                manager.getManifestWithCompletionHandler { manifest, _ in
                    continuation.resume(returning: manifest?.assetPack(withID: id))
                }
            } else {
                manager.getAssetPack(withIdentifier: id) { pack, _ in
                    continuation.resume(returning: pack)
                }
            }
        }
        guard let pack else {
            Automation.mark("voice: asset pack \(id) not found; using engine download")
            return nil
        }
        let error: Error? = await withCheckedContinuation { continuation in
            manager.ensureLocalAvailability(of: pack) { error in
                continuation.resume(returning: error)
            }
        }
        if let error {
            Automation.mark("voice: asset pack \(id) failed: \(error.localizedDescription)")
            return nil
        }
        guard let marker = try? manager.url(forPath: model.markerPath) else {
            Automation.mark("voice: asset pack \(id) missing \(model.markerPath); using engine download")
            return nil
        }
        Automation.mark("voice: asset pack \(id) ready")
        return modelsRoot(containing: marker, markerPath: model.markerPath)
    }
    #endif

    // MARK: - Direct download

    private struct PackManifest: Decodable {
        struct Entry: Decodable {
            let path: String
            let bytes: Int
        }
        let files: [Entry]
    }

    /// Pulls the pack's files into the app cache and returns the models root.
    /// Idempotent: files already present at the right size are skipped, so a
    /// complete pack is a no-op on later calls.
    private static func directPackDirectory(base: URL, model: SpeechModel) async -> URL? {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let root = caches.appendingPathComponent("speech-packs/\(model.rawValue)", isDirectory: true)
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

    /// The models root: the directory that contains the marker's repo folder.
    /// `markerPath` is `kokoro-82m-coreml/ANE/vocab.json`, so walk up one
    /// component per path segment.
    private static func modelsRoot(containing marker: URL, markerPath: String) -> URL {
        var url = marker
        for _ in markerPath.split(separator: "/") {
            url.deleteLastPathComponent()
        }
        return url
    }
}
