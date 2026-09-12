import AppKit
import QuartzCore

/// The desktop held at its own angle while the panel turns around it.
///
/// This is the only style that captures the screen. An overlay cannot reshape
/// what is behind it, and the effect is fundamentally a reshaping: the content
/// has to stay put in perceived space while the lid rotates, which means drawing
/// it ourselves on a plane we control.
///
/// The feed is live, not a frozen frame. The effect begins while the lid is
/// still at a usable angle, and a still image there leaves you unable to see
/// what you are doing - clicks pass through, but the picture never changes.
///
/// No Metal. `CATransform3D` gives the perspective and `CALayer.filters` gives a
/// real, radius-controlled blur - both verified by measurement. (`backgroundFilters`,
/// which would have filtered the desktop directly, does nothing on a modern
/// compositor, which is why the permission-free styles can only mask.)
final class PlaneFoldStyle: FoldStyleRenderer {

    /// How far the plane leans away at full fold. A full 90 degrees would turn it
    /// edge-on and hide it; the reference keeps the content readable throughout.
    private static let maxLean: CGFloat = 55 * .pi / 180
    /// Perspective depth. Smaller denominators exaggerate the keystone.
    private static let perspectiveDistance: CGFloat = 1400
    /// Blur radius in points at full fold.
    private static let maxBlurRadius: CGFloat = 28
    /// How wide the plane's edges fade out at full fold, in points.
    private static let maxFeather: CGFloat = 120

    /// The captured desktop, sharp.
    private let plane = CALayer()
    /// Variable blur: the radius follows a mask image instead of being uniform.
    ///
    /// A CALayer `mask` cannot be used for this - measured, a layer with both a
    /// mask and `filters` silently drops the filter, whether the mask sits on the
    /// layer itself or on an ancestor. Core Image does the gradient instead.
    private let blur = CIFilter(name: "CIMaskedVariableBlur")
    /// Cached so the gradient is not rebuilt on every frame.
    private var maskImage: CIImage?
    private var maskReach: Double = .nan
    /// The void, cut to the shape of the plane.
    private let veil = CAShapeLayer()
    /// Holds the plane and carries the perspective.
    ///
    /// The veil and the stage are siblings, so the veil cannot be depth-sorted
    /// against the plane: the plane's z only exists inside the stage. That is
    /// what lets the void be a real layer rather than a flat fill painted on the
    /// container's background, which was the earlier workaround.
    private let stage = CALayer()
    private var host: NSView?

    private let feed = DisplayStream()
    /// Set once the first frame lands. Until then nothing is drawn at all.
    private var hasFrame = false
    /// Size of the incoming frames. Only used to tell whether a frame has a
    /// usable size yet - the filters work in the layer's space, not this one.
    private var capturedWidth: CGFloat = 0
    private var capturedHeight: CGFloat = 0

    var onUnavailable: ((String) -> Void)?
    /// The last state `apply` was called with.
    ///
    /// The capture is asynchronous and the frame loop idles as soon as the lid
    /// stops moving, so the image often arrives after the last `apply`. Without
    /// replaying that state the plane would stay hidden behind the backdrop.
    private var lastState: (progress: Double, direction: SweepDirection, bounds: NSRect, scale: CGFloat)?

    func install(in container: NSView) {
        container.wantsLayer = true
        host = container

        // Anchored to the bottom edge: that is where the hinge is, so the plane
        // pivots exactly where the real lid does.
        plane.anchorPoint = CGPoint(x: 0.5, y: 0)
        plane.contentsGravity = .resize
        // Not opaque: the blur fades the plane's edges out to transparent and
        // that has to composite against the void behind it.
        plane.isOpaque = false

        veil.fillRule = .evenOdd
        veil.fillColor = NSColor(white: 0.04, alpha: 1).cgColor
        container.layer?.addSublayer(veil)
        container.layer?.addSublayer(stage)
        stage.addSublayer(plane)
    }

    func uninstall() {
        feed.stop()
        hasFrame = false
        maskImage = nil
        veil.path = nil
        veil.removeFromSuperlayer()
        stage.sublayerTransform = CATransform3DIdentity
        stage.removeFromSuperlayer()
        plane.removeFromSuperlayer()
        plane.contents = nil
        host = nil
    }

    func apply(progress: Double, direction: SweepDirection, bounds: NSRect, scale: CGFloat) {
        lastState = (progress, direction, bounds, scale)

        // Run the feed only while the fold is on screen. Capturing continuously
        // would undo the idle work for an effect nobody is looking at.
        if progress > 0.001 {
            startFeedIfNeeded()
        } else if feed.isRunning {
            feed.stop()
            hasFrame = false
            plane.contents = nil
        }

        // Layer geometry changes must not animate: they are driven by the lid,
        // and Core Animation's default quarter-second easing would lag behind it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard hasFrame else {
            // Nothing to draw yet, so draw nothing. Painting the void first
            // would black out a working screen while the capture is in flight,
            // and if the capture fails it would never be replaced.
            veil.path = nil
            plane.isHidden = true
            return
        }

        // The void the panel folds into, painted on the container's own layer
        // rather than a sibling.
        //
        // A sibling backdrop sits at z = 0, and once the plane leans backwards
        // its own z goes negative, so Core Animation depth-sorts the plane
        // *behind* the backdrop and it vanishes. A parent's background always
        // draws behind its sublayers, whatever their depth.
        //
        // It is a vertical gradient, not a flat fill, and it descends with the
        // fold so the darkness arrives in step with the blur rather than
        // covering the screen the instant the effect starts.
        //
        // Opaque from the top down to the plane's leading edge, because that is
        // the only part actually *seen*: below the edge the plane covers it. It
        // has to be fully opaque there or the real desktop shows through and the
        // sharp screen plus the leaning blurred copy read as a double image.
        // Below the edge it fades out along the same ramp the blur uses, which
        // is what keeps the plane's own feathered border from reading as a dark
        // rim around a screen that is otherwise untouched.


        // Perspective, projected about the middle of the screen.
        //
        // A sublayerTransform is applied about its own layer's anchor point, and
        // AppKit pins that to (0, 0) for a view-backed layer - which projects
        // from the bottom-left corner and shears the plane into a parallelogram.
        // The stage is a plain layer whose anchor is the middle, so the raw
        // projection is already centred and no correction is needed.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / PlaneFoldStyle.perspectiveDistance
        veil.frame = bounds
        stage.frame = bounds
        stage.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        stage.sublayerTransform = perspective

        plane.isHidden = false

        let p = CGFloat(min(max(progress, 0), 1))
        // Full size. The fade needs a dark margin to happen in, and the keystone
        // already supplies one that grows with the fold: at half fold the
        // perspective pulls the far edge 185 points in from the screen on each
        // side against a 60 point feather, and the ratio holds all the way down.
        // Shrinking the plane on top of that only adds a flat bar.
        let width = bounds.width
        let height = bounds.height
        plane.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // Left unset a layer renders at 1x, which both throws away half of a
        // Retina capture and leaves the filter space ambiguous.
        plane.contentsScale = scale

        // The anchor is the plane's bottom edge, so this is literally where the
        // hinge is: the bottom of the screen.
        plane.position = CGPoint(x: bounds.midX, y: bounds.minY)


        // Leaning away about the hinge is what makes the content look like it
        // kept its angle while the panel moved. The perspective comes from the
        // parent, so this is a pure rotation.
        plane.transform = CATransform3DMakeRotation(-PlaneFoldStyle.maxLean * p, 1, 0, 0)


        // Both Core Image masks are built in the layer's own bounds - in points,
        // not pixels, and not the size of the captured surface.
        //
        // This was measured, and getting it wrong is not obvious from looking at
        // the result. A mask built at capture size (3024 x 1964 against a plane
        // 1421 points wide) overhangs the layer: its near edge lands inside and
        // its far edge falls outside entirely, so the edge fade appears on one
        // side of the plane and not the other, and the blur ramp never reaches
        // full strength. Widening the fade to 280 moved the left edge by eight
        // column buckets and left the right edge identical to two decimal
        // places - which is what pinned the space down.
        let feather = PlaneFoldStyle.maxFeather * p
        applyBlur(progress: Double(p), pixelHeight: height, pixelWidth: width, feather: feather)
        updateVeil(progress: p, bounds: bounds, size: CGSize(width: width, height: height),
                   feather: feather)
    }

    /// Where a point on the plane lands on screen, once it has been rotated
    /// about the hinge and put through the perspective divide.
    ///
    /// The projection is worked through by hand rather than read back from Core
    /// Animation because the veil has to be cut for the same frame the plane is
    /// drawn in, and the presentation layer is a frame behind.
    ///
    /// `x` is measured from the middle of the hinge and `y` up from it, which is
    /// the plane's own coordinate space.
    private static func project(x: CGFloat, y: CGFloat,
                                progress p: CGFloat, bounds: NSRect) -> CGPoint {
        let theta = maxLean * p
        let rotatedY = y * cos(theta)
        let z = -y * sin(theta)
        let w = 1 - z / perspectiveDistance
        return CGPoint(x: bounds.midX + x / w,
                       y: bounds.midY + (bounds.minY + rotatedY - bounds.midY) / w)
    }

    /// Cuts the void to the plane's own outline.
    ///
    /// A plain vertical gradient was tried first and is not enough: it darkens
    /// the top correctly but leaves the side margins transparent, and the real
    /// desktop showing beside the leaning copy of itself reads as a double
    /// image. The dark has to cover everything the plane does not, which is a
    /// shape, not a ramp. Because that shape is the plane's own footprint, the
    /// darkness necessarily arrives in step with the fold.
    ///
    /// The hole has to stop where the plane becomes genuinely opaque, or the
    /// real screen shows through the half-transparent band - sharp, beside the
    /// leaning blurred copy of itself.
    ///
    /// Since the feather now tapers to nothing at the hinge, so does the hole:
    /// its bottom corners sit on the plane's true corners and only the far ones
    /// are pulled in. The straight edge between them tracks the ramp closely
    /// enough, which the red-veil measurement confirms.
    private func updateVeil(progress p: CGFloat, bounds: NSRect,
                            size: CGSize, feather: CGFloat) {
        let opaqueAt = feather * 1.5
        let halfWidth = size.width / 2
        let corners = [
            PlaneFoldStyle.project(x: -halfWidth, y: 0, progress: p, bounds: bounds),
            PlaneFoldStyle.project(x: halfWidth, y: 0, progress: p, bounds: bounds),
            PlaneFoldStyle.project(x: halfWidth - opaqueAt, y: max(0, size.height - opaqueAt),
                                   progress: p, bounds: bounds),
            PlaneFoldStyle.project(x: -halfWidth + opaqueAt, y: max(0, size.height - opaqueAt),
                                   progress: p, bounds: bounds),
        ]

        let path = CGMutablePath()
        path.addRect(bounds)
        path.move(to: corners[0])
        for corner in corners.dropFirst() { path.addLine(to: corner) }
        path.closeSubpath()
        // Even-odd, so the quad punches a hole in the full-screen rectangle.
        veil.path = path
    }

    /// Builds the variable-blur mask and hands it to the filter.
    ///
    /// The mask is a vertical ramp: black at the hinge, white at the far edge,
    /// so the radius grows with distance from the hinge. How far down the ramp
    /// reaches is what the fold drives - at a shallow angle only the far edge is
    /// soft, by the end the whole panel is.
    private func applyBlur(progress p: Double, pixelHeight: CGFloat, pixelWidth: CGFloat,
                           feather: CGFloat) {
        guard let blur, p > 0.01, pixelHeight > 0 else {
            plane.filters = nil
            return
        }

        let reach = 1.25 - p * 1.5
        if maskImage == nil || abs(maskReach - reach) > 0.01 {
            maskReach = reach
            let low = max(0, reach - 0.45) * pixelHeight
            let high = min(1, reach + 0.35) * pixelHeight
            // Core Image's origin is bottom left, so "white at the top" means the
            // brighter end sits at the larger y.
            let gradient = CIFilter(name: "CILinearGradient")
            gradient?.setValue(CIVector(x: pixelWidth / 2, y: low), forKey: "inputPoint0")
            gradient?.setValue(CIColor.black, forKey: "inputColor0")
            gradient?.setValue(CIVector(x: pixelWidth / 2, y: high), forKey: "inputPoint1")
            gradient?.setValue(CIColor.white, forKey: "inputColor1")
            maskImage = gradient?.outputImage?.cropped(
                to: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }

        blur.setValue(maskImage, forKey: "inputMask")
        blur.setValue(PlaneFoldStyle.maxBlurRadius * CGFloat(p), forKey: kCIInputRadiusKey)

        // The blur is deliberately left unbounded.
        //
        // A blur samples past the edge of its input, where there is nothing but
        // transparent black, so the edges of the plane fade out instead of
        // stopping on a hard line. Clamping the input and cropping the output
        // was tried first and gives a crisp-edged rectangle; letting it spill
        // into the void reads better, and the void is the only thing out there.
        //
        // This only works because the earlier grey wash is gone. With the
        // brightness and contrast pass still in the chain the same spill came
        // out as a haze around the plane rather than a soft edge.

        // Frosted glass rather than fog: saturation only.
        //
        // A plain blur reads as grey mist because blurring averages colour away,
        // so the saturation is pushed back up. Saturation is safe here because
        // it is a ratio about the pixel's own luma and leaves brightness alone.
        //
        // Brightness and contrast were tried alongside it and had to go. Core
        // Image works in a *linear* colour space, so easing the contrast to 0.98
        // pivots dark pixels about linear 0.5: an sRGB 0.1 pixel is 0.010 linear
        // and comes back 0.020, twice as bright. Measured, that put a uniform
        // +15/255 white haze over the entire screen the instant the effect
        // began - the blur ramp was correct and the wash was not.
        let glass = CIFilter(name: "CIColorControls")
        glass?.setValue(1 + 0.35 * p, forKey: kCIInputSaturationKey)

        // Soften the plane's own outline.
        //
        // Everything above blurs the *contents*; the rectangle they sit in still
        // ends on a hard line, so a blurred desktop reads as a sharp-edged
        // cutout pasted onto the void. This fades the alpha out along the
        // border instead.
        //
        // `CALayer.mask` would be the obvious tool and cannot be used - measured,
        // a layer carrying both a mask and `filters` silently drops the filters.
        // So the fade is another Core Image pass, using a white rectangle the
        // exact size of the plane as an alpha mask.
        //
        // The softness is not uniform around the border: the rectangle goes
        // through the *same* variable blur as the contents, driven by the same
        // gradient. An edge is exactly as soft as the picture next to it, so the
        // hinge end stays crisp where nothing is blurred and only the far end
        // dissolves. A uniform feather was tried first and is wrong in a way
        // that is easy to see once pointed at: it rounds off the bottom corners,
        // which are the part of the panel still facing the viewer squarely.
        //
        // The rectangle is at the plane's true size, not inset, so at the hinge
        // the edge lands on the physical border of the screen where a hard edge
        // cannot be seen at all.
        var edge: CIFilter?
        if feather > 1,
           let solid = CIFilter(name: "CIConstantColorGenerator") {
            solid.setValue(CIColor.white, forKey: kCIInputColorKey)
            var mask = solid.outputImage?
                .cropped(to: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            if let ramp = CIFilter(name: "CIMaskedVariableBlur") {
                ramp.setValue(mask, forKey: kCIInputImageKey)
                ramp.setValue(maskImage, forKey: "inputMask")
                ramp.setValue(feather, forKey: kCIInputRadiusKey)
                mask = ramp.outputImage
            }
            // Source-in keeps the content only where the mask is opaque, which
            // multiplies the two alphas - exactly the fade we want.
            edge = CIFilter(name: "CISourceInCompositing")
            edge?.setValue(mask, forKey: kCIInputBackgroundImageKey)
        }

        plane.filters = [blur, glass, edge].compactMap { $0 }
    }

    private func startFeedIfNeeded() {
        guard !feed.isRunning else { return }
        feed.onUnavailable = { [weak self] message in self?.onUnavailable?(message) }
        feed.start(excludingWindowNumber: host?.window?.windowNumber) { [weak self] surface in
            guard let self else { return }
            // Assigning an IOSurface hands the layer the captured pixels without
            // a copy. Implicit animations would try to cross-fade every frame.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.capturedWidth = CGFloat(IOSurfaceGetWidth(surface))
            self.capturedHeight = CGFloat(IOSurfaceGetHeight(surface))
            self.plane.contents = surface

            CATransaction.commit()

            guard !self.hasFrame else { return }
            self.hasFrame = true
            // Replay the last state so the plane appears as soon as pixels exist
            // rather than waiting for the lid to move again.
            if let state = self.lastState {
                self.apply(progress: state.progress, direction: state.direction,
                           bounds: state.bounds, scale: state.scale)
            }
        }
    }
}
