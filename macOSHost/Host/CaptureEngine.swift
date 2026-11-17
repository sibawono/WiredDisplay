import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures one display with ScreenCaptureKit and hands complete frames to
/// `onFrame` on a private serial queue. Requires the Screen Recording
/// permission for this app.
///
/// Concurrency: `stream`/`output` are touched only by start/stop, which the
/// session calls from its run-loop thread; frames arrive on `sampleQueue`.
final class CaptureEngine: @unchecked Sendable {
    enum Error: Swift.Error, CustomStringConvertible {
        case displayNotShareable(CGDirectDisplayID)
        case screenCapture(String)

        var description: String {
            switch self {
            case .displayNotShareable(let id):
                return "display \(id) not offered by ScreenCaptureKit (Screen Recording permission missing?)"
            case .screenCapture(let reason): return "ScreenCaptureKit: \(reason)"
            }
        }
    }

    private let sampleQueue = DispatchQueue(label: "wireddisplay.host.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var output: Output?

    func start(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, fps: Int, displayP3: Bool, bgra: Bool = false,
               onFrame: @escaping @Sendable (CVPixelBuffer, CMTime, Double) -> Void,
               onStop: @escaping @Sendable (String) -> Void) throws {
        let display = try findDisplay(displayID, timeout: 3)

        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        // Half the frame period: at exactly 1/fps, frames arriving a hair early
        // (16.66 vs 16.67 ms) were discarded, leaving 50 ms gaps (measured).
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1) * 2))
        configuration.pixelFormat = bgra ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // Display P3 primaries + BT.709 YCbCr matrix, matching the encoder tags
        // (step 4; was sRGB, which clipped wide-gamut colour).
        configuration.colorSpaceName = displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.queueDepth = 4
        configuration.showsCursor = true
        // The display's framebuffer can be larger than the panel ("more space"
        // modes): scale it to the panel size (same aspect ratio).
        configuration.scalesToFit = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let output = Output(onFrame: onFrame, onStop: onStop)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            throw Error.screenCapture("addStreamOutput: \(error.localizedDescription)")
        }
        do {
            try wait { done in stream.startCapture { done($0) } }
        } catch {
            // It may still start after a timeout: make sure it does not linger.
            try? wait { done in stream.stopCapture { done($0) } }
            throw error
        }
        self.stream = stream
        self.output = output
        Log.info("capture started on display \(displayID) at \(pixelWidth)x\(pixelHeight), \(fps) fps max")
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        output = nil
        try? wait { done in stream.stopCapture { done($0) } }
        Log.info("capture stopped")
    }

    private func findDisplay(_ id: CGDirectDisplayID, timeout: TimeInterval) throws -> SCDisplay {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            final class Box: @unchecked Sendable { var displays: [SCDisplay] = []; var error: Swift.Error? }
            let box = Box()
            let done = DispatchSemaphore(value: 0)
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                box.displays = content?.displays ?? []
                box.error = error
                done.signal()
            }
            done.wait()
            if let display = box.displays.first(where: { $0.displayID == id }) { return display }
            if Date() >= deadline {
                if let error = box.error { throw Error.screenCapture(error.localizedDescription) }
                throw Error.displayNotShareable(id)
            }
            // A just-created display takes a moment to appear in shareable content.
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func wait(_ start: (@escaping @Sendable (Swift.Error?) -> Void) -> Void) throws {
        final class Box: @unchecked Sendable { var error: Swift.Error? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        start { error in
            box.error = error
            done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success else { throw Error.screenCapture("timed out") }
        if let error = box.error { throw Error.screenCapture(error.localizedDescription) }
    }

    private final class Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        let onFrame: @Sendable (CVPixelBuffer, CMTime, Double) -> Void
        let onStop: @Sendable (String) -> Void

        init(onFrame: @escaping @Sendable (CVPixelBuffer, CMTime, Double) -> Void, onStop: @escaping @Sendable (String) -> Void) {
            self.onFrame = onFrame
            self.onStop = onStop
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
            // Only complete frames carry new pixels; idle/blank/suspended do not.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
               let rawStatus = attachments.first?[.status] as? Int,
               SCFrameStatus(rawValue: rawStatus) != .complete {
                return
            }
            // Share of the frame that changed (dirty rects are in pixels of the
            // output buffer); 1 when unknown, which counts as motion.
            var dirty = 1.0
            if let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                            as? [[SCStreamFrameInfo: Any]])?.first,
               let rects = info[.dirtyRects] as? [NSDictionary] {
                let total = Double(CVPixelBufferGetWidth(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer))
                let changed = rects.compactMap { CGRect(dictionaryRepresentation: $0) }
                    .reduce(0.0) { $0 + Double($1.width * $1.height) }
                dirty = total > 0 ? min(changed / total, 1) : 1
            }
            onFrame(pixelBuffer, sampleBuffer.presentationTimeStamp, dirty)
        }

        func stream(_ stream: SCStream, didStopWithError error: Swift.Error) {
            onStop(error.localizedDescription)
        }
    }
}
