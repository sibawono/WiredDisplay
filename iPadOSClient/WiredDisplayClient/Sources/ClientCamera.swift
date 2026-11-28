import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import UIKit
import VideoToolbox
import WDVideo

/// Captures the iPad's front camera (with Center Stage on supported iPads),
/// encodes 1080p 30 fps H.264 in hardware via VideoToolbox, and emits Annex-B
/// frames for `ClientSession` to send over `StreamType.camera`.
final class ClientCamera: NSObject, @unchecked Sendable {
    var onFrame: ((_ annexB: [UInt8], _ isKeyframe: Bool, _ timestampNanos: UInt64) -> Void)?
    var onStateChange: ((_ enabled: Bool, _ centerStage: Bool, _ centerStageSupported: Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "wireddisplay.client.camera", qos: .userInteractive)
    private var captureSession: AVCaptureSession?
    private var videoDevice: AVCaptureDevice?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var encoder: VTCompressionSession?
    private var encoderWidth: Int32 = 0
    private var encoderHeight: Int32 = 0

    private var enabled = false
    private var centerStage = true
    private var centerStageSupported = false
    private var forceNextKeyframe = false
    private var lastRotationAngle: CGFloat?
    private var mirrorConfigured = false
    private var observers: [NSObjectProtocol] = []

    static func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    func apply(enabled: Bool, centerStage: Bool) {
        queue.async { [self] in
            let wasEnabled = self.enabled
            self.centerStage = centerStage
            if enabled && !wasEnabled {
                startOnQueue()
            } else if !enabled && wasEnabled {
                stopOnQueue()
            } else if enabled && wasEnabled {
                applyCenterStageOnQueue()
                notifyState()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if enabled { stopOnQueue() }
        }
    }

    func requestKeyframe() {
        queue.async { [self] in
            forceNextKeyframe = true
        }
    }

    // MARK: - Capture lifecycle (on `queue`)

    private func startOnQueue() {
        guard let device = bestFrontCamera() else {
            ClientLog.write("camera: no front camera available")
            emitError("Front camera not available on this iPad.")
            enabled = false
            notifyState()
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                emitError("Could not attach front camera input.")
                enabled = false
                notifyState()
                return
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            ClientLog.write("camera: input failed: \(error)")
            emitError("Could not open front camera: \(error.localizedDescription)")
            enabled = false
            notifyState()
            return
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            emitError("Could not attach camera video output.")
            enabled = false
            notifyState()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        videoDevice = device
        videoOutput = output
        captureSession = session
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        updateConnectionRotation()

        // Configure 30 fps + Center Stage.
        do {
            try device.lockForConfiguration()
            let fps30 = CMTime(value: 1, timescale: 30)
            let supports30 = device.activeFormat.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
            }
            if supports30 {
                device.activeVideoMinFrameDuration = fps30
                device.activeVideoMaxFrameDuration = fps30
            }
            centerStageSupported = device.activeFormat.isCenterStageSupported
            device.unlockForConfiguration()
        } catch {
            ClientLog.write("camera: lockForConfiguration failed: \(error)")
            centerStageSupported = device.activeFormat.isCenterStageSupported
        }
        applyCenterStageOnQueue()

        installObservers(for: session)
        forceNextKeyframe = true
        session.startRunning()
        enabled = session.isRunning
        ClientLog.write("camera: started (device=\(device.localizedName), centerStageSupported=\(centerStageSupported), centerStage=\(centerStage))")
        notifyState()
    }

    private func stopOnQueue() {
        removeObservers()
        if let session = captureSession {
            session.stopRunning()
        }
        captureSession = nil
        videoOutput = nil
        videoDevice = nil
        rotationCoordinator = nil
        lastRotationAngle = nil
        mirrorConfigured = false
        teardownEncoder()
        enabled = false
        ClientLog.write("camera: stopped")
        notifyState()
    }

    private func bestFrontCamera() -> AVCaptureDevice? {
        if let ultraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .front) {
            return ultraWide
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }

    private func applyCenterStageOnQueue() {
        guard centerStageSupported else { return }
        AVCaptureDevice.centerStageControlMode = .cooperative
        AVCaptureDevice.isCenterStageEnabled = centerStage
    }

    private func updateConnectionRotation() {
        guard let output = videoOutput, let connection = output.connection(with: .video) else { return }
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 0
        if lastRotationAngle != angle, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
            lastRotationAngle = angle
        }
        if !mirrorConfigured, connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
            mirrorConfigured = true
        }
    }

    private func installObservers(for session: AVCaptureSession) {
        removeObservers()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            ClientLog.write("camera: interrupted (reason=\(raw ?? -1))")
            self?.emitError("Camera paused while another app is active or WiredDisplay is in the background.")
        })
        observers.append(nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] _ in
            ClientLog.write("camera: interruption ended")
            self?.requestKeyframe()
        })
    }

    private func removeObservers() {
        let nc = NotificationCenter.default
        for token in observers { nc.removeObserver(token) }
        observers.removeAll()
    }

    // MARK: - VideoToolbox H.264 encoder (on `queue`)

    private func ensureEncoder(width: Int32, height: Int32) -> VTCompressionSession? {
        if let encoder, encoderWidth == width, encoderHeight == height {
            return encoder
        }
        teardownEncoder()

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            ClientLog.write("camera: VTCompressionSessionCreate failed (\(status))")
            return nil
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 6_000_000 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)

        encoder = session
        encoderWidth = width
        encoderHeight = height
        forceNextKeyframe = true
        ClientLog.write("camera: encoder ready (\(width)x\(height) H.264 6 Mbit/s)")
        return session
    }

    private func teardownEncoder() {
        if let encoder {
            VTCompressionSessionInvalidate(encoder)
        }
        encoder = nil
        encoderWidth = 0
        encoderHeight = 0
    }

    private func notifyState() {
        let on = enabled
        let cs = centerStage
        let supported = centerStageSupported
        let cb = onStateChange
        DispatchQueue.main.async { cb?(on, cs, supported) }
    }

    private func emitError(_ message: String) {
        let cb = onError
        DispatchQueue.main.async { cb?(message) }
    }
}

extension ClientCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard enabled, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Keep orientation tracking current if the iPad was rotated.
        updateConnectionRotation()

        let width = Int32(CVPixelBufferGetWidth(imageBuffer))
        let height = Int32(CVPixelBufferGetHeight(imageBuffer))
        guard width > 0, height > 0, let session = ensureEncoder(width: width, height: height) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMTime(value: 1, timescale: 30)
        var frameProps: CFDictionary?
        if forceNextKeyframe {
            forceNextKeyframe = false
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        let timestampNanos = DispatchTime.now().uptimeNanoseconds
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProps,
            infoFlagsOut: nil
        ) { [weak self] encodeStatus, _, encodedSample in
            guard let self, encodeStatus == noErr, let encodedSample else { return }
            do {
                let encoded = try SampleBuffers.annexBPayload(from: encodedSample, codec: .h264)
                guard !encoded.annexB.isEmpty else { return }
                self.onFrame?(encoded.annexB, encoded.isKeyframe, timestampNanos)
            } catch {
                ClientLog.write("camera: annexB conversion failed: \(error)")
            }
        }
        if status != noErr {
            ClientLog.write("camera: encode failed (\(status))")
        }
    }
}
