// Runnable check for the camera frame normaliser (not part of the app target).
// Foundation/Accelerate only, so it runs on the host with plain swiftc:
//
//   swiftc -o /tmp/mac-scalecheck mac/Sources/Idfon/VideoScaling.swift \
//     mac/Checks/VideoScalingCheck/main.swift
//   /tmp/mac-scalecheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Accelerate
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

/// BGRA buffer of `width`×`height` filled with one colour, `extraStride` bytes
/// of padding per row (to exercise the padded case).
func makeBGRA(width: Int, height: Int, extraStride: Int, b: UInt8, g: UInt8, r: UInt8, a: UInt8) -> [UInt8] {
    let rowBytes = width * 4 + extraStride
    var buffer = [UInt8](repeating: 0, count: rowBytes * height)
    for row in 0..<height {
        for column in 0..<width {
            let offset = row * rowBytes + column * 4
            buffer[offset] = b
            buffer[offset + 1] = g
            buffer[offset + 2] = r
            buffer[offset + 3] = a
        }
    }
    return buffer
}

check(VideoScaling.width == 1280 && VideoScaling.height == 720,
      "canonical size mirrors the dylib's macOS default: \(VideoScaling.width)x\(VideoScaling.height)")

// A 1080p camera that ignored the preset gets normalised to the canonical size,
// so pushed frames match the encoder's fixed dimensions.
var hd1080 = makeBGRA(width: 1920, height: 1080, extraStride: 0, b: 30, g: 20, r: 10, a: 255)
let scaled = hd1080.withUnsafeMutableBytes { raw -> [UInt8]? in
    VideoScaling.canonicalBGRA(base: raw.baseAddress!, width: 1920, height: 1080, bytesPerRow: 1920 * 4)
}
guard let scaled else { check(false, "1920x1080 scaled"); exit(1) }
check(scaled.count == VideoScaling.width * VideoScaling.height * 4,
      "output is tightly packed 1280x720: \(scaled.count)")
// Colour survives the resample (allow ±2 for filter ringing at the edge).
check(abs(Int(scaled[0]) - 30) <= 2 && abs(Int(scaled[1]) - 20) <= 2 && abs(Int(scaled[2]) - 10) <= 2
        && scaled[3] == 255,
      "colour preserved: b=\(scaled[0]) g=\(scaled[1]) r=\(scaled[2]) a=\(scaled[3])")

// Padded stride into a non-canonical size: still produces a packed canonical frame.
var padded = makeBGRA(width: 640, height: 360, extraStride: 64, b: 200, g: 100, r: 50, a: 255)
let paddedScaled = padded.withUnsafeMutableBytes { raw -> [UInt8]? in
    VideoScaling.canonicalBGRA(base: raw.baseAddress!, width: 640, height: 360, bytesPerRow: 640 * 4 + 64)
}
guard let paddedScaled else { check(false, "padded 640x360 scaled"); exit(1) }
check(paddedScaled.count == VideoScaling.width * VideoScaling.height * 4,
      "padded input still yields a packed canonical frame: \(paddedScaled.count)")
check(abs(Int(paddedScaled[2]) - 50) <= 2 && abs(Int(paddedScaled[1]) - 100) <= 2,
      "padded colour preserved: r=\(paddedScaled[2]) g=\(paddedScaled[1])")

// Already-canonical input is a no-op resample: same size, colours intact.
var native = makeBGRA(width: 1280, height: 720, extraStride: 0, b: 7, g: 8, r: 9, a: 255)
let nativeScaled = native.withUnsafeMutableBytes { raw -> [UInt8]? in
    VideoScaling.canonicalBGRA(base: raw.baseAddress!, width: 1280, height: 720, bytesPerRow: 1280 * 4)
}
guard let nativeScaled else { check(false, "canonical input scaled"); exit(1) }
check(nativeScaled.count == native.count, "canonical input keeps its size")
check(nativeScaled[0] == 7 && nativeScaled[1] == 8 && nativeScaled[2] == 9 && nativeScaled[3] == 255,
      "canonical input colours unchanged")

print("ALL OK")
