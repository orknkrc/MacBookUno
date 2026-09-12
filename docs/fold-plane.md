# The Fold Plane, in detail

Notes on how the Fold Plane style is built, and on the things that had to be
measured before it worked. The [README](../README.md) has the short version.

Everything below was verified on a `Mac17,9` running macOS 26.6, 1512 × 982
points at 2×. The numbers are from that machine; the behaviours are not
machine-specific.

---

## Why it has to capture the screen

The Frosted Glass style can only ever be a filter laid over the display. The
reference animation is not a filter: the content appears to **hold its own
angle** while the panel rotates around it. An overlay cannot do that, because it
cannot reshape what is behind it — so the content has to be drawn again, on a
surface we control.

`CALayer.backgroundFilters` would have been the way out, filtering the desktop
directly with no capture and no permission. It does nothing on a modern
compositor. The filter is retained and never applied; this was measured, not
assumed, and it is why the permission-free style can only mask.

The feed is a live `SCStream`, not a screenshot. A frozen frame was tried first
and is unusable: the effect begins while the lid is still at a working angle, so
a still image leaves you looking at a photograph of your desktop while clicks
pass through to the real thing underneath. Measured ~48 fps.

## Geometry

`CATransform3D` supplies the perspective (`m34 = -1/1400`) and the plane leans
back up to 55°. A full 90° would turn it edge-on and hide it, and the reference
keeps the content readable throughout.

Two layer-tree findings shaped this:

- **AppKit pins a view-backed layer's `anchorPoint` to (0, 0).** A
  `sublayerTransform` carrying perspective is applied about that anchor, so it
  projects from the bottom-left corner and shears the plane into a parallelogram
  instead of a keystone.
- **A backdrop layer at z = 0 sorts in front of a plane leaning away.** Core
  Animation depth-sorts siblings, and the plane's z goes negative as it leans,
  so a sibling backdrop blacks out the screen completely.

Both are solved by the same structure: the perspective lives on a plain
intermediate layer whose anchor is the middle, and the plane sits inside it. The
projection is then already centred, and the plane's z exists only within that
layer, so the void can be a real sibling rather than a colour painted on the
container's background.

## The blur ramp

Blur strength varies across the panel, heaviest where the surface turns away.
`CALayer.mask` would be the obvious way to shape that and cannot be used:

> **`CALayer.mask` and `CALayer.filters` are mutually exclusive.** A layer
> carrying both silently drops the filter, whether the mask sits on the layer
> itself or on an ancestor.

So the ramp is Core Image's `CIMaskedVariableBlur`, whose radius follows a
`CILinearGradient` mask. That gradient is the spine of the whole style — the
blur, the border softness, the shading and the void are all driven from it, so
they arrive together and cannot drift apart.

The blur is bracketed by `CIAffineClamp` and `CICrop` in the Frosted Glass
lineage; in the plane it is deliberately left unbounded, so the edges fade out
instead of stopping on a line.

### Masks are built in points

Both Core Image masks are built in the layer's **bounds, in points** — not
pixels, and not the size of the captured surface.

Getting this wrong is not obvious from the result. A mask built at capture size
(3024 × 1964 against a plane 1421 points wide) overhangs the layer: its near
edge lands inside and its far edge falls outside entirely. The symptom was an
edge fade on one side of the plane and not the other, plus a blur ramp that
never reached full strength.

What pinned it down: widening the fade from 110 to 280 moved the left edge by
eight measured column buckets and left the right edge identical to two decimal
places. A one-sided response to a symmetric change can only mean the coordinate
space is wrong.

## The soft border

Blurring the contents is only half of it. The rectangle they sit in still ends
on a hard line, so a blurred desktop reads as a sharp-edged cutout pasted onto
the void. A second Core Image pass fades the plane's alpha along its border — a
white rectangle the size of the plane, used as an alpha mask through
`CISourceInCompositing`.

That rectangle goes through the **same variable blur as the contents, driven by
the same gradient**, so an edge is exactly as soft as the picture beside it. A
uniform feather was tried first and is wrong in a way that is obvious once you
look for it: it rounds off the hinge end, which is the part of the panel still
facing the viewer squarely and the part that is not blurred at all.

The rectangle is at the plane's true size rather than inset, so at the hinge the
edge lands on the physical border of the screen, where a hard edge cannot be
seen. The margin the fade needs higher up is supplied by the keystone, which
widens with the fold — 185 points per side at half fold against a 60 point
feather.

## The void

The dark around the fold is cut to the plane's own outline rather than filled
flat, so it arrives in step with the fold instead of covering the screen the
moment the effect starts.

A vertical gradient was tried first and is not enough: it darkens the top
correctly but leaves the side margins transparent, and the real desktop showing
beside the leaning copy of itself reads as a double image.

The hole has to stop where the plane becomes **genuinely opaque**, or the real
screen shows through the half-transparent band. Two numbers control that, and
both were earned rather than guessed:

- It is inset by the *local* softness at every height, sampled from the same
  ramp — not by a straight line from the hinge corner to the far corner. The
  border's width follows the ramp while a straight line rises evenly, and where
  the ramp runs ahead the plane is half transparent with nothing behind it.
- It reaches **2.5 feather widths** in, not one. That is the distance the
  variable blur actually needs before the plane is opaque.

The leak *moved* as the lid closed — top of the screen at a quarter fold, bottom
at nine tenths — because the ramp's knee travels towards the hinge. That is what
made one fault look like several separate ones.

Measured with the three layers tinted apart (see below), leaked pixels went to
zero across the range:

| Fold | Before | After |
| --- | --- | --- |
| 12% | 0.004% | 0.004% |
| 25% | 0.007% | 0.000% |
| 50% | 0.024% | 0.000% |
| 75% | 0.053% | 0.000% |
| 90% | 0.127% | 0.000% |

And the darkness descends with the fold. Across the panel in ten bands, the top
band goes 37.3 → 37.2 → 26.5 → 10.0 as the fold runs 0 → 12% → 30% → 50%, while
the bottom band stays within 3.5 of untouched throughout.

## Colour and shading

The far end of the plane is shaded down, by up to half its brightness at full
fold. A surface turning away from the light gets darker, and after the
perspective this is the strongest depth cue available — without it the plane
reads as a blurred picture lying flat rather than a panel leaning back. It is a
`CIMultiplyCompositing` pass against the same gradient the blur uses.

A multiply and not the brightness control, deliberately:

> **Core Image works in a linear colour space.** Easing the contrast to 0.98
> pivots dark pixels about linear 0.5 — an sRGB 0.1 pixel is 0.010 in linear and
> comes back 0.020, twice as bright. Measured against an unfiltered capture,
> that put a uniform **+15/255 white haze** over the whole screen from the
> moment the effect began.

Multiplying is a ratio: it scales every pixel by the same factor and cannot lift
a dark one, so the linear working space costs nothing. Saturation is safe for
the same reason — it is a ratio about the pixel's own luma — and it is pushed up
because a blur alone reads as grey mist, blurring having averaged the colour
away.

## Coming and going

The plane is dissolved in and out rather than switched on and off.

It can never be as sharp as the screen it is copying. Any transform at all puts
the captured pixels through bilinear resampling and breaks their alignment with
the display grid, and that softness does not fall away as the fold does:
measured on a static region, the plane is still **12% softer than the real
screen at a fold of 0.002**, where the lean is a twentieth of a degree and every
filter is already switched off.

So there is no angle at which it can simply be removed without the screen
snapping into focus. Fading it over the first 8% of the fold takes the step at
the cut-off from **11.9% to 0.5%**.

| Fold | Cut | Dissolved |
| --- | --- | --- |
| 0 (off) | 1.6474 | 1.6474 |
| 0.002 | 1.4518 | 1.6392 |
| 0.030 | 1.0048 | 1.2647 |

*Mean absolute horizontal gradient over a fixed static region; higher is
sharper.*

## Lifecycle

Three bugs lived in the capture's lifecycle, all invisible on screen:

- `FoldOverlayWindow.apply` returned before reaching the renderer once the fold
  hit zero, so the plane was never told the effect was over and **kept capturing
  for the rest of the session**, with the screen-recording indicator lit.
- `DisplayStream.start` guarded on its `stream` property, which is only assigned
  after the asynchronous set-up finishes. The frame loop therefore created a
  fresh `SCStream` on every frame until the first one came up — **five live
  captures for one fold, four of them orphaned**: never stopped, and still
  delivering frames into the same handler.
- The stop itself was guarded on `feed.isRunning`, which has the same problem
  from the other side: a fold that started and reversed before the set-up
  finished skipped the stop, and the stream was adopted afterwards and never
  released. The first fix above made the stop reachable; this one made it
  unconditional.

Measured after all three, driving the fold through the threshold repeatedly:
one stream created and stopped per cycle, alternating cleanly.

Cost, once both were fixed: about **3.5% CPU** while the plane is on screen,
against 0.2% idle. It only runs below the threshold angle.

## How this was measured

The effect is hard to judge by eye, and two rounds of wrong conclusions came
from measuring the wrong thing. What worked:

**Tinting the layers apart.** There are three layers on screen: the plane, the
void, and the real screen behind both. Painting the *void* a colour cannot
separate them, because the plane shows a copy of the same desktop. Painting the
**plane red and the void blue** can: neither has a green channel, so any green
pixel is provably the real screen, with no assumption about the desktop's
colours. Every leak figure above comes from counting green pixels.

**Gradient energy.** Mean absolute horizontal difference over a fixed static
region of the screen. A resampled copy of the desktop is measurably softer than
the desktop, which is what makes the dissolve numbers above possible.

**Band profiles.** Mean luminance in ten horizontal bands, which is how the
descending void was checked against an untouched baseline.

**`--simulate` and the Preview slider.** Holding a fixed angle is what makes any
of this repeatable; moving the lid by hand cannot be done while reading the
screen.

Two cautionary notes, both learned by getting them wrong:

- A colour-based leak detector that looks for *saturated* pixels fails, because
  the capture legitimately contains the wallpaper and the Dock. It cannot tell
  captured wallpaper from leaked wallpaper. Tint the layers instead.
- Screenshots taken across a settings change compare nothing. The threshold is
  persisted and can be changed from the menu between two captures; read it at
  capture time and confirm it afterwards.
