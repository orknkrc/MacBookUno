# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Performance

- The app is now idle while the lid is still. Measured CPU with the lid open and
  the effect invisible dropped from **1.2% to 0.2%**.
  - The 60 Hz frame loop stops once nothing is changing and is woken by lid
    motion, a settings change, a screen change, or waking from sleep.
  - The sensor is sampled a few times a second while the lid is still and at the
    full rate while it moves, switching on a 0.15 degree motion deadband. The
    deadband is needed because the centidegree field jitters by a few hundredths
    of a degree even when the lid is held still.
- Event-driven input reports were tried first and rejected on measurement: this
  sensor does not publish a report when the angle changes. Opening the lid by
  12 degrees produced no report for 2.6 seconds, which would freeze the effect
  exactly when it matters. `LidAngleSensor.startStreaming` is kept for
  `lidangle --stream` and for models where streaming may behave differently.

### Changed

- The blur is now a ramp spanning the whole panel instead of a bounded frosted
  region with a soft edge. Watching the reference animation showed the blur
  strength varies continuously across the surface — heaviest where it turns away
  from the viewer, fading to sharp where it still faces them.
- Heavier frost: a second `.withinWindow` effect view blurs the first pass's
  output, and a faint light wash sits over the ramp. `NSVisualEffectView` has no
  public blur-radius control, and a single pass left large shapes readable.
- Default sweep direction is now `fromTop`. On a closing lid the top edge is the
  part turning away from the viewer, which matches the reference.
- The overlay pins itself to the dark appearance, so the effect looks identical
  regardless of the user's system theme.

### Added

- `--appearance light|dark` debug flag for comparing the effect against either
  theme without changing the system setting.

### Fixed

- `lidangle` no longer traps on extreme `--bit-size` values. Computing the
  logical range in `Int` arithmetic overflowed for unsigned 63-bit and signed
  64-bit fields; both are now handled explicitly, and sizes outside 1...64 are
  rejected with a clear message.
- The dummy buffer handed to IOKit when clearing the input report callback is
  now per sensor instead of a shared static. A mutable global is not
  concurrency-safe and is an error under the Swift 6 language mode.
- `LidAngleMonitor` cancels its poll timer in `deinit`, so dropping a monitor
  without calling `stop()` no longer leaves the timer running.

### Changed

- The menu shows the selected sweep direction in its title, matching how the
  threshold angle is already displayed.
- `lidangle` reuses a single `ISO8601DateFormatter` rather than allocating one
  per reading.

## [0.1.0] - 2026-09-11

First working release.

### Added

- `LidAngleKit`: UI-independent lid angle sensor layer.
  - Hand-written HID report descriptor parser, so bit offsets are derived from
    the device instead of being hard-coded.
  - Device discovery with VID/PID + usage matching and a usage-only fallback,
    which reports back when the fallback was used.
  - Three read paths: synchronous `GetReport`, input report streaming, and
    `IOHIDDeviceGetValue`.
  - Automatic selection between the whole-degree field (Report ID 1) and the
    centidegree field (Report ID 7).
  - Median-of-3 plus time-based exponential smoothing.
  - Background polling monitor with reconnect on sleep/wake.
- `MacBookUno`: menu bar app with the lid fold effect.
  - Frosted region swept across the internal display via
    `NSVisualEffectView.maskImage`, tracking the hinge angle linearly.
  - Faint highlight along the leading edge of the frosted region.
  - Borderless, click-through, all-Spaces overlay below pop-up menu level.
  - Menu: enable/disable, threshold angle, sweep direction, live angle and
    fold amount, sensor status.
  - Settings persisted in `UserDefaults`.
  - Debug flags: `--simulate`, `--sweep`, `--log`, `--pattern`.
- `lidangle`: sensor inspection CLI with `--probe`, `--descriptor`, `--list`,
  `--debug`, manual field overrides and `--fine`/`--coarse` field selection.
- `Scripts/make-app.sh`: builds an ad-hoc signed `MacBookUno.app` with no
  sandbox entitlements.
- `--version` on both executables, sourced from `ProjectVersion`.

### Notes

- Verified on `Mac17,9` running macOS 26.6. The sensor is exposed as HID
  vendor `0x05AC`, product `0x8104`, usage page `0x0020`, usage `0x008A`.
- The angle arrives as an **input** report, not a feature report as commonly
  reported elsewhere; the device declares no feature items at all.
- `NSVisualEffectView.maskImage` is consumed in pixels and top-aligned rather
  than stretched to the view; the mask is built at
  `bounds.height * backingScaleFactor` to compensate.

[Unreleased]: https://github.com/orknkrc/MacBookUno/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/orknkrc/MacBookUno/releases/tag/v0.1.0
