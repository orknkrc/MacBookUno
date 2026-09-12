import AppKit

/// Frost spread evenly across the panel, heaviest at the far edge.
///
/// The blur strength varies continuously rather than sweeping a bounded region,
/// which is what the reference animation does: no visible edge, just more frost
/// the further the surface has turned away from the viewer.
final class BlurFoldStyle: FoldStyleRenderer {

    /// The ramp covers the whole panel, so there is no boundary to see.
    private static let softness: Double = 1.0
    /// Strength of the light wash. Real frosted glass scatters light rather than
    /// only blurring; without this the result keeps too much contrast.
    private static let frostOpacity: CGFloat = 0.16

    /// First pass: blurs the desktop behind the window.
    private let effectView = NSVisualEffectView()
    /// Second pass: blurs the first pass's output again.
    ///
    /// `NSVisualEffectView` has no public blur-radius control, so a single pass
    /// leaves large shapes (window edges, the Dock silhouette) readable.
    private let secondPass = NSVisualEffectView()
    private let frost = makeMaskedView()

    private let mask = FoldMaskCache()

    /// Never called: this style needs nothing it might not get.
    var onUnavailable: ((String) -> Void)?

    func install(in container: NSView) {
        for effect in [effectView, secondPass] {
            effect.frame = container.bounds
            effect.autoresizingMask = [.width, .height]
            effect.material = .fullScreenUI
            effect.state = .active
            container.addSubview(effect)
        }
        // behindWindow blurs what is behind the window; withinWindow blends with
        // what this window has already drawn, i.e. the first pass.
        effectView.blendingMode = .behindWindow
        secondPass.blendingMode = .withinWindow

        frost.frame = container.bounds
        frost.autoresizingMask = [.width, .height]
        frost.layer?.backgroundColor = NSColor.white
            .withAlphaComponent(BlurFoldStyle.frostOpacity).cgColor
        container.addSubview(frost)
    }

    func uninstall() {
        for view in [effectView, secondPass, frost] { view.removeFromSuperview() }
    }

    func apply(progress: Double, direction: SweepDirection, bounds: NSRect, scale: CGFloat) {
        for view in [effectView, secondPass] { view.frame = bounds }
        frost.frame = bounds

        let height = Int((bounds.height * scale).rounded())
        guard mask.update(progress: progress, direction: direction,
                          height: height, softness: BlurFoldStyle.softness) else { return }
        effectView.maskImage = mask.nsImage
        secondPass.maskImage = mask.nsImage
        mask.applyToLayerMask(of: frost)
    }
}
