# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
