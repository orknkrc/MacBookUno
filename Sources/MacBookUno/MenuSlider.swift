import AppKit

/// A slider that lives inside a menu, with a caption under it.
///
/// A menu item can host a view, and a control inside one keeps receiving events
/// while the menu is open, which is the whole reason this works.
///
/// Tuning the effect otherwise means physically moving the lid, which cannot be
/// done while reading the screen, or relaunching with `--simulate`. Both are
/// poor ways to answer "is this too dark?".
final class MenuSliderView: NSView {

    /// Fires on every movement of the knob, in whole degrees.
    var onChange: ((Double) -> Void)?

    private let slider = NSSlider()
    private let caption = NSTextField(labelWithString: "")

    init(minimum: Double, maximum: Double) {
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: 52))

        slider.minValue = minimum
        slider.maxValue = maximum
        slider.target = self
        slider.action = #selector(moved)
        // Keep firing while the knob is held. Otherwise nothing happens until
        // the mouse is released, which is useless for a preview and unhelpful
        // for a threshold you are trying to feel out.
        slider.isContinuous = true
        slider.frame = NSRect(x: 14, y: 24, width: 204, height: 20)
        addSubview(slider)

        caption.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.frame = NSRect(x: 14, y: 6, width: 204, height: 16)
        addSubview(caption)
    }

    required init?(coder: NSCoder) { nil }

    /// Reflects a value without firing `onChange`.
    func show(value: Double, caption text: String) {
        slider.doubleValue = value
        caption.stringValue = text
    }

    var maximum: Double { slider.maxValue }

    @objc private func moved() {
        // Whole degrees: the sensor resolves hundredths, but a threshold or a
        // preview angle finer than a degree is not a distinction anyone makes.
        onChange?(slider.doubleValue.rounded())
    }
}
