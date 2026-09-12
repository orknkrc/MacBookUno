import AppKit
import LidAngleKit

/// Maps the lid angle to fold progress and drives the overlay window.
///
/// Timing: the sensor updates at ~10 Hz while the display runs at 60 Hz. The
/// monitor polls in the background at 30 Hz; the 60 Hz frame loop here advances
/// the smoother on every frame, so the 10 Hz steps dissolve across the frames in
/// between and the sweep looks continuous.
final class FoldController {

    private let monitor: LidAngleMonitor
    private var smoother = AngleSmoother(timeConstant: 0.12, snapThreshold: 45)
    private var overlay: FoldOverlayWindow?
    private var frameTimer: Timer?
    private var lastIngested: Double?

    /// How long everything must stay settled before the frame loop stops.
    private static let idleDelay: TimeInterval = 0.5
    /// Below this gap the smoothed value has caught up with the target.
    private static let settledEpsilon = 0.02

    private var lastMotionTime: TimeInterval = 0

    let settings: Settings

    /// For updating the UI (menu): (raw angle, smoothed angle, progress)
    var onUpdate: ((Double?, Double?, Double) -> Void)?

    /// Raised when the selected style cannot run, with a message for the user.
    var onStyleUnavailable: ((String) -> Void)?

    private(set) var currentProgress: Double = 0

    /// For testing: use a fixed angle instead of the sensor.
    var simulatedAngle: Double?
    /// For testing: sweep the angle back and forth across this range.
    var sweepRange: ClosedRange<Double>?
    private var sweepStart: TimeInterval?

    init(settings: Settings, monitor: LidAngleMonitor) {
        self.settings = settings
        self.monitor = monitor
    }

    // MARK: - Screen selection

    /// Internal display only. The lid angle has nothing to do with an external monitor.
    static var internalScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }
    }

    // MARK: - Lifecycle

    func start() {
        rebuildOverlay()
        // The monitor tells us when the lid actually moves, so nothing here has
        // to poll for it.
        monitor.onMotion = { [weak self] _ in self?.wake() }
        wake()
    }

    /// Starts the frame loop, or keeps it alive if it is already running.
    ///
    /// Call this whenever something that affects the effect changes: lid motion,
    /// a settings change, a screen change, waking from sleep. Missing a call
    /// means the effect silently stops updating, so it is wired defensively.
    func wake() {
        lastMotionTime = ProcessInfo.processInfo.systemUptime
        guard frameTimer == nil else { return }
        // .common mode: keep frames flowing even while a menu is open.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    func stop() {
        monitor.onMotion = nil
        frameTimer?.invalidate()
        frameTimer = nil
        overlay?.teardown()
        overlay?.close()
        overlay = nil
    }

    func rebuildOverlay() {
        guard let screen = FoldController.internalScreen else {
            // No internal display: clamshell with an external monitor, or a
            // desktop Mac. The window is torn down and forgotten, not merely
            // hidden - a hidden one was still reachable, and the very next tick
            // handed it a fold of 1 and ordered it front again, which put the
            // effect on the external display at the internal screen's stale
            // coordinates. The lid angle has nothing to do with that monitor.
            overlay?.teardown()
            overlay?.close()
            overlay = nil
            return
        }
        if let overlay {
            overlay.reposition(on: screen)
        } else {
            let window = FoldOverlayWindow(screen: screen)
            window.onStyleUnavailable = { [weak self] message in
                self?.onStyleUnavailable?(message)
            }
            overlay = window
        }
    }

    /// After waking from sleep: do not ease slowly toward a stale angle.
    func resetSmoothing() {
        smoother.reset()
        lastIngested = nil
        wake()
    }

    // MARK: - Frame loop

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let raw = resolveAngle(now: now)

        // Feed a sample only when it changes rather than re-feeding the same one;
        // on the frames in between just advance time.
        if let raw, raw != lastIngested {
            lastIngested = raw
            smoother.ingest(raw, now: now)
        } else {
            smoother.advance(to: now)
        }

        let smoothed = smoother.value
        let progress: Double
        if !settings.isEnabled {
            progress = 0
        } else if let smoothed {
            progress = FoldController.foldProgress(angle: smoothed, threshold: settings.threshold)
        } else {
            progress = 0
        }

        currentProgress = progress
        overlay?.apply(progress: progress,
                       direction: settings.sweepDirection,
                       style: settings.foldStyle)
        onUpdate?(raw, smoothed, progress)

        // Stop the loop once nothing is changing. Recomputing an identical mask
        // 60 times a second keeps the CPU out of its deep idle states for no
        // visible benefit; `wake()` brings it straight back.
        if shouldIdle(now: now, raw: raw, smoothed: smoothed) {
            frameTimer?.invalidate()
            frameTimer = nil
        }
    }

    private func shouldIdle(now: TimeInterval, raw: Double?, smoothed: Double?) -> Bool {
        // The sweep drives the angle itself, so it must never be put to sleep.
        guard sweepRange == nil else { return false }
        guard now - lastMotionTime >= FoldController.idleDelay else { return false }
        guard let raw, let smoothed else { return true }
        return abs(raw - smoothed) < FoldController.settledEpsilon
    }

    private func resolveAngle(now: TimeInterval) -> Double? {
        if let sweepRange {
            let start = sweepStart ?? { sweepStart = now; return now }()
            // 6-second triangle wave: close, then open.
            let period = 6.0
            let phase = (now - start).truncatingRemainder(dividingBy: period) / period
            let t = phase < 0.5 ? phase * 2 : (1 - phase) * 2
            return sweepRange.upperBound + (sweepRange.lowerBound - sweepRange.upperBound) * t
        }
        if let simulatedAngle { return simulatedAngle }
        return monitor.latestAngle
    }

    // MARK: - Mapping

    /// Angle -> fold progress.
    ///
    /// Deliberately linear: the frosted boundary has to track the hinge angle
    /// directly so the effect feels tied to the hardware. The softness of the
    /// transition already comes from the gradient band (see `FoldMask.softness`),
    /// so no extra easing curve is needed - with one, the boundary would drift
    /// ahead of or behind the lid instead of moving with it.
    static func foldProgress(angle: Double, threshold: Double) -> Double {
        guard threshold > 0 else { return 0 }
        return min(max((threshold - angle) / threshold, 0), 1)
    }
}
