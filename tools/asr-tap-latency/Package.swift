// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AsrTapLatency",
    platforms: [.macOS("15.0")],
    dependencies: [
        // The same fork/branch both apps pin for the tap consumer
        // (`mac/Package.resolved`: donpark/FluidAudio @ encoder-output-callback).
        // Pinned by revision so the probe builds offline and cannot drift.
        .package(url: "https://github.com/donpark/FluidAudio",
                 revision: "2ad9b4225769a9f644cee1995809918fb0fe2d27",
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
