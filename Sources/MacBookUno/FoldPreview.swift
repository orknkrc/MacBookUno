import AppKit

/// A slider that lives in the menu and drives the effect from a pretend angle.
///
/// Tuning the look otherwise means physically moving the lid, which cannot be
/// done while reading the screen, or relaunching with `--simulate`. Both are
/// poor ways to answer "is this too dark?".
///
/// A menu item can host a view, and a control inside one keeps receiving events
/// while the menu is open, which is the whole reason this works.
final class FoldPreviewView: NSView {

    /// The widest angle the slider offers. The measured hinge range on this Mac
    /// is 0-132 degrees, and the few degrees of headroom let the slider start
    /// above any threshold so the moment the effect begins is visible.
    static let maxAngle: Double = 135

    /// `nil` means stop pretending and follow the sensor again.
    var onAngle: ((Double?) -> Void)?

    private let slider = NSSlider()
    private let readout = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: 52))

        slider.minValue = 0
        slider.maxValue = FoldPreviewView.maxAngle
        slider.doubleValue = FoldPreviewView.maxAngle
        slider.target = self
        slider.action = #selector(sliderMoved)
        // Keep firing while the knob is held, otherwise the effect only catches
        // up when the mouse is released and the slider stops being a preview.
        slider.isContinuous = true
        slider.frame = NSRect(x: 14, y: 24, width: 204, height: 20)
        addSubview(slider)

        readout.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .center
        readout.frame = NSRect(x: 14, y: 6, width: 204, height: 16)
        addSubview(readout)

        show(angle: nil)
    }

    required init?(coder: NSCoder) { nil }

    /// Reflects the current state without firing `onAngle`.
    func show(angle: Double?) {
        if let angle {
            slider.doubleValue = angle
            readout.stringValue = String(format: "Previewing %.0f°", angle)
        } else {
            slider.doubleValue = FoldPreviewView.maxAngle
            readout.stringValue = "Drag to preview"
        }
    }

    @objc private func sliderMoved() {
        let angle = slider.doubleValue
        readout.stringValue = String(format: "Previewing %.0f°", angle)
        onAngle?(angle)
    }
}
