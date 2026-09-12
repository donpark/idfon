import Accelerate

/// Rescales camera frames to the dimensions the dylib's H.264 encoder is
/// configured from.
///
/// The encoder is initialised once from `PushFrameSource.format()` and never
/// re-reads dimensions per frame, so every pushed frame must match — and the
/// dylib now takes the per-OS default as authoritative. iOS *should* deliver
/// portrait buffers because the capture connection sets `videoOrientation`, but
/// that is a behaviour worth not betting the video stream on, so the shell
/// normalises: a landscape buffer is quarter-turned, then everything is scaled
/// to 720×1280.
///
/// Dependency-free (Accelerate only) so it can be checked on the host by
/// `mac/Checks/VideoScalingCheck` (compiled against this file).
enum VideoScaling {
    /// Canonical size for the iOS shell; mirrors the dylib's
    /// `default_dimensions()` for iOS (portrait).
    static let width = 720
    static let height = 1280

    /// Tightly-packed BGRA at `width`×`height`, or nil if the conversion failed.
    /// `bytesPerRow` may be padded; a landscape source is rotated to portrait.
    static func canonicalBGRA(base: UnsafeMutableRawPointer,
                              width sourceWidth: Int,
                              height sourceHeight: Int,
                              bytesPerRow: Int) -> [UInt8]? {
        var source = vImage_Buffer(
            data: base,
            height: vImagePixelCount(sourceHeight),
            width: vImagePixelCount(sourceWidth),
            rowBytes: bytesPerRow)

        // A landscape buffer is the portrait frame turned a quarter turn. The
        // capture connection normally does this for us; if it didn't, rotate
        // rather than scale a sideways image into a stretched one.
        var scratch: UnsafeMutableRawPointer?
        defer { if let scratch { free(scratch) } }
        if sourceWidth > sourceHeight {
            let rotatedWidth = sourceHeight
            let rotatedHeight = sourceWidth
            let rotatedRowBytes = rotatedWidth * 4
            guard let storage = malloc(rotatedRowBytes * rotatedHeight) else { return nil }
            scratch = storage
            var rotated = vImage_Buffer(
                data: storage,
                height: vImagePixelCount(rotatedHeight),
                width: vImagePixelCount(rotatedWidth),
                rowBytes: rotatedRowBytes)
            // BGRA and ARGB8888 share byte layout; channel order is irrelevant
            // to rotate and resample. The background colour is unused (a quarter
            // turn covers the whole buffer) but the API requires a pointer.
            var background: [UInt8] = [0, 0, 0, 0]
            guard vImageRotate90_ARGB8888(&source, &rotated, UInt8(kRotate90DegreesClockwise),
                                          &background, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                return nil
            }
            source = rotated
        }

        let destinationRowBytes = width * 4
        let count = destinationRowBytes * height
        guard let storage = malloc(count) else { return nil }
        defer { free(storage) }
        var destination = vImage_Buffer(
            data: storage,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: destinationRowBytes)
        guard vImageScale_ARGB8888(&source, &destination, nil,
                                   vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else {
            return nil
        }
        return Array(UnsafeBufferPointer(
            start: storage.assumingMemoryBound(to: UInt8.self), count: count))
    }
}
