import Foundation
import IOKit
import IOKit.hid

/// Continuously polls the sensor in the background and exposes the latest angle
/// in a thread-safe way.
///
/// UI-independent: no AppKit here either. Reads happen on a background queue so
/// the main thread never blocks on synchronous IOKit calls.
public final class LidAngleMonitor {

    public enum State: Sendable {
        case stopped
        case running
        /// The device is temporarily unreadable (e.g. around sleep/wake).
        /// Reconnection is attempted automatically.
        case degraded(String)
    }

    private let queue = DispatchQueue(label: "LidAngleMonitor.poll", qos: .userInitiated)
    private let lock = NSLock()

    private var sensor: LidAngleSensor?
    private var timer: DispatchSourceTimer?
    private var _latestAngle: Double?
    private var _state: State = .stopped
    private var consecutiveFailures = 0

    public let pollInterval: TimeInterval
    public let preference: LidAngleSensor.FieldPreference
    private let match: LidAngleMatch

    /// Called on the main queue when the state changes (for display in the menu).
    public var onStateChange: ((State) -> Void)?

    public init(match: LidAngleMatch = LidAngleMatch(),
                preference: LidAngleSensor.FieldPreference = .bestResolution,
                pollHz: Double = 30) {
        self.match = match
        self.preference = preference
        self.pollInterval = 1.0 / max(1, pollHz)
    }

    /// The most recent raw angle. nil until the first successful read.
    public var latestAngle: Double? {
        lock.lock(); defer { lock.unlock() }
        return _latestAngle
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// Description of the selected field (for display in the UI).
    public var fieldDescription: String? {
        lock.lock(); defer { lock.unlock() }
        guard let field = sensor?.angleField else { return nil }
        return "Report ID \(field.reportID), \(field.bitSize) bit, step \(String(format: "%g", field.scale))°"
    }

    // MARK: - Lifecycle

    public func start() throws {
        try queue.sync {
            try connectLocked()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            sensor?.close()
            sensor = nil
        }
        setState(.stopped)
        lock.lock(); _latestAngle = nil; lock.unlock()
    }

    /// After waking, the device handle may be stale; reconnect from scratch.
    public func reconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.sensor?.close()
            self.sensor = nil
            try? self.connectLocked()
        }
    }

    // MARK: - Internals

    /// Must be called on `queue`.
    private func connectLocked() throws {
        let located = try LidAngleSensor.locate(preferred: match)
        let sensor = try LidAngleSensor(device: located.device, preference: preference)
        try sensor.open()
        self.sensor = sensor
        consecutiveFailures = 0
        setState(.running)
    }

    private func tick() {
        guard let sensor else {
            // No connection: try to reconnect roughly once a second.
            consecutiveFailures += 1
            if consecutiveFailures % Int(1.0 / pollInterval) == 0 {
                try? connectLocked()
            }
            return
        }

        do {
            let reading = try sensor.readOnce()
            lock.lock(); _latestAngle = reading.angle; lock.unlock()
            if consecutiveFailures > 0 {
                consecutiveFailures = 0
                setState(.running)
            }
        } catch {
            consecutiveFailures += 1
            // Occasional failures are normal (around sleep/wake); report only if persistent, then reconnect.
            if consecutiveFailures == 10 {
                setState(.degraded("\(error)".split(separator: "\n").first.map(String.init) ?? "read error"))
            }
            if consecutiveFailures >= 30 {
                self.sensor?.close()
                self.sensor = nil
            }
        }
    }

    private func setState(_ newState: State) {
        lock.lock(); _state = newState; lock.unlock()
        if let onStateChange {
            DispatchQueue.main.async { onStateChange(newState) }
        }
    }
}
