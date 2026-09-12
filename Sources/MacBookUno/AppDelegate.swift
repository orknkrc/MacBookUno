import AppKit
import LidAngleKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let settings = Settings()
    private let monitor = LidAngleMonitor(preference: .bestResolution, pollHz: 30)
    private var controller: FoldController!

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let angleItem = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    private let foldItem = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let enableItem = NSMenuItem(title: "Effect", action: #selector(toggleEnabled), keyEquivalent: "")
    private let thresholdItem = NSMenuItem(title: "Threshold", action: nil, keyEquivalent: "")
    private let directionItem = NSMenuItem(title: "Sweep", action: nil, keyEquivalent: "")
    private let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
    /// The live sensor reading, folded into a submenu of its own: it answers
    /// "is this working?", which is a question you ask rarely and never act on
    /// from here, so it does not belong in front of the controls.
    private let sensorItem = NSMenuItem(title: "Sensor: starting…", action: nil, keyEquivalent: "")
    private let previewItem = NSMenuItem(title: "Preview", action: nil, keyEquivalent: "")

    /// How long a preview survives after the menu closes.
    ///
    /// The overlay sits above the menu bar, so a deep preview hides the status
    /// item that would let you cancel it - not "hard to find", invisible. A
    /// preview left running is therefore a way to lock yourself out of the app,
    /// and it has to end on its own.
    ///
    /// The clock starts when the menu closes, not on every change of the angle.
    /// While the menu is open the slider is right there, so a countdown would
    /// only snatch the view away mid-inspection; the risk begins when the menu
    /// goes.
    private static let previewHold: TimeInterval = 10
    /// How long the angle takes to travel back to the lid's own.
    private static let previewRelease: TimeInterval = 0.45

    private var previewTimer: Timer?
    /// Set while the preview came from the slider. `--simulate` is a debug flag
    /// that is meant to hold, so it is deliberately not swept up by any of this.
    private var previewFromSlider = false
    /// The release in flight: where it started and when.
    private var previewReleasing: (from: Double, start: TimeInterval)?
    /// The widest angle the preview offers. A few degrees past the hinge's own
    /// maximum, so the slider can start above any threshold and the moment the
    /// effect begins is visible.
    private static let previewMaxAngle: Double = 135
    private let previewView = MenuSliderView(minimum: 0, maximum: previewMaxAngle)
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")

    /// Test flags handed over from main.swift.
    var simulatedAngle: Double?
    var sweepEnabled = false
    /// --log: print angle and fold amount to stdout (diagnostics / tuning).
    var logEnabled = false
    /// --pattern: lay a striped test pattern under the overlay for measurement.
    var patternEnabled = false
    /// --capture-test: write one captured frame to this path and exit.
    var captureTestPath: String?
    private var patternWindow: PatternBackdropWindow?
    private var lastLog: TimeInterval = 0

    /// Shown once per launch: repeating a modal on every frame would be unusable.
    private var reportedStyleFailure = false

    /// Whether the sensor is usable, for the icon and the Sensor row.
    private var sensorIsHealthy = true

    private var menuIsOpen = false
    private var lastMenuRefresh: TimeInterval = 0

    // MARK: - Startup

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = captureTestPath { runCaptureTest(writingTo: path); return }
        controller = FoldController(settings: settings, monitor: monitor)
        buildStatusItem()

        monitor.onStateChange = { [weak self] state in
            self?.apply(state: state)
        }

        do {
            try monitor.start()
        } catch {
            // If the sensor is missing, still launch, but say why it does not work.
            presentStartupFailure(error)
        }

        controller.onUpdate = { [weak self] raw, smoothed, intensity in
            guard let self else { return }
            self.advancePreviewRelease()
            self.refreshMenuIfVisible(raw: raw, smoothed: smoothed, intensity: intensity)
            self.logIfNeeded(raw: raw, smoothed: smoothed, intensity: intensity)
        }
        controller.onStyleUnavailable = { [weak self] message in
            self?.reportStyleUnavailable(message)
        }
        controller.simulatedAngle = simulatedAngle
        if sweepEnabled {
            // Sweep from a little above the threshold down to 0: shows both extremes.
            controller.sweepRange = 0...(settings.threshold * 1.2)
        }
        if patternEnabled, let screen = FoldController.internalScreen {
            patternWindow = PatternBackdropWindow(screen: screen)
        }
        controller.start()

        // A display was attached or removed, or the resolution changed.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Waking from sleep: the device handle may be stale, so reconnect.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        monitor.stop()
    }

    /// Verifies the capture path end to end, then exits.
    private func runCaptureTest(writingTo path: String) {
        Task {
            do {
                let image = try await ScreenCapture.captureInternalDisplay(excludingWindowNumber: nil)
                let rep = NSBitmapImageRep(cgImage: image)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    print("could not encode the capture"); exit(1)
                }
                try data.write(to: URL(fileURLWithPath: path))
                print("captured \(image.width)x\(image.height) to \(path)")
                exit(0)
            } catch {
                print("capture failed: \(error)")
                exit(1)
            }
        }
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        angleItem.isEnabled = false
        foldItem.isEnabled = false
        statusLine.isEnabled = false

        // Ordered by what you came here to do. The effect's own switch first,
        // then the tool you reach for while tuning, then the settings, and the
        // diagnostics last - they used to sit in the first two rows, where the
        // eye lands, despite being the one thing you never act on.
        menu.delegate = self

        enableItem.target = self
        enableItem.state = settings.isEnabled ? .on : .off
        menu.addItem(enableItem)

        menu.addItem(.separator())
        // The slider sits in the menu itself rather than behind a submenu: it is
        // the most-handled control here and was two clicks away. Nudging it by
        // accident is survivable now that a preview releases itself.
        addPreviewItems(to: menu)

        menu.addItem(.separator())
        thresholdItem.submenu = buildThresholdMenu()
        menu.addItem(thresholdItem)
        styleItem.submenu = buildStyleMenu()
        menu.addItem(styleItem)
        directionItem.submenu = buildDirectionMenu()
        menu.addItem(directionItem)

        menu.addItem(.separator())
        sensorItem.submenu = buildSensorMenu()
        menu.addItem(sensorItem)
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        // Version in the interface, not only behind --version: it is the first
        // thing anyone reporting a problem is asked for.
        let version = NSMenuItem(title: "MacBookUno \(ProjectVersion.current)",
                                 action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateStatusIcon()
        updateThresholdTitle()
        updateDirectionTitle()
        updateStyleTitle()
        // Reflect --simulate, so the slider and the sensor never disagree about
        // which angle the effect is being driven from.
        showPreview(angle: controller.simulatedAngle)
        updatePreviewTitle()
        updateLoginTitle()
    }

    @objc private func toggleLoginItem() {
        let wanted = LoginItem.state != .on
        if let problem = LoginItem.set(wanted) {
            let alert = NSAlert()
            alert.messageText = "Open at Login"
            alert.informativeText = problem
            alert.alertStyle = .warning
            alert.runModal()
        }
        updateLoginTitle()
    }

    private func updateLoginTitle() {
        switch LoginItem.state {
        case .on:
            loginItem.title = "Open at Login"
            loginItem.state = .on
            loginItem.isEnabled = true
        case .off:
            loginItem.title = "Open at Login"
            loginItem.state = .off
            loginItem.isEnabled = true
        case .needsApproval:
            // Registered but not allowed yet. Saying so beats a tick that lies.
            loginItem.title = "Open at Login — approve in System Settings"
            loginItem.state = .mixed
            loginItem.isEnabled = true
        }
    }

    /// The preview: a slider that feeds the controller a pretend angle.
    /// Puts the slider and its escape hatch straight into a menu.
    private func addPreviewItems(to menu: NSMenu) {
        previewView.captionForValue = { AppDelegate.previewCaption(for: $0) }
        previewView.onChange = { [weak self] angle in
            guard let self else { return }
            self.previewFromSlider = true
            self.previewReleasing = nil
            self.cancelPreviewTimer()
            self.controller.simulatedAngle = angle
            self.updatePreviewTitle()
            // The frame loop idles once nothing is moving, and dragging the
            // slider is exactly the case it cannot see coming.
            self.controller.wake()
        }

        let holder = NSMenuItem()
        holder.view = previewView
        menu.addItem(holder)

        previewItem.action = #selector(stopPreview)
        previewItem.target = self
        menu.addItem(previewItem)
    }

    /// The live reading, out of the way but still one hop from the menu.
    private func buildSensorMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.addItem(angleItem)
        submenu.addItem(foldItem)
        submenu.addItem(.separator())
        submenu.addItem(statusLine)
        return submenu
    }

    @objc private func stopPreview() {
        cancelPreviewTimer()
        previewReleasing = nil
        previewFromSlider = false
        controller.simulatedAngle = nil
        showPreview(angle: nil)
        updatePreviewTitle()
        controller.wake()
    }

    private func cancelPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    /// Hands the angle back to the lid, easing rather than cutting.
    ///
    /// Dropping the pretend angle outright jumps the raw reading by however far
    /// the preview sat from the real hinge, and anything past the smoother's
    /// snap threshold arrives in a single frame. That is the same abrupt change
    /// the plane's dissolve exists to avoid, so the angle is walked back
    /// instead.
    private func beginPreviewRelease() {
        guard previewFromSlider, let from = controller.simulatedAngle else { return }
        previewReleasing = (from, ProcessInfo.processInfo.systemUptime)
        controller.wake()
    }

    private func advancePreviewRelease() {
        guard let releasing = previewReleasing else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - releasing.start
        let t = min(1, elapsed / AppDelegate.previewRelease)
        guard t < 1 else {
            previewReleasing = nil
            previewFromSlider = false
            controller.simulatedAngle = nil
            showPreview(angle: nil)
            updatePreviewTitle()
            controller.wake()
            return
        }
        // Read the lid every frame rather than once: it may be moving.
        let target = monitor.latestAngle ?? releasing.from
        let eased = 1 - pow(1 - t, 3)
        controller.simulatedAngle = releasing.from + (target - releasing.from) * eased
        controller.wake()
    }

    private static func previewCaption(for angle: Double) -> String {
        String(format: "Previewing %.0f°", angle)
    }

    /// `nil` parks the knob at the top and says there is nothing to escape.
    private func showPreview(angle: Double?) {
        if let angle {
            previewView.show(value: angle, caption: AppDelegate.previewCaption(for: angle))
        } else {
            previewView.show(value: AppDelegate.previewMaxAngle,
                             caption: "Drag to preview")
        }
    }

    private func updatePreviewTitle() {
        // The slider's own readout already says which angle is being previewed,
        // so this row carries only the way out of one - and nothing at all when
        // there is nothing to escape from.
        previewItem.title = "Follow the Lid"
        previewItem.isHidden = controller?.simulatedAngle == nil
    }

    private func buildThresholdMenu() -> NSMenu {
        let submenu = NSMenu()

        for value in Settings.thresholdChoices {
            let item = NSMenuItem(title: String(format: "%.0f°", value),
                                  action: #selector(selectThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(value - settings.threshold) < 0.5 ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let hint = NSMenuItem(title: "No effect above the threshold; it grows toward 0°.",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        submenu.addItem(hint)
        return submenu
    }

    private func buildStyleMenu() -> NSMenu {
        let submenu = NSMenu()
        for style in FoldStyle.allCases {
            let item = NSMenuItem(title: style.localizedName,
                                  action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.toolTip = style.summary
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = FoldStyle(rawValue: raw) else { return }
        settings.foldStyle = style
        updateStyleTitle()
        controller.wake()
    }

    private func updateStyleTitle() {
        styleItem.title = "Style: \(settings.foldStyle.localizedName)"
        guard let submenu = styleItem.submenu else { return }
        for item in submenu.items {
            guard let raw = item.representedObject as? String else { continue }
            item.state = raw == settings.foldStyle.rawValue ? .on : .off
        }
    }

    private func buildDirectionMenu() -> NSMenu {
        let submenu = NSMenu()
        for direction in SweepDirection.allCases {
            let item = NSMenuItem(title: direction.localizedName,
                                  action: #selector(selectDirection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = direction.rawValue
            item.state = direction == settings.sweepDirection ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let hint = NSMenuItem(title: "The frosted region advances from this edge.",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        submenu.addItem(hint)
        return submenu
    }

    @objc private func selectDirection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let direction = SweepDirection(rawValue: raw) else { return }
        settings.sweepDirection = direction
        updateDirectionTitle()
        controller.wake()
    }

    private func updateDirectionTitle() {
        directionItem.title = "Sweep: \(settings.sweepDirection.localizedName)"
        guard let submenu = directionItem.submenu else { return }
        for item in submenu.items {
            guard let raw = item.representedObject as? String else { continue }
            item.state = raw == settings.sweepDirection.rawValue ? .on : .off
        }
    }

    private func updateThresholdTitle() {
        thresholdItem.title = String(format: "Threshold: %.0f°", settings.threshold)
        if let submenu = thresholdItem.submenu {
            for item in submenu.items {
                guard let value = item.representedObject as? Double else { continue }
                item.state = abs(value - settings.threshold) < 0.5 ? .on : .off
            }
        }
    }

    // MARK: - Menu updates

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        // The readings are refreshed from the frame loop, and that loop idles
        // while the lid is still - so without this the angle and fold rows sit
        // at whatever they last showed for as long as the menu is open.
        controller?.wake()
        // The login item can be changed in System Settings behind our back, so
        // it is read fresh every time rather than cached.
        updateLoginTitle()
        // Back at the controls: the preview is safe again.
        cancelPreviewTimer()
        // A release caught half-way leaves the angle where it got to, so the
        // slider has to be told rather than left at where the drag ended.
        previewReleasing = nil
        showPreview(angle: controller?.simulatedAngle)
        updatePreviewTitle()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        guard previewFromSlider, controller.simulatedAngle != nil else { return }
        cancelPreviewTimer()
        previewTimer = Timer.scheduledTimer(withTimeInterval: AppDelegate.previewHold,
                                            repeats: false) { [weak self] _ in
            self?.beginPreviewRelease()
        }
    }

    /// Updating text while the menu is closed is wasted work; we refresh only
    /// while it is open, throttled to 10 Hz (writing NSMenuItem titles at 60 Hz
    /// is pointless).
    private func refreshMenuIfVisible(raw: Double?, smoothed: Double?, intensity: Double) {
        guard menuIsOpen else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMenuRefresh >= 0.1 else { return }
        lastMenuRefresh = now

        if let raw, let smoothed {
            angleItem.title = String(format: "%.2f°  (smoothed %.2f°)", raw, smoothed)
        } else {
            angleItem.title = "No reading"
        }
        foldItem.title = settings.isEnabled
            ? String(format: "Folded %%%.0f", intensity * 100)
            : "Effect off"
    }

    private func logIfNeeded(raw: Double?, smoothed: Double?, intensity: Double) {
        guard logEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLog >= 0.05 else { return }
        lastLog = now
        let rawText = raw.map { String(format: "%7.2f", $0) } ?? "      -"
        let smoothText = smoothed.map { String(format: "%7.2f", $0) } ?? "      -"
        print(String(format: "%8.3f  raw %@°  smoothed %@°  fold %%%3.0f  via %@",
                     now, rawText, smoothText, intensity * 100, monitor.cadence.rawValue))
        fflush(stdout)
    }

    private func apply(state: LidAngleMonitor.State) {
        switch state {
        case .stopped:
            statusLine.title = "Not reading the sensor"
            sensorItem.title = "Sensor: stopped"
            sensorIsHealthy = false
        case .running:
            let field = monitor.fieldDescription ?? "-"
            let source = monitor.cadence.rawValue
            statusLine.title = "Reading via \(source) — \(field)"
            sensorItem.title = "Sensor: OK"
            sensorIsHealthy = true
        case .degraded(let reason):
            statusLine.title = reason
            sensorItem.title = "Sensor: problem"
            sensorIsHealthy = false
        }
        updateStatusIcon()
    }

    /// The selected style cannot run - almost always a missing Screen Recording
    /// permission, which macOS grants per binary, so switching between a debug
    /// build and the app bundle triggers it.
    private func reportStyleUnavailable(_ message: String) {
        sensorItem.title = "Sensor: OK — \(settings.foldStyle.localizedName) unavailable"
        guard !reportedStyleFailure else { return }
        reportedStyleFailure = true

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(settings.foldStyle.localizedName) cannot run"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Use Blur Instead")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        case .alertSecondButtonReturn:
            settings.foldStyle = .blur
            updateStyleTitle()
            controller.wake()
        default:
            break
        }
    }

    private func presentStartupFailure(_ error: Error) {
        statusLine.title = "Could not open the sensor"
        sensorItem.title = "Sensor: unavailable"
        sensorIsHealthy = false
        updateStatusIcon()
        // Make sure the .accessory app's alert does not end up behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Cannot read the lid angle sensor"
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Actions

    /// The icon is the only thing the app says without being opened, so it
    /// carries the two states worth knowing at a glance: the effect switched
    /// off, and a sensor that cannot be read.
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let name: String
        let label: String
        if !sensorIsHealthy {
            name = "laptopcomputer.trianglebadge.exclamationmark"
            label = "Lid angle sensor unavailable"
        } else if !settings.isEnabled {
            name = "laptopcomputer.slash"
            label = "Fold effect off"
        } else {
            name = "laptopcomputer"
            label = "Fold effect on"
        }
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: label) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "◐"
        }
        button.toolTip = label
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
        enableItem.state = settings.isEnabled ? .on : .off
        updateStatusIcon()
        // The frame loop idles when nothing moves, so every settings change has
        // to wake it or the effect would not update until the lid next moves.
        controller.wake()
    }

    @objc private func selectThreshold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        settings.threshold = value
        updateThresholdTitle()
        controller.wake()
    }

    @objc private func screensChanged() {
        controller.rebuildOverlay()
        controller.wake()
    }

    @objc private func didWake() {
        controller.resetSmoothing()   // also wakes the frame loop
        monitor.reconnect()
        controller.rebuildOverlay()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
