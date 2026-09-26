import CoreGraphics
import Foundation

/// Handles aspect-fit letterbox/pillarbox calculation and coordinate mapping

/// between iPhone screen touches and Android/Waydroid native pixel space.
public struct CoordinateMapper {
    public let viewSize: CGSize
    public let videoSize: CGSize
    public let androidResolution: CGSize

    public let fittedRect: CGRect
    public let scale: CGFloat

    public init(viewSize: CGSize, videoSize: CGSize, androidResolution: CGSize) {
        self.viewSize = viewSize
        self.videoSize = videoSize
        self.androidResolution = (androidResolution.width > 0 && androidResolution.height > 0)
            ? androidResolution
            : videoSize

        guard viewSize.width > 0, viewSize.height > 0, videoSize.width > 0, videoSize.height > 0 else {
            self.fittedRect = .zero
            self.scale = 1.0
            return
        }

        let viewAspect = viewSize.width / viewSize.height
        let videoAspect = videoSize.width / videoSize.height

        if viewAspect > videoAspect {
            // Pillarbox: Black bars on left and right
            let s = viewSize.height / videoSize.height
            let fittedWidth = videoSize.width * s
            let xOffset = (viewSize.width - fittedWidth) / 2.0
            self.scale = s
            self.fittedRect = CGRect(x: xOffset, y: 0, width: fittedWidth, height: viewSize.height)
        } else {
            // Letterbox: Black bars on top and bottom
            let s = viewSize.width / videoSize.width
            let fittedHeight = videoSize.height * s
            let yOffset = (viewSize.height - fittedHeight) / 2.0
            self.scale = s
            self.fittedRect = CGRect(x: 0, y: yOffset, width: viewSize.width, height: fittedHeight)
        }
    }

    /// Determines if a touch point in the view falls inside the active video display area.
    public func isInsideVideo(point: CGPoint) -> Bool {
        return fittedRect.contains(point)
    }

    /// Maps a point from iOS view coordinates (points) directly into Android display pixel coordinates.
    /// Returns (androidX, androidY, isInsideVideo).
    public func mapToAndroid(point: CGPoint) -> (x: UInt32, y: UInt32, inside: Bool) {
        guard fittedRect.width > 0, fittedRect.height > 0 else {
            return (0, 0, false)
        }

        let inside = isInsideVideo(point: point)

        // Clamped normalized coordinates in 0.0 ... 1.0 range
        let relX = (point.x - fittedRect.origin.x) / fittedRect.width
        let relY = (point.y - fittedRect.origin.y) / fittedRect.height

        let clampedRelX = max(0.0, min(1.0, relX))
        let clampedRelY = max(0.0, min(1.0, relY))

        let targetWidth = androidResolution.width > 0 ? androidResolution.width : videoSize.width
        let targetHeight = androidResolution.height > 0 ? androidResolution.height : videoSize.height

        let x = UInt32(clampedRelX * (targetWidth - 1))
        let y = UInt32(clampedRelY * (targetHeight - 1))

        return (x, y, inside)
    }
}
