// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AsrBundleSwap",
    platforms: [.macOS("15.0")],
    dependencies: [
        // Same upstream pin the apps and `tools/asr-tap-latency` use (v0.18.3),
        // so the managers under test are the ones that ship.
        .package(url: "https://github.com/FluidInference/FluidAudio",
                 revision: "c8b41f98eae668794dd0083bbe028fe7e6585051",
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
