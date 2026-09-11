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

    private let container = NSView()
    private var renderer: FoldStyleRenderer?
    private var installedStyle: FoldStyle?

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

        container.frame = NSRect(origin: .zero, size: screen.frame.size)
        container.autoresizingMask = [.width, .height]

        contentView = container
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition(on screen: NSScreen) {
        setFrame(screen.frame, display: true)
        container.frame = NSRect(origin: .zero, size: screen.frame.size)
    }

    /// Applies fold progress. 0 = no effect, 1 = fully folded.
    func apply(progress: Double, direction: SweepDirection, style: FoldStyle) {
        let p = min(max(progress, 0), 1)

        if p < 0.005 {
            if isVisible { orderOut(nil) }
            return
        }
        if !isVisible { orderFrontRegardless() }

        install(style: style)
        let scale = backingScaleFactor > 0 ? backingScaleFactor : 2
        renderer?.apply(progress: p, direction: direction, bounds: container.bounds, scale: scale)
    }

    /// Swaps renderers when the user picks a different style.
    private func install(style: FoldStyle) {
        guard installedStyle != style else { return }
        renderer?.uninstall()
        let renderer = style.makeRenderer()
        renderer.install(in: container)
        self.renderer = renderer
        installedStyle = style
    }

    func hideOverlay() {
        if isVisible { orderOut(nil) }
    }
}
