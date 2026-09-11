import AppKit

/// The thin highlight along the leading edge of the frosted region.
///
/// On the iPhone Duo the flap's edge reads like a pane of glass catching light.
/// The mask alone cannot produce that (a mask only says where the blur applies,
/// it cannot add brightness), so we draw a separate, very faint band.
private final class EdgeHighlightView: NSView {
    var intensity: CGFloat = 0 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard intensity > 0.001 else { return }
        let colors = [
            NSColor(white: 1, alpha: 0),
            NSColor(white: 1, alpha: 0.13 * intensity),
            NSColor(white: 1, alpha: 0),
        ]
        guard let gradient = NSGradient(colors: colors,
                                        atLocations: [0, 0.5, 1],
                                        colorSpace: .deviceRGB) else { return }
        gradient.draw(in: bounds, angle: 90)
    }
}

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

    private let effectView = NSVisualEffectView()
    private let highlight = EdgeHighlightView()

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

        highlight.autoresizingMask = [.width]
        container.addSubview(highlight)

        contentView = container
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition(on screen: NSScreen) {
        setFrame(screen.frame, display: true)
        contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
        effectView.frame = NSRect(origin: .zero, size: screen.frame.size)
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
        updateHighlight(progress: p, direction: direction)
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
        effectView.maskImage = FoldMask.image(progress: quantized, direction: direction, height: height)
    }

    private func updateHighlight(progress: Double, direction: SweepDirection) {
        guard let contentView else { return }
        let height = contentView.bounds.height
        let position = FoldMask.boundaryPosition(progress: progress, direction: direction)
        let bandHeight = max(2, height * CGFloat(FoldMask.softness) * 0.9)
        let centerY = CGFloat(position) * height

        highlight.frame = NSRect(x: 0,
                                 y: centerY - bandHeight / 2,
                                 width: contentView.bounds.width,
                                 height: bandHeight)
        // Fade the highlight as the boundary leaves the screen, so no line is left hanging.
        let fadeIn = min(1, progress / 0.10)
        let fadeOut = min(1, (1 - progress) / 0.10)
        highlight.intensity = CGFloat(min(fadeIn, fadeOut))
    }
}
