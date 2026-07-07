# SwirlSaver

A macOS screen saver that renders one unified Metal effect: the Apple Pro Display
XDR **neon swirl** seen *through* a **liquid-glass lens**. The swirl (flowing
neon liquid-marble ribbons on black) is the scene; a glass surface — a Fresnel
bulge plus animated Simplex-noise ripples (ported from paper.design's
`liquidGlass.metal`) — lenses and chromatically refracts it, with a specular rim
and film grain on top.

![thumbnail](SwirlSaver/thumbnail.png)

## How the effect works

Everything is produced by one screen-space fragment function, `swirl_color()` in
[`SwirlSaver/SwirlCore.metal`](SwirlSaver/SwirlCore.metal):

1. **Domain-warped fBm** — nested fractal noise (`fbm(p + warp*fbm(p + warp*fbm(p)))`)
   creates the big, smooth, taffy-pulled marble flow. Animating the inner warp with
   time makes it move like liquid.
2. **Iso-contour bands** — sharp, widely-spaced bands of the field become the thin
   parallel ribbons; wide black gaps fall out for free where the field is calm.
3. **Per-channel chromatic offset + cosine palette** — offsetting R/G/B along the
   field gives the oil-slick rainbow fringing; an IQ cosine palette supplies the
   electric blue / cyan / magenta / orange neon.
4. **Specular crest** — the brightest core of each ribbon blooms toward white.

It is a single full-screen triangle — no multi-pass pipeline, no textures.

## Build & install

```sh
xcodebuild -project SwirlSaver.xcodeproj -scheme SwirlSaver -configuration Release build
./install.sh          # copies the .saver into ~/Library/Screen Savers and resets the host
```

Then open **System Settings → Screen Saver → SwirlSaver**. Use **Options…** to tune:

- **Speed** — animation rate (drives both the swirl flow and the glass ripple)
- **Detail** — swirl ribbon density

The swirl palette (the 8 reference neons) and the glass parameters (refraction,
ripple/liquid amount, grain, etc.) are baked to their defaults in `SwirlUniforms`
/ `LiquidUniforms`, easy to expose as extra sliders later. The combined shader is
`combined_fragment` / `combined_color` in `SwirlCore.metal`; `swirl_fragment` and
`liquid_fragment` remain in the file if you ever want either effect on its own.

## Live tuning — the SwirlLive companion app

A real macOS screensaver **can't** show interactive controls: the system's
`legacyScreenSaver` host quits the saver on the first mouse/key event. So live
tuning lives in a companion app instead:

```sh
./build-live.sh        # builds build/SwirlLive.app and launches it fullscreen
```

`SwirlLive.app` runs the exact same `SwirlRenderer` + `SwirlCore.metal`
fullscreen with an overlay panel of sliders for **every** parameter (Speed,
Detail, Saturation, Brightness, Chroma, Glass bend, Ripple, Wave size, Grain).
Because it's an ordinary app, nothing disappears while you drag. **Esc (or ⌘Q)
exits** — nothing else does.

Every change is written to the shared `ScreenSaverDefaults`, and the real
screensaver reads all of those keys, so whatever you dial in here is exactly
what the screensaver shows. (The screensaver's own **Options** sheet still just
exposes Speed + Detail for quick tweaks; the app is the full mixing board.)

Note: `Saturation` goes from 0 (the monochrome liquid-chrome look) up to 1 (full
neon), so the app can take you all the way back to the colorful original.

## Tuning the look offline (no bundle rebuild)

`preview/preview.swift` runtime-compiles the exact same `SwirlCore.metal` as a
compute kernel and writes PNG stills, so you can iterate on the shader without
building the screensaver:

```sh
swift preview/preview.swift SwirlSaver/SwirlCore.metal /tmp/out 1600 900 0.0 6.0
```

The fragment shader and the preview kernel both call `swirl_color()`, so a still
matches exactly what the saver renders.

## Notes on modern macOS screensavers

Third-party savers run in the out-of-process `legacyScreenSaver` host, which does
not reliably tear savers down. `SwirlSaverView` handles this the hard-won way:
self-driving `MTKView` (own display link), `exit(0)` on stop/sleep, a fresh
config sheet per open, and loading the metallib from *this* bundle
(`makeDefaultLibrary(bundle:)`) rather than the host's. See the comments in
[`SwirlSaverView.swift`](SwirlSaver/SwirlSaverView.swift).

Credit: the bundle wiring / lifecycle approach follows the sibling
`liquid-glass-screensaver` project.
