import Foundation
import IOKit
import IOKit.hid

/// Watches the lid angle, polling fast while it moves and slowly while it does not.
///
/// Why polling and not the input report stream: measured on a `Mac17,9`, the
/// sensor does not publish a report when the angle changes. Opening the lid by
/// 12 degrees produced no report for 2.6 seconds, so an event-driven design
/// freezes exactly when it matters. The device only emits a low-rate heartbeat.
///
/// So the rate is adapted instead. While the lid is still, sampling a few times
/// a second is enough to notice that it started moving; once it is moving, the
/// full rate keeps the effect smooth. Worst-case latency at the start of a
/// movement is one idle interval, and at that point the lid is still far from
/// the threshold, so nothing is visible yet.
///
/// UI-independent: no AppKit here. The blocking IOKit reads happen on a
/// background queue.
public final class LidAngleMonitor {

    public enum State: Sendable {
        case stopped
        case running
        /// The device is temporarily unreadable (e.g. around sleep/wake).
        /// Reconnection is attempted automatically.
        case degraded(String)
    }

    /// How often the sensor is currently being sampled.
    public enum Cadence: String, Sendable {
        /// Slow sampling: the lid is not moving.
        case idle
        /// Full rate: the lid is moving.
        case active
    }

    private let queue = DispatchQueue(label: "LidAngleMonitor.poll", qos: .userInitiated)
    private let lock = NSLock()

    private var sensor: LidAngleSensor?
    private var timer: DispatchSourceTimer?
    private var _latestAngle: Double?
    private var _state: State = .stopped
    private var _cadence: Cadence = .active
    private var consecutiveFailures = 0
    private var lastMotion: TimeInterval = 0
    private var lastNotifiedAngle: Double?

    /// Interval between samples while the lid is moving.
    public let activeInterval: TimeInterval
    /// Interval between samples while the lid is still.
    public let idleInterval: TimeInterval
    /// How long the lid must be still before sampling slows down.
    private static let activeHold: TimeInterval = 1.0

    public let preference: LidAngleSensor.FieldPreference
    private let match: LidAngleMatch

    /// Called on the main queue when the state changes (for display in the menu).
    public var onStateChange: ((State) -> Void)?

    /// Called on the main queue when the lid actually moves.
    public var onMotion: ((Double) -> Void)?

    /// Movement smaller than this is sensor noise, not the lid moving.
    ///
    /// Measured: the centidegree field jitters by a few hundredths of a degree
    /// while the lid is held still. Without a deadband every sample would look
    /// like motion and the rate could never drop.
    public var motionDeadband: Double = 0.15

    public init(match: LidAngleMatch = LidAngleMatch(),
                preference: LidAngleSensor.FieldPreference = .bestResolution,
                pollHz: Double = 30,
                idleHz: Double = 5) {
        self.match = match
        self.preference = preference
        self.activeInterval = 1.0 / max(1, pollHz)
        self.idleInterval = 1.0 / max(0.5, min(idleHz, pollHz))
    }

    deinit {
        timer?.cancel()
        sensor?.close()
    }

    // MARK: - Published state

    /// The most recent raw angle. nil until the first successful read.
    public var latestAngle: Double? {
        withLock { _latestAngle }
    }

    public var state: State {
        withLock { _state }
    }

    /// Whether the sensor is currently sampled at the idle or the active rate.
    public var cadence: Cadence {
        withLock { _cadence }
    }

    /// Description of the selected field (for display in the UI).
    public var fieldDescription: String? {
        withLock {
            guard let field = sensor?.angleField else { return nil }
            return "Report ID \(field.reportID), \(field.bitSize) bit, step \(String(format: "%g", field.scale))°"
        }
    }

    // MARK: - Lifecycle

    public func start() throws {
        try queue.sync { try connectLocked() }
        // Start at the full rate so the first reading lands immediately; the
        // rate drops on its own once the lid proves to be still.
        setCadence(.active)
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            self.sensor?.close()
            self.sensor = nil
        }
        setState(.stopped)
        withLock { _latestAngle = nil; lastNotifiedAngle = nil }
    }

    /// After waking, the device handle may be stale; reconnect from scratch.
    public func reconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.sensor?.close()
            self.sensor = nil
            // The last angle goes too, not just the notification marker.
            //
            // Sleep is entered with the lid shut, so the reading left behind is
            // whatever it was at a few degrees. Keeping it means the first frame
            // after waking is driven by that stale value - a full fold flashed
            // across the screen before the first fresh sample arrived. A caller
            // that reads nil simply shows nothing until the sensor answers.
            self.withLock {
                self._latestAngle = nil
                self.lastNotifiedAngle = nil   // force a notification after reconnecting
            }
            try? self.connectLocked()
            self.setCadence(.active)
        }
    }

    // MARK: - Internals

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Must be called on `queue`.
    private func connectLocked() throws {
        let located = try LidAngleSensor.locate(preferred: match)
        let sensor = try LidAngleSensor(device: located.device, preference: preference)
        try sensor.open()
        withLock { self.sensor = sensor }
        consecutiveFailures = 0
        setState(.running)
    }

    private func setCadence(_ cadence: Cadence) {
        let interval = cadence == .active ? activeInterval : idleInterval
        withLock { _cadence = cadence }
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Fires immediately so a rate change takes effect at once rather than
        // after the previous interval would have elapsed.
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        guard let sensor = withLock({ self.sensor }) else {
            // No connection: retry roughly once a second.
            consecutiveFailures += 1
            let ticksPerSecond = max(1, Int((1.0 / currentInterval).rounded()))
            if consecutiveFailures % ticksPerSecond == 0 {
                try? connectLocked()
            }
            return
        }

        do {
            let reading = try sensor.readOnce()
            if consecutiveFailures > 0 {
                consecutiveFailures = 0
                setState(.running)
            }
            accept(angle: reading.angle)
        } catch {
            consecutiveFailures += 1
            // Occasional failures are normal (around sleep/wake); report only if
            // persistent, then drop the handle so the next tick reconnects.
            let perSecond = max(1, Int((1.0 / currentInterval).rounded()))
            if consecutiveFailures == perSecond / 3 + 1 {
                setState(.degraded("\(error)".split(separator: "\n").first.map(String.init) ?? "read error"))
            }
            if consecutiveFailures >= perSecond {
                withLock { self.sensor = nil }
                sensor.close()
            }
        }
    }

    private var currentInterval: TimeInterval {
        withLock { _cadence } == .active ? activeInterval : idleInterval
    }

    private func accept(angle: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let moved: Bool = withLock {
            _latestAngle = angle
            guard let last = lastNotifiedAngle else {
                lastNotifiedAngle = angle
                return true
            }
            guard abs(angle - last) >= motionDeadband else { return false }
            lastNotifiedAngle = angle
            return true
        }

        if moved {
            lastMotion = now
            if withLock({ _cadence }) == .idle { setCadence(.active) }
            if let onMotion { DispatchQueue.main.async { onMotion(angle) } }
        } else if withLock({ _cadence }) == .active,
                  now - lastMotion >= LidAngleMonitor.activeHold {
            setCadence(.idle)
        }
    }

    private func setState(_ newState: State) {
        withLock { _state = newState }
        guard let onStateChange else { return }
        DispatchQueue.main.async { onStateChange(newState) }
    }
}
