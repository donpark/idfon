import Accelerate
import CoreVideo

/// Rescales camera frames to the dimensions the dylib's H.264 encoder is
/// configured from.
///
/// The encoder is initialised once from `PushFrameSource.format()` and never
/// re-reads dimensions per frame, so every pushed frame must match. macOS
/// session presets are advisory — a 1080p camera ignores `.hd1280x720` and the
/// `activeFormat` pin can silently fail — so the shell normalises instead of
/// hoping the camera cooperates.
///
/// Dependency-free (Accelerate only) so it can be checked on the host by
/// `mac/Checks/VideoScalingCheck`.
enum VideoScaling {
    /// Canonical size for the mac shell; mirrors the dylib's
    /// `default_dimensions()` for macOS.
    static let width = 1280
    static let height = 720

    /// Tightly-packed BGRA at `width`×`height`, or nil if scaling failed.
    /// `bytesPerRow` may be padded.
    static func canonicalBGRA(base: UnsafeMutableRawPointer,
                              width sourceWidth: Int,
                              height sourceHeight: Int,
                              bytesPerRow: Int) -> [UInt8]? {
        let destinationRowBytes = width * 4
        let count = destinationRowBytes * height
        var source = vImage_Buffer(
            data: base,
            height: vImagePixelCount(sourceHeight),
            width: vImagePixelCount(sourceWidth),
            rowBytes: bytesPerRow)
        guard let storage = malloc(count) else { return nil }
        defer { free(storage) }
        var destination = vImage_Buffer(
            data: storage,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: destinationRowBytes)
        // BGRA and ARGB8888 share byte layout for scaling; channel order is
        // irrelevant to a resample.
        guard vImageScale_ARGB8888(&source, &destination, nil,
                                   vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else {
            return nil
        }
        return Array(UnsafeBufferPointer(
            start: storage.assumingMemoryBound(to: UInt8.self), count: count))
    }
}
