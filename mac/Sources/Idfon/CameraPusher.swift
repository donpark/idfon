import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import CIdfon

/// Feeds the Rust media layer with camera frames on macOS, same pattern as
/// the iOS CameraPusher (mac port; nokhwa capture removed from the dylib):
/// AVCaptureSession (front camera, 1280x720 BGRA) -> media_video_push_frame
/// FFI -> PushFrameSource (VideoSource) -> H.264 encoder ladder.
///
/// No orientation lock: macOS delivers sensor-native landscape frames,
/// matching the dylib's declared 1280x720 source format. No active-state
/// deferral: start() is only called from user interaction (dial/answer).
final class CameraPusher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = CameraPusher()

    private var session = AVCaptureSession()
    /// Controls session lifecycle; the delegate queue is separate so
    /// start/stop never serialize behind captureOutput callbacks.
    private let queue = DispatchQueue(label: "idfon.camera.control")
    private let captureQueue = DispatchQueue(label: "idfon.camera.frames")
    private var configured = false

    func start() {
        queue.async { self.startLocked() }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func startLocked() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            // TCC prompt; the dylib's own request (ensure_camera_access)
            // coalesces into the same dialog.
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                NSLog("idfon camera push: access granted=\(granted)")
                if granted { self?.queue.async { self?.beginSession() } }
            }
            return
        }
        guard status == .authorized else {
            NSLog("idfon camera push: camera access denied (status=\(status.rawValue))")
            return
        }
        beginSession()
    }

    private func beginSession() {
        if !configured { configure() }
        guard configured, !session.isRunning else { return }
        session.startRunning()
        NSLog("idfon camera push: session running")
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Must match the dylib's declared PushFrameSource dimensions
        // (1280x720): the H.264 encoder is initialized from them and never
        // re-reads per frame.
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            NSLog("idfon camera push: no camera / input unavailable (auth=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue))")
            return
        }
        session.addInput(input)
        // Session presets are advisory on macOS (a 1080p camera ignores
        // .hd1280x720) — pin the device format to the dimensions the dylib
        // expects when the camera offers them.
        try? device.lockForConfiguration()
        let want = CMVideoDimensions(width: 1280, height: 720)
        if let fmt = device.formats.first(where: {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return d.width == want.width && d.height == want.height
        }) {
            device.activeFormat = fmt
        }
        device.unlockForConfiguration()
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            NSLog("idfon camera push: canAddOutput=false")
            return
        }
        session.addOutput(output)
        configured = true
        NSLog("idfon camera push: configured ok, device=\(device.localizedName)")
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let expected = width * 4
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }

        let ptsMs = UInt64(max(0, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000))
        if bytesPerRow == expected {
            media_video_push_frame(base.assumingMemoryBound(to: UInt8.self), expected * height, UInt32(width), UInt32(height), ptsMs)
        } else {
            // Padded stride: copy rows into a tightly packed buffer first.
            var packed = [UInt8](repeating: 0, count: expected * height)
            let src = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                _ = packed.withUnsafeMutableBytes { dst in
                    memcpy(dst.baseAddress! + row * expected, src + row * bytesPerRow, expected)
                }
            }
            packed.withUnsafeBytes { raw in
                media_video_push_frame(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), packed.count, UInt32(width), UInt32(height), ptsMs)
            }
        }
    }
}
