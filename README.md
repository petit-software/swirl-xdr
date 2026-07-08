# Swirl XDR

A calm, hypnotic screen saver for macOS — a flowing liquid-chrome swirl seen
through rippling glass, with a whisper of rainbow along the edges.

<img width="3020" height="2124" alt="CleanShot 2026-07-08 at 12  16 11@2x" src="https://github.com/user-attachments/assets/87f637f1-816d-4755-a2b3-b8319d578147" />


## Install

1. Download **Swirl-XDR.saver.zip** from the
   [latest release](https://github.com/petit-software/swirl-xdr/releases/latest)
   and unzip it.
2. Double-click **Swirl XDR.saver** and choose to install it.
3. Open **System Settings → Screen Saver** and pick **Swirl XDR**.

> First time only: because it isn't from the App Store, macOS may ask you to
> confirm. If it's blocked, go to **System Settings → Privacy & Security** and
> click **Open Anyway**, then try again.

## Make it yours

In **System Settings → Screen Saver → Swirl XDR**, click **Options…**:

- **Speed** — how fast it moves
- **Detail** — busy and intricate, or big and calm

## Want more control?

There's a companion app for playing with the look in real time — colors,
brightness, glassiness, grain and more — all on a fullscreen live preview.
Drag the sliders and watch it change; press **Esc** to exit. Press **S** to save
a high-resolution screenshot to your Desktop.

Build and launch it with:

```sh
./build-live.sh
```

Anything you set there becomes the screen saver's look too.

---

<details>
<summary>For developers</summary>

Built in Swift + Metal. One fragment shader (`SwirlXDR/SwirlCore.metal`) does
everything: a domain-warped noise "swirl" refracted through an animated
liquid-glass lens (`combined_fragment`).

- `./install.sh` — build the `.saver` and install it to `~/Library/Screen Savers`
- `./build-live.sh` — build & run the `SwirlLive` tuning app
- `./reset-host.sh` — restart the screen-saver host if a preview gets stuck
- `preview/*.swift` — render stills offline for fast shader iteration

Settings are shared between the saver and the app via `ScreenSaverDefaults`
(module `com.bartbak.SwirlSaver`). The glass lens is ported from paper.design's
`liquidGlass.metal`.

</details>
