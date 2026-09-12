# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Fold Plane style.** The desktop keeps its own angle on a `CATransform3D`
  plane while the panel turns around it, which is how the reference animation
  behaves. Chosen from the new Animation Style menu; Frosted Glass remains the
  default and still asks for no permissions.
  - The plane shows a live `ScreenCaptureKit` stream, measured at ~48 fps. A
    single screenshot was tried first and is unusable: the effect begins while
    the lid is still at a working angle, so a frozen frame leaves you looking at
    a photograph of your desktop while clicks pass through to the real thing.
  - Blur strength ramps across the plane via `CIMaskedVariableBlur`, matching
    the ramp the Frosted Glass style already had.
  - The plane's own outline is feathered through the same variable blur as its
    contents, so an edge is exactly as soft as the picture beside it: the hinge
    end stays crisp where nothing is blurred, and only the far end dissolves. A
    uniform feather was tried first and rounds off the hinge corners, which are
    the part of the panel still facing the viewer squarely. The hinge edge is excluded, since fading it
    would leave a dark band across the bottom of the screen.
  - The void is cut to the plane's outline rather than filled flat, so the dark
    descends with the fold. Measured in ten bands, the top band goes 37.3 to
    10.0 as the fold runs 0 to 50% while the bottom band stays within 3.5 of
    untouched. A vertical gradient was tried first and leaves the side margins
    transparent, where the real desktop beside the leaning copy of itself reads
    as a double image. The hole stops where the plane's alpha actually
    reaches 1, which now tapers with the feather: its bottom corners sit on the
    plane's true corners and only the far ones are pulled in. Cut any wider and
    a half-transparent band is left with no dark behind it, and the real screen
    shows through it.
  - If Screen Recording is unavailable the app says why and offers to open
    System Settings or switch to Frosted Glass, rather than showing nothing.
- `--style blur|plane` to pick a style for one run, and `--capture-test <path>`
  to grab a single frame and exit, which separates a permission problem from a
  rendering one.
- `Scripts/make-app.sh` signs with a real code signing identity when one exists,
  using `CODESIGN_IDENTITY` or the first identity it finds, and falls back to
  ad-hoc with a warning. macOS keys the Screen Recording grant to the code
  signature, and an ad-hoc signature changes on every rebuild.

### Changed

- Minimum macOS is now **14**, for `SCScreenshotManager`. The Frosted Glass
  style alone would still run on macOS 13.

### Notes

Three things measured while building this, all of which shaped the design:

- `CALayer.backgroundFilters` does nothing on a modern compositor. It would have
  blurred the desktop directly with no capture and no permission; the filter is
  retained and never applied.
- `CALayer.mask` and `CALayer.filters` are mutually exclusive — a layer with
  both silently drops the filter, whether the mask is on the layer or on an
  ancestor. Hence Core Image for the variable blur.
- AppKit pins a view-backed layer's `anchorPoint` to (0, 0), so a
  `sublayerTransform` carrying perspective shears the plane into a parallelogram.
  The perspective sits on a plain intermediate layer whose anchor is the middle,
  which also stops the void being depth-sorted in front of the leaning plane.
- `CALayer.filters` operate in the layer's bounds **in points**, not in pixels
  and not at the size of the content assigned to it. A mask built at the
  captured surface's size overhangs the layer, which showed up as an edge fade
  on one side of the plane only and a blur ramp that never reached full
  strength.
- Core Image filters run in a **linear** colour space. A CIColorControls pass
  meant to sell the glass look - contrast 0.98, brightness +0.02 - pivoted dark
  pixels about linear 0.5 and lifted the entire screen by a measured +15/255 as
  soon as the effect began. Only the saturation boost survives; it is a ratio
  about the pixel's own luma and does not touch brightness.

The plane costs about **3.5% CPU** while on screen, against 0.2% idle. It only
runs below the threshold angle.

## [0.2.0] - 2026-09-12

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

- Unit tests for the descriptor parser and the angle smoother. They run against
  a report descriptor recorded from real hardware, so no sensor is needed.
- GitHub Actions CI: builds, tests, packages the app and fails if the bundle
  ever picks up a sandbox entitlement.
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

[Unreleased]: https://github.com/orknkrc/MacBookUno/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/orknkrc/MacBookUno/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/orknkrc/MacBookUno/releases/tag/v0.1.0
