// swift-tools-version:5.9
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// Phonon 31m TTS is compiled in by default (the voice-agent mouth);
// IDFON_TTS_PHONON=0 opts out.
let phonon = ProcessInfo.processInfo.environment["IDFON_TTS_PHONON"] != "0"

let package = Package(
    name: "Idfon",
    // ptts (Phonon) needs macOS 15+; phonon builds raise the floor with it.
    platforms: [.macOS(phonon ? "15.0" : "14.0")],
    dependencies: [
        // On-device speech models: Parakeet (ASR) + Kokoro (TTS).
        .package(url: "https://github.com/FluidInference/FluidAudio", .upToNextMinor(from: "0.17.5")),
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
                // CIdfon.c on first use, so the app links at macOS 14.
                .unsafeFlags(["-L\(packageDir)/Vendor"]),
            ]
        ),
    ]
)
