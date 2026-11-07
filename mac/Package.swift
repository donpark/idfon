// swift-tools-version:5.9
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// Phonon 31m TTS is compiled in by default (the voice-agent mouth);
// IDFON_TTS_PHONON=0 opts out.
let phonon = ProcessInfo.processInfo.environment["IDFON_TTS_PHONON"] != "0"

let package = Package(
    name: "Idfon",
    platforms: [.macOS("15.0")],
    dependencies: [
        // On-device speech models: Parakeet (ASR) + Kokoro (TTS).
        // Frozen at fork tag `idfon-tap-pin-1` (2ad9b42) — the resolution this repo was
        // verified against — so a resolve cannot drift to the moving fork branch.
        // `setEncoderOutputCallback` (raw encoder outputs) landed upstream as
        // FluidInference/FluidAudio#1109 (merged 2026-11-07, not yet in a release tag).
        // When a release tag contains it (post-v0.18.2), switch to
        // `FluidInference/FluidAudio` with a version pin and delete the fork.
        .package(url: "https://github.com/donpark/FluidAudio", revision: "2ad9b4225769a9f644cee1995809918fb0fe2d27"),
        // The turn-taker's Swift runtime (shared with iOS; MLX tier on mac).
        .package(path: "../ports/tyger-swift"),
    ]
        + (phonon
            ? [
                // Phonon 31m TTS (gradium); arm64-only compiled core.
                // Pinned range: 0.4.1's tag lacks its PhononCore release asset
                // (404) — shortcut: widen once gradium's tags and release
                // assets line up.
                .package(url: "https://github.com/gradium-ai/xn-ptts.git", "0.4.0"..<"0.4.1"),
            ]
            : []),
    targets: [
        // Hand-declared C ABI from crates/iroh-c-ffi (same approach as
        // the iOS bridging header: the library is the single source of truth).
        .target(name: "CIdfon"),
        .executableTarget(
            name: "Idfon",
            dependencies: [
                "CIdfon",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "TygerVoice", package: "tyger-swift"),
                .product(name: "TygerVoiceMLX", package: "tyger-swift"),
                .product(name: "TygerVoiceCoreAI", package: "tyger-swift"),
            ]
                + (phonon ? [.product(name: "ptts", package: "xn-ptts")] : []),
            linkerSettings: [
                .linkedLibrary("iroh_c_ffi"),
                // Everything macOS 26/27-only (the on-device director + Apple
                // Foundation Models, SystemConfiguration, libc++) lives in
                // libidfon_director.dylib (see build-deps.sh), dlopen'd by
                // CIdfon.c on first use, so the app links at macOS 15.
                .unsafeFlags(["-L\(packageDir)/Vendor"]),
            ]
        ),
    ]
)
