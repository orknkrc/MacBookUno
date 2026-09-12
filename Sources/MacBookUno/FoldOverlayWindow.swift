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

    /// Forwarded from whichever style is installed, so a style that cannot run
    /// says so instead of quietly drawing nothing.
    var onStyleUnavailable: ((String) -> Void)?

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

        let scale = backingScaleFactor > 0 ? backingScaleFactor : 2

        if p <= 0 {
            // Hand the renderer the zero before the window goes away. Returning
            // here early instead meant a style that holds a resource - the Fold
            // Plane holds a screen capture - was never told the effect had
            // ended, so it kept capturing for the rest of the session.
            renderer?.apply(progress: 0, direction: direction,
                            bounds: container.bounds, scale: scale)
            if isVisible { orderOut(nil) }
            return
        }
        if !isVisible { orderFrontRegardless() }

        install(style: style)
        renderer?.apply(progress: p, direction: direction, bounds: container.bounds, scale: scale)
    }

    /// Swaps renderers when the user picks a different style.
    private func install(style: FoldStyle) {
        guard installedStyle != style else { return }
        renderer?.uninstall()
        let renderer = style.makeRenderer()
        renderer.onUnavailable = { [weak self] message in self?.onStyleUnavailable?(message) }
        renderer.install(in: container)
        self.renderer = renderer
        installedStyle = style
    }

    func hideOverlay() {
        if isVisible { orderOut(nil) }
    }

    /// Shuts the overlay down for good: the renderer first, then the window.
    ///
    /// Hiding alone is not enough. A style can hold a resource - the Fold Plane
    /// holds a screen capture - and only learns the effect is over when it is
    /// handed a zero or uninstalled. Ordering the window out leaves it running.
    func teardown() {
        renderer?.apply(progress: 0, direction: .fromTop,
                        bounds: container.bounds,
                        scale: backingScaleFactor > 0 ? backingScaleFactor : 2)
        renderer?.uninstall()
        renderer = nil
        installedStyle = nil
        if isVisible { orderOut(nil) }
    }
}
