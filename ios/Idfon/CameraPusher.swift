import AVFoundation
import CoreMedia
import CoreVideo
import UIKit

/// Feeds the Rust media layer with camera frames, replacing the vendored
/// nokhwa capture on iOS:
/// AVCaptureSession (front camera, portrait BGRA) -> media_video_push_frame
/// FFI -> PushFrameSource (VideoSource) -> H.264 encoder ladder.
///
/// Rotation is handled natively by locking the capture connection to
/// portrait orientation, so frames arrive upright regardless of device
/// orientation; no rotation FFI involved.
final class CameraPusher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = CameraPusher()

    private var session = AVCaptureSession()
    /// Controls session lifecycle; the delegate queue is separate so
    /// start/stop never serialize behind captureOutput callbacks.
    private let queue = DispatchQueue(label: "idfon.camera.control")
    private let captureQueue = DispatchQueue(label: "idfon.camera.frames")
    private var configured = false
    private var framesPushed = 0
    /// Set when start() was requested while the app was not active; capture
    /// arbitration denies frames to non-active clients, so we defer.
    private var pendingStart = false
    /// Set when the session reports a runtime error / interruption.
    private var lastSessionError = ""

    override init() {
        super.init()
        // object: nil so rebuilt (fresh) sessions are observed too; this is
        // the only AVCaptureSession in the process.
        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: nil, queue: nil
        ) { [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.lastSessionError = "runtime: \(err?.description ?? "?")"
            NSLog("idfon camera push: RUNTIME ERROR \(err?.description ?? "?")")
        }
        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: nil, queue: nil
        ) { [weak self] note in
            let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
            self?.lastSessionError = "interrupted reason=\(reason)"
            NSLog("idfon camera push: INTERRUPTED reason=\(reason)")
        }
        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil
        ) { _ in NSLog("idfon camera push: interruption ended") }
    }

    func start() {
        let state = UIApplication.shared.applicationState
        NSLog("idfon camera push: start requested appState=\(state.rawValue) (0=active)")
        guard state == .active else {
            // Session started while inactive is born ineligible for frame
            // delivery (cameracaptured arbitration) and never recovers —
            // wait until the app is actually active.
            pendingStart = true
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, self.pendingStart else { return }
                self.pendingStart = false
                self.queue.async { self.startLocked() }
            }
            NSLog("idfon camera push: app not active, deferring start until didBecomeActive")
            return
        }
        queue.async { self.startLocked() }
    }
    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func startLocked() {
        if !configured { configure() }
        guard configured, !session.isRunning else { return }
        session.startRunning()
        NSLog("idfon camera push: session running (isRunning=\(session.isRunning)) appState=\(UIApplication.shared.applicationState.rawValue) scenes=\(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.activationState.rawValue })")
        // No frames within 2s => isolation ladder: attempt 2 = BACK camera
        // vanilla, attempt 3 = nokhwa's exact recipe (InputPriority preset +
        // back camera), the one configuration that delivered frames in this
        // same app before the migration.
        captureQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.framesPushed == 0 else { return }
            guard self.session.isRunning else { return }
            NSLog("idfon camera push: NO FRAMES attempt 1 (front/hd720/BGRA) -> attempt 2: back camera vanilla")
            self.rebuild(cameraPosition: .back, preset: nil)
            self.captureQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.framesPushed == 0, self.session.isRunning else { return }
                NSLog("idfon camera push: NO FRAMES attempt 2 -> attempt 3: nokhwa recipe (InputPriority + back)")
                self.rebuild(cameraPosition: .back, preset: "AVCaptureSessionPresetInputPriority")
            }
        }
    }

    /// Tear down and rebuild with a different camera/config. Uses a FRESH
    /// AVCaptureSession: a session denied by capture arbitration (started
    /// while inactive) stays denied, so reconfiguring the same object
    /// proves nothing.
    private func rebuild(cameraPosition: AVCaptureDevice.Position, preset: String?) {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            let fresh = AVCaptureSession()
            if let preset { fresh.sessionPreset = .init(rawValue: preset) }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                NSLog("idfon camera push: rebuild device unavailable pos=\(cameraPosition.rawValue)")
                return
            }
            fresh.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "idfon.camera.frames.\(cameraPosition.rawValue)"))
            fresh.addOutput(output)
            output.connection(with: .video)?.videoOrientation = .portrait
            self.session = fresh
            fresh.startRunning()
            NSLog("idfon camera push: rebuilt running pos=\(cameraPosition.rawValue) preset=\(preset ?? "none") appState=\(UIApplication.shared.applicationState.rawValue)")
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            NSLog("idfon camera push: no front camera / input unavailable (auth=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue))")
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            NSLog("idfon camera push: canAddOutput=false")
            return
        }
        session.addOutput(output)
        // Sensor is landscape-native; have AVFoundation deliver upright
        // portrait frames so no rotation is needed anywhere downstream.
        output.connection(with: .video)?.videoOrientation = .portrait
        configured = true
        NSLog("idfon camera push: configured ok, device=\(device.localizedName) auth=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        NSLog("idfon camera push: frame dropped")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        framesPushed += 1
        if framesPushed == 1 || framesPushed % 150 == 0 {
            NSLog("idfon camera push: frame #\(framesPushed) conn.active=\(connection.isActive) enabled=\(connection.isEnabled)")
        }
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
            media_video_push_frame(base.assumingMemoryBound(to: UInt8.self), UInt(expected * height), UInt32(width), UInt32(height), ptsMs)
        } else {
            // Padded stride: copy rows into a tightly packed buffer first.
            var packed = [UInt8](repeating: 0, count: expected * height)
            let src = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                packed.withUnsafeMutableBytes { dst in
                    _ = memcpy(dst.baseAddress! + row * expected, src + row * bytesPerRow, expected)
                }
            }
            packed.withUnsafeBytes { raw in
                media_video_push_frame(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt(packed.count), UInt32(width), UInt32(height), ptsMs)
            }
        }
    }
}
