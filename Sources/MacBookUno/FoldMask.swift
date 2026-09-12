import AppKit

/// Which edge the frosted region sweeps in from.
enum SweepDirection: String, CaseIterable {
    /// From the hinge (the bottom edge of the screen) upward.
    case fromHinge
    /// From the top edge (farthest from the hinge, the edge that travels most) downward.
    case fromTop

    var localizedName: String {
        switch self {
        case .fromHinge: return "From the hinge"
        case .fromTop:   return "From the top"
        }
    }
}

/// Builds the mask image that defines the frosted region.
///
/// In the iPhone Duo fold animation the blur is not spread evenly across the
/// whole screen: the moving flap behaves like frosted glass, the boundary of
/// that region slides with the hinge angle, and the content behind stays fixed
/// in space. The same idea is adapted here to a single-panel display - the
/// mask's alpha channel decides where the blur applies, and the boundary sweeps
/// with a soft transition.
///
/// `NSVisualEffectView.maskImage` is documented API; no private API is used.
enum FoldMask {

    /// The mask is a vertical gradient, so a few pixels of width are enough -
    /// horizontal stretching works fine.
    ///
    /// Vertically the image is generated at the view's exact size instead.
    /// Measured reason: a fixed-height mask (8x512) is NOT stretched to the view,
    /// so the gradient was squeezed into a strip at the top of the screen - at
    /// 50% progress the boundary landed at 0.86 instead of 0.50, and the soft
    /// transition came out 0.02 wide instead of 0.18. Generating it 1:1 removes
    /// scaling from the picture entirely.
    private static let width = 8

    /// How far the blur ramp is spread, as a fraction of screen height.
    ///
    /// This is the whole character of the effect. A small value (0.2) gives a
    /// frosted *region* with a soft edge sweeping across a sharp screen. A value
    /// near 1.0 spreads the ramp over the entire panel instead: heavily frosted
    /// at the far edge, fading continuously to sharp at the near edge, with the
    /// whole ramp sliding as the lid moves.
    ///
    /// The reference animation does the latter - the blur strength varies
    /// continuously across the panel rather than having a visible boundary - so
    /// the ramp covers the full height.
    static let softness: Double = 1.0

    /// `progress` 0 = no frosting, 1 = the whole screen frosted.
    /// `height` is the height to generate at - pass the view's pixel height so
    /// that no vertical scaling happens.
    static func image(progress: Double,
                      direction: SweepDirection,
                      height rawHeight: Int,
                      softness: Double = softness) -> NSImage {
        let p = min(max(progress, 0), 1)
        let height = max(2, rawHeight)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32
        ), let data = rep.bitmapData else {
            return NSImage(size: NSSize(width: width, height: height))
        }

        // Boundary position. At progress=0 it sits fully off-screen and at
        // progress=1 fully past the opposite edge, so both ends come out clean.
        let boundary = p * (1 + softness) - softness / 2

        for row in 0..<height {
            // Bitmap rows run top to bottom; d is the distance from the hinge (bottom edge).
            let fromTopNorm = Double(row) / Double(height - 1)
            let d = 1 - fromTopNorm

            let raw: Double
            switch direction {
            case .fromHinge:
                raw = (boundary - d) / softness + 0.5
            case .fromTop:
                raw = (d - (1 - boundary)) / softness + 0.5
            }

            // smoothstep: zero derivative at the boundary, so the transition reads softly.
            let t = min(max(raw, 0), 1)
            let alpha = t * t * (3 - 2 * t)
            let value = UInt8(min(max(alpha * 255, 0), 255))

            for column in 0..<width {
                let offset = row * width * 4 + column * 4
                // Only the alpha channel is read from a mask; keep RGB white.
                data[offset + 0] = 255
                data[offset + 1] = 255
                data[offset + 2] = 255
                data[offset + 3] = value
            }
        }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        // Stretch across the view; tiling would repeat the vertical gradient.
        image.resizingMode = .stretch
        image.capInsets = NSEdgeInsetsZero
        return image
    }

    /// The same mask as a `CGImage`, for use as a `CALayer` mask on plain views
    /// (`maskImage` only exists on `NSVisualEffectView`).
    static func cgImage(progress: Double,
                        direction: SweepDirection,
                        height: Int,
                        softness: Double = softness) -> CGImage? {
        let nsImage = image(progress: progress, direction: direction, height: height, softness: softness)
        guard let rep = nsImage.representations.first as? NSBitmapImageRep else { return nil }
        return rep.cgImage
    }

}
