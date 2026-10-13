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
                // Everything macOS 26/27-only (the on-device director + Apple
                // Foundation Models, SystemConfiguration, libc++) lives in
                // libidfon_director.dylib (see build-deps.sh), dlopen'd by
                // CIdfon.c on first use, so the app links at macOS 14.
                .unsafeFlags(["-L\(packageDir)/Vendor"]),
            ]
        ),
    ]
)
