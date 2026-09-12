import AppKit

/// The visual treatment applied as the lid folds.
enum FoldStyle: String, CaseIterable {
    /// A frosted ramp spanning the whole panel. Requires no permissions.
    case blur
    /// The desktop held at its own angle while the panel turns around it.
    /// Captures the screen, so it needs Screen Recording permission.
    case plane

    var localizedName: String {
        switch self {
        case .blur:  return "Blur"
        case .plane: return "Fold Plane"
        }
    }

    var summary: String {
        switch self {
        case .blur:  return "Frost spread evenly across the panel. No permissions."
        case .plane: return "The desktop keeps its angle as the lid turns. Needs Screen Recording."
        }
    }

    func makeRenderer() -> FoldStyleRenderer {
        switch self {
        case .blur:  return BlurFoldStyle()
        case .plane: return PlaneFoldStyle()
        }
    }
}

/// One visual treatment of the fold.
///
/// The overlay window owns the window and the geometry; a renderer owns the
/// layers that produce the look, so a new style is a new file rather than
/// another branch inside the window.
protocol FoldStyleRenderer: AnyObject {
    /// Called on the main queue when the style cannot run, with a message fit to
    /// show a user. Styles that need no permissions never call it, but it is on
    /// the protocol so a failing style can never fail silently.
    var onUnavailable: ((String) -> Void)? { get set }

    /// Adds the style's views to the overlay's container.
    func install(in container: NSView)
    /// Removes them again when the style changes.
    func uninstall()
    /// Updates for the current fold state.
    ///
    /// - Parameter scale: the backing scale factor. Masks are consumed in
    ///   pixels rather than points, so every style needs it.
    func apply(progress: Double, direction: SweepDirection, bounds: NSRect, scale: CGFloat)
}

/// Builds fold masks and skips the work when nothing relevant changed.
///
/// Regenerating a full-height bitmap on every frame is wasteful, and every style
/// needs the same caching, so it lives here rather than in each renderer.
final class FoldMaskCache {
    /// Progress has to move by at least this much before the mask is rebuilt.
    private static let quantum = 1.0 / 300.0

    private var lastProgress = -1.0
    private var lastDirection: SweepDirection?
    private var lastHeight = 0
    private var lastSoftness = -1.0

    private(set) var cgImage: CGImage?
    private(set) var nsImage: NSImage?

    /// Returns true when the mask was rebuilt and needs reassigning.
    @discardableResult
    func update(progress: Double, direction: SweepDirection, height: Int, softness: Double) -> Bool {
        let quantized = (progress / FoldMaskCache.quantum).rounded() * FoldMaskCache.quantum
        guard quantized != lastProgress
                || direction != lastDirection
                || height != lastHeight
                || softness != lastSoftness else { return false }

        guard let cg = FoldMask.cgImage(progress: quantized, direction: direction,
                                        height: height, softness: softness) else { return false }
        lastProgress = quantized
        lastDirection = direction
        lastHeight = height
        lastSoftness = softness
        cgImage = cg
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        image.resizingMode = .stretch
        nsImage = image
        return true
    }

    /// Forces the next `update` to rebuild, e.g. after the screen changed.
    func invalidate() {
        lastProgress = -1
    }

    /// Applies the cached mask to a plain layer-backed view.
    ///
    /// Implicit animations are disabled: this runs many times a second and a
    /// default quarter-second animation would lag the sweep behind the lid.
    func applyToLayerMask(of view: NSView) {
        guard let cgImage else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.mask?.frame = view.bounds
        view.layer?.mask?.contents = cgImage
        CATransaction.commit()
    }
}

/// A layer-backed view with a mask layer ready for `FoldMaskCache`.
func makeMaskedView() -> NSView {
    let view = NSView()
    view.wantsLayer = true
    let mask = CALayer()
    mask.contentsGravity = .resize
    view.layer?.mask = mask
    return view
}
