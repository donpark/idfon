// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TygerVoice",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "TygerVoice", targets: ["TygerVoice"]),
        // The mac tier's MLX int8-g16 runtime (the platform-split ruling in
        // docs/voice-tyger-ondevice.md). Separate product so the iOS/CoreML
        // build never links MLX.
        .library(name: "TygerVoiceMLX", targets: ["TygerVoiceMLX"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3"),
    ],
    targets: [
        .target(name: "TygerVoice", path: "Sources/TygerVoice"),
        .target(
            name: "TygerVoiceMLX",
            dependencies: [
                "TygerVoice",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ],
            path: "Sources/TygerVoiceMLX"
        ),
        // The OS 27+ tier (Core AI .aimodel); availability-gated in source.
        .target(
            name: "TygerVoiceCoreAI",
            dependencies: ["TygerVoice"],
            path: "Sources/TygerVoiceCoreAI",
            linkerSettings: [.linkedFramework("CoreAI")]
        ),
        .testTarget(
            name: "TygerVoiceTests",
            dependencies: ["TygerVoice"],
            path: "Tests/TygerVoiceTests"
        ),
        .testTarget(
            name: "TygerVoiceMLXTests",
            dependencies: ["TygerVoiceMLX"],
            path: "Tests/TygerVoiceMLXTests"
        ),
        .testTarget(
            name: "TygerVoiceCoreAITests",
            dependencies: ["TygerVoiceCoreAI"],
            path: "Tests/TygerVoiceCoreAITests"
        ),
    ]
)
