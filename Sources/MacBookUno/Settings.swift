import Foundation

/// User settings, stored in UserDefaults so they survive a restart.
struct Settings {
    private enum Key {
        static let enabled = "effectEnabled"
        static let threshold = "thresholdAngle"
        static let sweepDirection = "sweepDirection"
    }

    /// Threshold angle choices. The measured range on this Mac is 0-132 degrees,
    /// with normal use between 85-132; the 60 degree default never interferes.
    static let thresholdChoices: [Double] = [20, 30, 40, 50, 60, 70, 80, 90, 100, 120]
    static let defaultThreshold: Double = 60

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.enabled: true,
            Key.threshold: Settings.defaultThreshold,
            Key.sweepDirection: SweepDirection.fromTop.rawValue,
        ])
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.enabled) }
    }

    var threshold: Double {
        get {
            let value = defaults.double(forKey: Key.threshold)
            return value > 0 ? value : Settings.defaultThreshold
        }
        nonmutating set { defaults.set(newValue, forKey: Key.threshold) }
    }

    /// Which edge the frosted region sweeps in from.
    var sweepDirection: SweepDirection {
        get {
            guard let raw = defaults.string(forKey: Key.sweepDirection),
                  let value = SweepDirection(rawValue: raw) else { return .fromTop }
            return value
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.sweepDirection) }
    }
}
