import Foundation
#if canImport(BackgroundAssets)
import BackgroundAssets
#endif

/// A model the client can provision on device.
enum SpeechModel: String {
    case kokoroAne = "kokoro-ane"

    /// BackgroundAssets asset-pack identifier, configured by the host app
    /// (env for now). Unset keeps the engine's own download/cache path, so
    /// nothing changes until the packs are actually hosted.
    var assetPackID: String? {
        switch self {
        case .kokoroAne:
            let value = ProcessInfo.processInfo.environment["IDFON_KOKORO_PACK"] ?? ""
            return value.isEmpty ? nil : value
        }
    }

    /// A file that exists inside the pack; locating it gives us the directory
    /// FluidAudio should load from.
    var markerPath: String {
        switch self {
        case .kokoroAne: return "kokoro-ane/vocab.json"
        }
    }
}

/// Resolves a model directory, preferring an Apple-managed asset pack when one
/// is configured and available (iOS 26+); `nil` means "use the engine's own
/// cache/download path" (FluidAudio's HuggingFace downloader).
///
/// `<26` falls back to FluidAudio too — the legacy `BADownloadManager` has no
/// manifest/status semantics, so it isn't worth a second path here.
enum SpeechProvisioning {
    static func directory(for model: SpeechModel) async -> URL? {
        #if canImport(BackgroundAssets)
        if #available(iOS 26.0, *), let id = model.assetPackID {
            return await assetPackDirectory(id: id, model: model)
        }
        #endif
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
        return marker.deletingLastPathComponent()
    }
    #endif
}
