import CoreGraphics

/// Maps a touch in the iPad view to a point on the Mac display and back.
///
/// The video is aspect-fit inside the view (letterbox/pillarbox). All sizes are
/// in points of their own coordinate space; both spaces have a top-left origin
/// (UIKit view, and CoreGraphics global display coordinates used by CGEvent).
public struct CoordinateMapper: Equatable, Sendable {
    public let viewSize: CGSize
    /// Mac display rectangle in global coordinates (CGDisplayBounds). The
    /// origin is non-zero for any display that is not the main display.
    public let displayBounds: CGRect
    /// Region of the view actually covered by video.
    public let contentRect: CGRect

    public init?(viewSize: CGSize, displayBounds: CGRect) {
        guard viewSize.width > 0, viewSize.height > 0,
              displayBounds.width > 0, displayBounds.height > 0,
              viewSize.width.isFinite, viewSize.height.isFinite,
              displayBounds.width.isFinite, displayBounds.height.isFinite,
              displayBounds.origin.x.isFinite, displayBounds.origin.y.isFinite else { return nil }
        self.viewSize = viewSize
        self.displayBounds = displayBounds
        let scale = min(viewSize.width / displayBounds.width, viewSize.height / displayBounds.height)
        let size = CGSize(width: displayBounds.width * scale, height: displayBounds.height * scale)
        let content = CGRect(x: (viewSize.width - size.width) / 2,
                             y: (viewSize.height - size.height) / 2,
                             width: size.width, height: size.height)
        // Reject geometry whose arithmetic degenerates (denormal sizes, origins
        // so large that origin + size is not representable): mapping through it
        // would yield NaN or infinite click positions.
        guard content.width > 0, content.height > 0, content.width.isFinite, content.height.isFinite,
              content.minX.isFinite, content.minY.isFinite,
              displayBounds.maxX.isFinite, displayBounds.maxY.isFinite,
              displayBounds.maxX.nextDown >= displayBounds.minX,
              displayBounds.maxY.nextDown >= displayBounds.minY else { return nil }
        self.contentRect = content
    }

    /// Returns nil for touches in the letterbox bars or with non-finite input,
    /// so a touch outside the picture can never become a click somewhere else.
    public func displayPoint(forViewPoint point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        guard point.x >= contentRect.minX, point.x <= contentRect.maxX,
              point.y >= contentRect.minY, point.y <= contentRect.maxY else { return nil }
        let normalizedX = (point.x - contentRect.minX) / contentRect.width
        let normalizedY = (point.y - contentRect.minY) / contentRect.height
        // maxX/maxY belong to the neighbouring display; clamp just inside so the
        // far edge maps to the last row/column without distorting nearby points.
        let x = min(displayBounds.minX + normalizedX * displayBounds.width, displayBounds.maxX.nextDown)
        let y = min(displayBounds.minY + normalizedY * displayBounds.height, displayBounds.maxY.nextDown)
        let result = CGPoint(x: max(x, displayBounds.minX), y: max(y, displayBounds.minY))
        guard result.x.isFinite, result.y.isFinite, displayBounds.contains(result) else { return nil }
        return result
    }

    public func viewPoint(forDisplayPoint point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, displayBounds.contains(point) else { return nil }
        let normalizedX = (point.x - displayBounds.minX) / displayBounds.width
        let normalizedY = (point.y - displayBounds.minY) / displayBounds.height
        let result = CGPoint(x: contentRect.minX + normalizedX * contentRect.width,
                             y: contentRect.minY + normalizedY * contentRect.height)
        guard result.x.isFinite, result.y.isFinite else { return nil }
        return result
    }
}
