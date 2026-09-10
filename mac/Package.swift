// swift-tools-version:5.9
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Idfon",
    platforms: [.macOS(.v13)],
    targets: [
        // Hand-declared C ABI from native/vendor/iroh-c-ffi (same approach as
        // the iOS bridging header: the library is the single source of truth).
        .target(name: "CIdfon"),
        .executableTarget(
            name: "Idfon",
            dependencies: ["CIdfon"],
            linkerSettings: [
                .linkedLibrary("iroh_c_ffi"),
                .unsafeFlags(["-L\(packageDir)/Vendor"]),
            ]
        ),
    ]
)