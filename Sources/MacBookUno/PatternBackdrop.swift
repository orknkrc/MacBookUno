import AppKit

/// Used only by the `--pattern` debug flag: a finely striped test pattern laid
/// UNDER the overlay.
///
/// Why it exists: measuring exactly where the frosted boundary lands on screen
/// is impossible over arbitrary desktop content, because most of the screen is
/// flat color and the blur has nothing to act on there. Against a known
/// high-frequency pattern the boundary is unmistakable.
final class PatternBackdropWindow: NSWindow {

    private final class StripeView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.setFill()
            bounds.fill()
            NSColor.white.setFill()
            // Vertical lines 4 points apart: blurring collapses horizontal
            // contrast, so a per-row sharpness measurement reads the boundary directly.
            var x: CGFloat = 0
            while x < bounds.width {
                NSRect(x: x, y: 0, width: 2, height: bounds.height).fill()
                x += 4
            }
            // A reference mark every 10%, to make the boundary position easy to read off.
            NSColor.systemRed.setFill()
            for step in 1..<10 {
                let markY = bounds.height * CGFloat(step) / 10
                NSRect(x: 0, y: markY - 1, width: 60, height: 3).fill()
            }
        }
    }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        // Just below the overlay, but above normal windows.
        level = NSWindow.Level(rawValue: FoldOverlayWindow.overlayLevel.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        let view = StripeView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        contentView = view
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
