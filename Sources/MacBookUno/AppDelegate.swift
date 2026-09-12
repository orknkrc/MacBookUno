import AppKit
import LidAngleKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let settings = Settings()
    private let monitor = LidAngleMonitor(preference: .bestResolution, pollHz: 30)
    private var controller: FoldController!

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let angleItem = NSMenuItem(title: "Angle: —", action: nil, keyEquivalent: "")
    private let foldItem = NSMenuItem(title: "Fold: —", action: nil, keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "Status: starting…", action: nil, keyEquivalent: "")
    private let enableItem = NSMenuItem(title: "Effect Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let thresholdItem = NSMenuItem(title: "Threshold Angle", action: nil, keyEquivalent: "")
    private let directionItem = NSMenuItem(title: "Sweep Direction", action: nil, keyEquivalent: "")
    private let styleItem = NSMenuItem(title: "Animation Style", action: nil, keyEquivalent: "")
    private let previewItem = NSMenuItem(title: "Preview", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
    private let previewView = FoldPreviewView()

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
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Lid fold effect") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "◐"
            }
        }

        angleItem.isEnabled = false
        foldItem.isEnabled = false
        statusLine.isEnabled = false

        menu.delegate = self
        menu.addItem(angleItem)
        menu.addItem(foldItem)
        menu.addItem(.separator())

        enableItem.target = self
        enableItem.state = settings.isEnabled ? .on : .off
        menu.addItem(enableItem)

        thresholdItem.submenu = buildThresholdMenu()
        menu.addItem(thresholdItem)

        styleItem.submenu = buildStyleMenu()
        menu.addItem(styleItem)

        directionItem.submenu = buildDirectionMenu()
        menu.addItem(directionItem)

        previewItem.submenu = buildPreviewMenu()
        menu.addItem(previewItem)

        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateThresholdTitle()
        updateDirectionTitle()
        updateStyleTitle()
        // Reflect --simulate, so the slider and the sensor never disagree about
        // which angle the effect is being driven from.
        previewView.show(angle: controller.simulatedAngle)
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
        case .unavailable:
            loginItem.title = "Open at Login — needs the app bundle"
            loginItem.state = .off
            loginItem.isEnabled = false
        }
    }

    /// The preview: a slider that feeds the controller a pretend angle.
    private func buildPreviewMenu() -> NSMenu {
        let submenu = NSMenu()

        previewView.onAngle = { [weak self] angle in
            guard let self else { return }
            self.controller.simulatedAngle = angle
            self.updatePreviewTitle()
            // The frame loop idles once nothing is moving, and dragging the
            // slider is exactly the case it cannot see coming.
            self.controller.wake()
        }

        let holder = NSMenuItem()
        holder.view = previewView
        submenu.addItem(holder)

        submenu.addItem(.separator())
        let follow = NSMenuItem(title: "Follow the Lid",
                                action: #selector(stopPreview), keyEquivalent: "")
        follow.target = self
        submenu.addItem(follow)
        return submenu
    }

    @objc private func stopPreview() {
        controller.simulatedAngle = nil
        previewView.show(angle: nil)
        updatePreviewTitle()
        controller.wake()
    }

    private func updatePreviewTitle() {
        if let angle = controller?.simulatedAngle {
            previewItem.title = String(format: "Preview: %.0f°", angle)
        } else {
            previewItem.title = "Preview: Off"
        }
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
        styleItem.title = "Animation Style: \(settings.foldStyle.localizedName)"
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
        directionItem.title = "Sweep Direction: \(settings.sweepDirection.localizedName)"
        guard let submenu = directionItem.submenu else { return }
        for item in submenu.items {
            guard let raw = item.representedObject as? String else { continue }
            item.state = raw == settings.sweepDirection.rawValue ? .on : .off
        }
    }

    private func updateThresholdTitle() {
        thresholdItem.title = String(format: "Threshold Angle: %.0f°", settings.threshold)
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
        // The login item can be changed in System Settings behind our back, so
        // it is read fresh every time rather than cached.
        updateLoginTitle()
    }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    /// Updating text while the menu is closed is wasted work; we refresh only
    /// while it is open, throttled to 10 Hz (writing NSMenuItem titles at 60 Hz
    /// is pointless).
    private func refreshMenuIfVisible(raw: Double?, smoothed: Double?, intensity: Double) {
        guard menuIsOpen else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMenuRefresh >= 0.1 else { return }
        lastMenuRefresh = now

        if let raw, let smoothed {
            angleItem.title = String(format: "Angle: %.2f°  (smoothed %.2f°)", raw, smoothed)
        } else {
            angleItem.title = "Angle: — (no reading)"
        }
        foldItem.title = settings.isEnabled
            ? String(format: "Fold: %%%.0f", intensity * 100)
            : "Fold: off"
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
            statusLine.title = "Status: stopped"
        case .running:
            let field = monitor.fieldDescription ?? "-"
            let source = monitor.cadence.rawValue
            statusLine.title = "Status: reading via \(source) — \(field)"
        case .degraded(let reason):
            statusLine.title = "Status: problem — \(reason)"
        }
    }

    /// The selected style cannot run - almost always a missing Screen Recording
    /// permission, which macOS grants per binary, so switching between a debug
    /// build and the app bundle triggers it.
    private func reportStyleUnavailable(_ message: String) {
        statusLine.title = "Status: \(settings.foldStyle.localizedName) unavailable"
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
        statusLine.title = "Status: could not open the sensor"
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

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
        enableItem.state = settings.isEnabled ? .on : .off
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
