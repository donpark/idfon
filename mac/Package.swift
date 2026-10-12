// swift-tools-version:5.9
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Idfon",
    platforms: [.macOS(.v14)],
    dependencies: [
        // On-device speech models: Parakeet (ASR) + Kokoro (TTS).
        .package(url: "https://github.com/FluidInference/FluidAudio", .upToNextMinor(from: "0.17.5")),
    ],
    targets: [
        // Hand-declared C ABI from native/vendor/iroh-c-ffi (same approach as
        // the iOS bridging header: the library is the single source of truth).
        .target(name: "CIdfon"),
        .executableTarget(
            name: "Idfon",
            dependencies: [
                "CIdfon",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            linkerSettings: [
                .linkedLibrary("iroh_c_ffi"),
                .linkedLibrary("idfon_director"),
                .linkedLibrary("c++"),
                // hyper-util's system-proxy matcher (pulled in with the director)
                // needs the SystemConfiguration C API.
                .linkedFramework("SystemConfiguration"),
                // The director's AFM shim references FoundationModels, which
                // only exists from macOS 26. Weak-link it so the app still
                // *launches* below that floor (no agent contact is seeded
                // there, so no director is ever created).
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
                .unsafeFlags(["-L\(packageDir)/Vendor"]),
            ]
        ),
    ]
)
