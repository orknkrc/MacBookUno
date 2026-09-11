import Foundation

/// Turns raw angle samples into a signal suitable for animation.
///
/// Why this is needed: the sensor updates at roughly 10 Hz, and while the lid
/// closes at a normal speed consecutive samples differ by 2-3 degrees. Driving a
/// visual effect straight from that value produces a visible stair-step ten
/// times a second. Two stages handle it:
///
///  1. **Median-of-3 prefilter** - completely absorbs single-sample spikes
///     (sensor noise) while adding only one sample of latency to real motion.
///  2. **Exponential smoothing** - uses a time-based coefficient, so behavior
///     stays identical even when the call interval varies (a dropped frame, a
///     pause while a menu is open). It closes ~63% of the gap to the target in
///     `timeConstant` seconds.
public struct AngleSmoother {

    /// Smoothing time constant in seconds. Smaller = more responsive, larger = smoother.
    public var timeConstant: TimeInterval

    /// Changes larger than this are treated as real, large motion and followed
    /// immediately. After waking from sleep we want to catch a 130-degree jump
    /// at once rather than easing into it.
    public var snapThreshold: Double

    private var window: [Double] = []
    private var smoothed: Double?
    private var lastUpdate: TimeInterval?

    public init(timeConstant: TimeInterval = 0.12, snapThreshold: Double = 45) {
        self.timeConstant = timeConstant
        self.snapThreshold = snapThreshold
    }

    /// The current smoothed value (nil until the first sample).
    public var value: Double? { smoothed }

    /// Feeds a new raw sample and returns the smoothed value.
    /// - Parameter now: a monotonic clock (`ProcessInfo.systemUptime`).
    @discardableResult
    public mutating func ingest(_ raw: Double, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        window.append(raw)
        if window.count > 3 { window.removeFirst() }
        let target = AngleSmoother.median(window)

        guard let current = smoothed, let last = lastUpdate else {
            smoothed = target
            lastUpdate = now
            return target
        }

        let dt = max(0, now - last)
        lastUpdate = now

        if abs(target - current) >= snapThreshold {
            smoothed = target
            return target
        }

        // Time-based exponential coefficient: feels the same regardless of dt.
        let alpha = timeConstant <= 0 ? 1 : 1 - exp(-dt / timeConstant)
        let next = current + (target - current) * alpha
        smoothed = next
        return next
    }

    /// Advances time without a new sample (sensor at 10 Hz, display at 60 Hz:
    /// keeps easing toward the target on the frames in between).
    @discardableResult
    public mutating func advance(to now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        guard let current = smoothed, let last = lastUpdate, !window.isEmpty else { return smoothed }
        let target = AngleSmoother.median(window)
        let dt = max(0, now - last)
        lastUpdate = now
        let alpha = timeConstant <= 0 ? 1 : 1 - exp(-dt / timeConstant)
        let next = current + (target - current) * alpha
        smoothed = next
        return next
    }

    /// Clears all state (used after waking, so we do not ease from a stale value).
    public mutating func reset() {
        window.removeAll()
        smoothed = nil
        lastUpdate = nil
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
