// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AsrBundleSwap",
    platforms: [.macOS("15.0")],
    dependencies: [
        // The same fork/revision the apps and `tools/asr-tap-latency` pin, so the
        // managers under test are the ones that ship.
        .package(url: "https://github.com/donpark/FluidAudio",
                 revision: "2ad9b4225769a9f644cee1995809918fb0fe2d27",
                 traits: []),
    ],
    targets: [
        .executableTarget(
            name: "asr-bundle-swap",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            // Both apps build in Swift 5 mode; AVAudioPCMBuffer crosses into the ASR
            // actor the same way there.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
