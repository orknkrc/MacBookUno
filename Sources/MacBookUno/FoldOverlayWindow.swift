import AppKit

/// The borderless, click-through window that covers the screen and carries the
/// fold effect.
///
/// Intensity is no longer a uniform `alphaValue`; it is applied *spatially* via
/// `NSVisualEffectView.maskImage`, so the frosted region sweeps across the
/// screen according to the hinge angle. All documented API.
final class FoldOverlayWindow: NSWindow {

    /// Why the window level is `popUpMenu - 1`:
    /// it has to sit above normal windows, the menu bar and the status bar, but
    /// BELOW pop-up menus - otherwise opening our own menu would render the menu
    /// frosted too.
    static let overlayLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) - 1
    )

    /// First pass: blurs the desktop behind the window.
    private let effectView = NSVisualEffectView()
    /// Second pass: blurs the FIRST pass's output again.
    ///
    /// `NSVisualEffectView` has no public blur-radius control, so a single pass
    /// leaves large shapes (window edges, the Dock silhouette) readable. Stacking
    /// a `.withinWindow` view on top blurs what the first pass drew into the
    /// window, which is the documented way to get a heavier blur.
    private let secondPass = NSVisualEffectView()
    /// A faint light wash over the frosted region.
    ///
    /// Real frosted glass scatters light, so it does not just blur - it lifts
    /// and desaturates what is behind it. Blur alone keeps too much contrast,
    /// which is what makes the effect read as "sharp" next to the reference.
    private let frost = NSView()

    /// How strongly the light wash lifts the frosted region. Higher reads as
    /// thicker glass; too high and the screen just looks washed out.
    ///
    /// Calibrated against the pinned dark appearance (see `init`), so it stays
    /// correct regardless of the user's system theme.
    private static let frostOpacity: CGFloat = 0.16

    /// Regenerating the mask every frame is wasteful; the current one is reused
    /// until progress moves by at least this much.
    private static let progressQuantum = 1.0 / 300.0
    private var lastMaskProgress: Double = -1
    private var lastMaskDirection: SweepDirection?
    private var lastMaskHeight: Int = 0

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Clicks, scrolling and the cursor all pass through to whatever is below.
        ignoresMouseEvents = true
        level = FoldOverlayWindow.overlayLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        isMovable = false
        hidesOnDeactivate = false
        alphaValue = 1
        // The effect is pinned to the dark appearance on purpose.
        //
        // NSVisualEffectView materials are appearance-aware: the same material
        // tints toward white in light mode and toward black in dark mode. Left to
        // follow the system, the fold would look like two different effects
        // depending on the user's theme. Pinning it means everyone sees the same
        // frosted glass, and the light wash below is calibrated against it.
        appearance = NSAppearance(named: .darkAqua)

        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        container.autoresizingMask = [.width, .height]

        effectView.frame = container.bounds
        effectView.autoresizingMask = [.width, .height]
        // behindWindow: blurs the content BEHIND the window.
        effectView.blendingMode = .behindWindow
        effectView.material = .fullScreenUI
        // .active: keep the effect live even when the app is not frontmost.
        effectView.state = .active
        container.addSubview(effectView)

        secondPass.frame = container.bounds
        secondPass.autoresizingMask = [.width, .height]
        // withinWindow: blends with what is already drawn in this window,
        // i.e. the first pass's blurred output.
        secondPass.blendingMode = .withinWindow
        secondPass.material = .fullScreenUI
        secondPass.state = .active
        container.addSubview(secondPass)

        frost.frame = container.bounds
        frost.autoresizingMask = [.width, .height]
        frost.wantsLayer = true
        frost.layer?.backgroundColor = NSColor.white
            .withAlphaComponent(FoldOverlayWindow.frostOpacity).cgColor
        let frostMask = CALayer()
        frostMask.contentsGravity = .resize
        frost.layer?.mask = frostMask
        container.addSubview(frost)

        contentView = container
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition(on screen: NSScreen) {
        setFrame(screen.frame, display: true)
        contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
        effectView.frame = NSRect(origin: .zero, size: screen.frame.size)
        secondPass.frame = effectView.frame
        frost.frame = effectView.frame
        // The mask has to be regenerated if the height changed.
        lastMaskProgress = -1
    }

    /// Applies fold progress. 0 = no effect, 1 = the whole screen frosted.
    func apply(progress: Double, direction: SweepDirection) {
        let p = min(max(progress, 0), 1)

        if p < 0.005 {
            if isVisible { orderOut(nil) }
            return
        }
        if !isVisible { orderFrontRegardless() }

        updateMaskIfNeeded(progress: p, direction: direction)
    }

    func hideOverlay() {
        if isVisible { orderOut(nil) }
    }

    // MARK: - Internals

    private func updateMaskIfNeeded(progress: Double, direction: SweepDirection) {
        let quantized = (progress / FoldOverlayWindow.progressQuantum).rounded()
            * FoldOverlayWindow.progressQuantum
        // The mask is generated at the view's PIXEL height.
        //
        // Measured: `maskImage` does not stretch the image to the view; it maps
        // it onto the backing store pixel for pixel, aligned to the top. Built in
        // points, the mask gets squeezed into the top half on a Retina (2x)
        // display - at 50% progress the boundary landed at 0.75 instead of 0.50.
        // Built in pixels it lines up 1:1.
        let scale = backingScaleFactor > 0 ? backingScaleFactor : 2
        let height = Int((effectView.bounds.height * scale).rounded())
        guard quantized != lastMaskProgress
                || direction != lastMaskDirection
                || height != lastMaskHeight else { return }
        lastMaskProgress = quantized
        lastMaskDirection = direction
        lastMaskHeight = height

        guard let cgMask = FoldMask.cgImage(progress: quantized, direction: direction, height: height)
        else { return }
        let nsMask = NSImage(cgImage: cgMask, size: NSSize(width: cgMask.width, height: cgMask.height))
        nsMask.resizingMode = .stretch
        effectView.maskImage = nsMask
        secondPass.maskImage = nsMask

        // The frost layer is a plain view, so it is masked through its layer.
        // Implicit animations are disabled: this runs up to 30 times a second and
        // a quarter-second default animation would lag the sweep behind the lid.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frost.layer?.mask?.frame = frost.bounds
        frost.layer?.mask?.contents = cgMask
        CATransaction.commit()
    }

}
