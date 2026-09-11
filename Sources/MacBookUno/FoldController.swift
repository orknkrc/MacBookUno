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

    let settings: Settings

    /// For updating the UI (menu): (raw angle, smoothed angle, progress)
    var onUpdate: ((Double?, Double?, Double) -> Void)?

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
        // .common mode: keep frames flowing even while a menu is open.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    func stop() {
        frameTimer?.invalidate()
        frameTimer = nil
        overlay?.hideOverlay()
        overlay?.close()
        overlay = nil
    }

    func rebuildOverlay() {
        guard let screen = FoldController.internalScreen else {
            // No internal display (clamshell with an external monitor, or a desktop Mac).
            overlay?.hideOverlay()
            return
        }
        if let overlay {
            overlay.reposition(on: screen)
        } else {
            overlay = FoldOverlayWindow(screen: screen)
        }
    }

    /// After waking from sleep: do not ease slowly toward a stale angle.
    func resetSmoothing() {
        smoother.reset()
        lastIngested = nil
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
        overlay?.apply(progress: progress, direction: settings.sweepDirection)
        onUpdate?(raw, smoothed, progress)
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
