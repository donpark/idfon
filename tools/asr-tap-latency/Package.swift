// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AsrTapLatency",
    platforms: [.macOS("15.0")],
    dependencies: [
        // Same upstream pin the apps use (v0.18.3, which ships #1109's
        // `setEncoderOutputCallback`). Pinned by revision so the probe builds
        // offline and cannot drift.
        .package(url: "https://github.com/FluidInference/FluidAudio",
                 revision: "c8b41f98eae668794dd0083bbe028fe7e6585051",
                 traits: []),  // ASR only: no TTS, diarizer or text-normalizer engine
    ],
    targets: [
        .executableTarget(
            name: "asr-tap-latency",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            // Both apps build in Swift 5 mode; AVAudioPCMBuffer crosses into the ASR
            // actor the same way there (the buffer is consumed synchronously).
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
