# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- A failed screen capture no longer retries sixty times a second. A failure left
  the stream neither running nor starting, which is indistinguishable from "not
  started", so the frame loop asked again on every frame and spawned an
  `SCShareableContent` query each time. There is now a three second cooldown
  after a failure, cleared when the fold ends so the next one gets a fresh try.
- The alert explaining that a style cannot run is shown again after the user
  picks a style or switches the effect back on. It was suppressed for the rest
  of the session after the first time, which also took away the "Open Settings"
  button that was the way out of it.
- `Open at Login` can be switched off while macOS is still waiting for approval.
  That state means the app *is* registered, but it was treated as "not on", so
  the click tried to register a second time, failed, and left no way to turn the
  item off.
- The Fold Plane's blur mask is rebuilt when the panel changes size. It was
  cached against the fold alone, so a resolution change - or the window
  following the display to another one - at an unchanged angle reused a mask
  built for the old dimensions.


## [0.4.1] - 2026-09-12

### Fixed

- The screen capture no longer outlives a fold that reverses quickly. The stop
  was guarded on `feed.isRunning`, which only turns true once the asynchronous
  set-up finishes, so a fold that started and reversed inside that window
  skipped the stop entirely; the set-up then adopted the stream and it captured
  for the rest of the session. `stop()` already handled both cases, so the guard
  was removed. This is the same defect as the one fixed in 0.4.0, in a second
  place that was missed.
- The effect no longer reappears on an external display in clamshell mode. With
  no internal display the overlay was hidden but kept, and the very next frame
  handed it a fold of 1 and ordered it front again, at the internal screen's
  stale coordinates. It is now torn down and forgotten, which also stops the
  capture that hiding alone left running.
- Waking from sleep no longer flashes a full fold. `reconnect()` cleared the
  notification marker but not the last angle, so the first frame after waking
  was driven by the few-degree reading left behind when the lid shut. Verified
  on hardware: the angle now reads nil between the reconnect and the first fresh
  sample, rather than 132.03 degrees.
- The preview slider's caption keeps up with the knob. It only updated when the
  menu was reopened, so the label read "Drag to preview" throughout a drag. The
  caption cannot simply be refreshed from the change handler - that writes the
  slider's value back and snaps the knob to whole degrees under the hand
  dragging it - so the view formats it directly.

Found by an external audit of the whole repository.

## [0.4.0] - 2026-09-12

### Added

- **Preview slider** in the menu. It feeds the effect a pretend angle, so the
  fold can be watched at 40 degrees with the lid wide open and the screen
  readable. Tuning previously meant moving the lid, which cannot be done while
  looking at the screen, or relaunching with `--simulate`.
- A preview ends by itself ten seconds after the menu closes, easing the angle
  back to the lid's own rather than cutting to it. The overlay sits above the
  menu bar, so a deep preview hides the status item that would cancel it - not
  hard to find, invisible - which made a left-running preview a way to lock
  yourself out of the app. The clock runs only while the menu is shut, since a
  countdown with the slider in view would just snatch the effect away
  mid-inspection. The easing matters too: the lid is usually far enough from the
  previewed angle that dropping it outright lands past the smoother's snap
  threshold and arrives in a single frame.
- **Open at Login**, via `SMAppService`. It needs no helper target and no extra
  entitlement. Running outside an app bundle and the user declining it in
  System Settings are both reported rather than shown as a tick that does
  nothing.
- The far end of the Fold Plane is **shaded down**, by up to half its brightness
  at full fold. A surface turning away from the light gets darker, and after the
  perspective this is the strongest depth cue there is; without it the plane
  reads as a blurred picture lying flat. It is a multiply against the same
  gradient the blur uses, not the brightness control that caused the earlier
  white haze - multiplying is a ratio and cannot lift a dark pixel, so the
  linear working space costs nothing.

### Changed

- The menu is reordered around what you came to do: the effect's switch first,
  then the preview slider, then the settings, and the live readings last, in a
  `Sensor` submenu. The angle and fold rows used to occupy the first two lines,
  where the eye lands, despite being the one thing in the menu nobody acts on.
- The preview slider moved out of its submenu and into the menu itself. It is
  the most-handled control there and was two clicks away; nudging it by accident
  is survivable now that a preview releases itself.
- The menu bar icon carries state: a slash through it when the effect is off, a
  warning badge when the sensor cannot be read. It is the only thing the app
  says without being opened.
- Shorter titles - `Threshold`, `Style`, `Sweep`, and `From the top` in place of
  `From top, downward` - and the Frosted Glass style is named that in the menu
  rather than `Blur`, matching the documentation. `Angle` also appeared in two
  unrelated rows.
- `Open at Login` is no longer greyed out when `SMAppService` reports
  `notFound`. That is what a stock build gets wherever the bundle lives -
  measured from the build directory, from `~/Applications` and from a temporary
  directory - and the cause is not something the app can establish; a
  self-signed bundle carrying no Team ID is the likeliest reason, but it is a
  guess. The row now offers itself, and shows whatever macOS says if it refuses.
  It previously claimed the app needed to be run from a bundle, which was simply
  wrong.
- The version is shown in the menu, not only behind `--version`.

### Fixed

- The real screen no longer shows through the Fold Plane, sharp beside the
  leaning blurred copy of itself. The void was cut with a straight line from the
  hinge corner to the far corner, but the plane's border softness follows the
  blur ramp, and where that ramp ran ahead of the line the plane was half
  transparent with nothing behind it. The void now samples the same ramp along
  its whole length, and reaches 2.5 feather widths in rather than 1.5 - the
  distance the variable blur actually needs before the plane is opaque, which
  had been guessed rather than measured.

  The leak moved as the lid closed, from the top of the screen at a quarter fold
  to the bottom at nine tenths, because the ramp's knee travels towards the
  hinge. That is what made one fault look like several. Measured by tinting the
  three layers apart - plane red, void blue, so any green pixel is provably the
  real screen:

  | Fold | Before | After |
  | --- | --- | --- |
  | 12% | 0.004% | 0.004% |
  | 25% | 0.007% | 0.000% |
  | 50% | 0.024% | 0.000% |
  | 75% | 0.053% | 0.000% |
  | 90% | 0.127% | 0.000% |

- The screen no longer snaps into focus when the effect ends. The plane can
  never be as sharp as the screen it is copying - any transform puts the
  captured pixels through bilinear resampling and breaks their alignment with
  the display grid - and that softness does not fall away as the fold does:
  measured on a static region, the plane was still 12% softer than the real
  screen at a fold of 0.002, where the lean is a twentieth of a degree and every
  filter is already off. There is therefore no angle at which the plane can be
  removed cleanly, so it is dissolved instead, over the first 8% of the fold.
  The step at the cut-off went from 11.9% to 0.5%.
- The screen capture is stopped when the effect ends. `FoldOverlayWindow.apply`
  returned before reaching the renderer once the fold hit zero, so the Fold
  Plane was never told the effect was over and kept capturing for the rest of
  the session, with the screen-recording indicator lit.
- Only one capture is started per fold. `DisplayStream.start` guarded on its
  `stream` property, which is assigned only after the asynchronous set-up
  finishes, so the frame loop created a fresh `SCStream` on every frame until
  the first one came up - five live captures for one fold, four of them
  orphaned: never stopped, and still delivering frames into the same handler.
- The angle and fold readings no longer sit stale while the menu is open. They
  are refreshed from the frame loop, and that loop idles while the lid is still,
  so opening the menu now wakes it.

## [0.3.0] - 2026-09-12

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
    the part of the panel still facing the viewer squarely.
  - The void is cut to the plane's outline rather than filled flat, so the dark
    descends with the fold instead of covering the screen the moment the effect
    starts. Measured in ten bands, the top band goes 37.3 to 10.0 as the fold
    runs 0 to 50% while the bottom band stays within 3.5 of untouched. A
    vertical gradient was tried first and leaves the side margins transparent,
    where the real desktop beside the leaning copy of itself reads as a double
    image.
  - That cut stops where the plane's alpha actually reaches 1, and tapers along
    with the feather: its bottom corners sit on the plane's true corners and
    only the far ones are pulled in. Cut any wider and a half-transparent band
    is left with no dark behind it, and the real screen shows through it.
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

- Minimum macOS is now **14**, for `SCScreenshotManager`, in `Package.swift`
  and in the bundle's `LSMinimumSystemVersion`. The Frosted Glass style alone
  would still run on macOS 13.

### Notes

Measured while building this, all of it load-bearing on the design:

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

[Unreleased]: https://github.com/orknkrc/MacBookUno/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/orknkrc/MacBookUno/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/orknkrc/MacBookUno/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/orknkrc/MacBookUno/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/orknkrc/MacBookUno/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/orknkrc/MacBookUno/releases/tag/v0.1.0
