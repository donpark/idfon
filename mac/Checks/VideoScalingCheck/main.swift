// Runnable check for the camera frame normaliser (not part of any app target).
// Accelerate/Foundation only, so it runs on the host with plain swiftc, and the
// same file is compiled against BOTH platform copies (they share an API but
// differ in canonical size and rotation handling):
//
//   swiftc -o /tmp/mac-scalecheck mac/Sources/Idfon/VideoScaling.swift \
//     mac/Checks/VideoScalingCheck/main.swift && /tmp/mac-scalecheck
//   swiftc -o /tmp/ios-scalecheck ios/Idfon/VideoScaling.swift \
//     mac/Checks/VideoScalingCheck/main.swift && /tmp/ios-scalecheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Accelerate
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

/// BGRA buffer of `width`×`height` filled with one colour, `extraStride` bytes
/// of padding per row (to exercise the padded case).
func makeBGRA(width: Int, height: Int, extraStride: Int, b: UInt8, g: UInt8, a: UInt8) -> [UInt8] {
    let rowBytes = width * 4 + extraStride
    var buffer = [UInt8](repeating: 0, count: rowBytes * height)
    for row in 0..<height {
        for column in 0..<width {
            let offset = row * rowBytes + column * 4
            buffer[offset] = b
            buffer[offset + 1] = g
            buffer[offset + 2] = 200 // r
            buffer[offset + 3] = a
        }
    }
    return buffer
}

/// Normalises an input of the given size and returns the packed result.
func normalise(width: Int, height: Int, extraStride: Int, b: UInt8, g: UInt8) -> [UInt8]? {
    var buffer = makeBGRA(width: width, height: height, extraStride: extraStride, b: b, g: g, a: 255)
    return buffer.withUnsafeMutableBytes { raw in
        VideoScaling.canonicalBGRA(base: raw.baseAddress!, width: width, height: height,
                                   bytesPerRow: width * 4 + extraStride)
    }
}

/// Colour survives rotate/scale (allow ±2 for filter ringing at the edge).
func coloursPreserved(_ out: [UInt8], b: UInt8, g: UInt8, label: String) {
    check(abs(Int(out[0]) - Int(b)) <= 2 && abs(Int(out[1]) - Int(g)) <= 2
            && abs(Int(out[2]) - 200) <= 2 && out[3] == 255,
          "\(label) colour preserved: b=\(out[0]) g=\(out[1]) r=\(out[2]) a=\(out[3])")
}

let canonicalCount = VideoScaling.width * VideoScaling.height * 4

// Canonical size must be one of the two the dylib declares per OS, and the two
// shells must agree with their own platform's default.
check((VideoScaling.width == 1280 && VideoScaling.height == 720)
        || (VideoScaling.width == 720 && VideoScaling.height == 1280),
      "canonical size is a platform default: \(VideoScaling.width)x\(VideoScaling.height)")

// 1080p source — the case where macOS ignores the preset.
guard let hd = normalise(width: 1920, height: 1080, extraStride: 0, b: 30, g: 20) else {
    check(false, "1920x1080 normalised"); exit(1)
}
check(hd.count == canonicalCount, "1080p -> packed canonical: \(hd.count)")
coloursPreserved(hd, b: 30, g: 20, label: "1080p")

// Padded stride, smaller than canonical.
guard let padded = normalise(width: 640, height: 360, extraStride: 64, b: 200, g: 100) else {
    check(false, "padded 640x360 normalised"); exit(1)
}
check(padded.count == canonicalCount, "padded -> packed canonical: \(padded.count)")
coloursPreserved(padded, b: 200, g: 100, label: "padded")

// The platform's native size: a no-op resample on macOS, and on iOS the
// landscape buffer that should have been rotated before it got here.
guard let native = normalise(width: VideoScaling.height, height: VideoScaling.width, extraStride: 0, b: 7, g: 8) else {
    check(false, "native-orientation normalised"); exit(1)
}
check(native.count == canonicalCount, "native-orientation -> canonical: \(native.count)")
coloursPreserved(native, b: 7, g: 8, label: "native orientation")

// Already-canonical input, padded: must come back packed and unchanged in size.
guard let exact = normalise(width: VideoScaling.width, height: VideoScaling.height,
                            extraStride: 32, b: 9, g: 10) else {
    check(false, "canonical input normalised"); exit(1)
}
check(exact.count == canonicalCount, "canonical input keeps its size")
coloursPreserved(exact, b: 9, g: 10, label: "canonical")

print("ALL OK (\(VideoScaling.width)x\(VideoScaling.height))")
