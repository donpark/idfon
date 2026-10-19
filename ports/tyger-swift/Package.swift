// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TygerVoice",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "TygerVoice", targets: ["TygerVoice"]),
    ],
    targets: [
        .target(name: "TygerVoice", path: "Sources/TygerVoice"),
        .testTarget(name: "TygerVoiceTests", dependencies: ["TygerVoice"], path: "Tests/TygerVoiceTests"),
    ]
)
