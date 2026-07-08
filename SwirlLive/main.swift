//
//  main.swift
//  SwirlLive — companion app for live-tuning the SwirlSaver effect.
//
//  Runs the SAME SwirlRenderer + SwirlCore.metal in a regular movable/resizable
//  window, with an overlay control panel. Because this is an ordinary app (not
//  the screensaver host), it does NOT quit on mouse/keyboard — you can drag the
//  sliders freely. Escape (or ⌘Q) exits; the green button goes fullscreen.
//  Every change is written to the shared ScreenSaverDefaults so the real
//  screensaver reflects your tuning.
//
//  SwirlRenderer.swift is compiled into this app (see build-live.sh), and the
//  metallib is bundled in Resources, so the visuals match the saver exactly.
//

import AppKit
import MetalKit
import ScreenSaver
import ImageIO
import UniformTypeIdentifiers

// Wraps a closure as an @objc target/action for controls.
final class ActionTarget: NSObject {
    let cb: (Double) -> Void
    init(_ cb: @escaping (Double) -> Void) { self.cb = cb }
    @objc func fire(_ s: NSSlider) { cb(s.doubleValue) }
}

final class AppController: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var mtkView: MTKView!
    var renderer: SwirlRenderer!
    var targets: [ActionTarget] = []          // retain slider targets
    var sliders: [String: NSSlider] = [:]     // by settings key, for re-sync
    var panel: NSView?                        // control panel, toggled with H
    var titleLabel: NSTextField?              // for transient status messages
    let defaults = SwirlSaverView.saverDefaults

    struct Ctl {
        let name: String, key: String
        let min: Double, max: Double
        let set: (SwirlRenderer, Float) -> Void
    }

    lazy var controls: [Ctl] = [
        Ctl(name: "Speed",       key: SwirlSaverView.Key.speed,      min: 0.0,  max: 3.0)  { $0.speed = $1 },
        Ctl(name: "Detail",      key: SwirlSaverView.Key.density,    min: 0.25, max: 3.0)  { $0.density = $1 },
        Ctl(name: "Saturation",  key: SwirlSaverView.Key.saturation, min: 0.0,  max: 1.0)  { $0.saturation = $1 },
        Ctl(name: "Brightness",  key: SwirlSaverView.Key.brightness, min: 0.5,  max: 3.0)  { $0.brightness = $1 },
        Ctl(name: "Chroma",      key: SwirlSaverView.Key.chroma,     min: 0.0,  max: 0.02) { $0.chroma = $1 },
        Ctl(name: "Glass bend",  key: SwirlSaverView.Key.glassBend,  min: 0.0,  max: 0.08) { $0.glassBend = $1 },
        Ctl(name: "Ripple",      key: SwirlSaverView.Key.ripple,     min: 0.0,  max: 0.5)  { $0.ripple = $1 },
        Ctl(name: "Wave size",   key: SwirlSaverView.Key.waveSize,   min: 0.5,  max: 3.0)  { $0.waveSize = $1 },
        Ctl(name: "Grain",       key: SwirlSaverView.Key.grain,      min: 0.0,  max: 0.15) { $0.grain = $1 },
    ]

    func applicationDidFinishLaunching(_ note: Notification) {
        let initial = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: initial,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Swirl XDR — Live"
        window.minSize = NSSize(width: 640, height: 400)
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .black
        window.isOpaque = true
        window.center()

        let content = NSView(frame: initial)
        window.contentView = content

        // Metal view (fills the window)
        mtkView = MTKView(frame: content.bounds)
        mtkView.autoresizingMask = [.width, .height]
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.autoResizeDrawable = false
        guard let r = SwirlRenderer(metalView: mtkView) else {
            fatalError("Renderer init failed (metallib missing?)")
        }
        renderer = r
        applyStoredToRenderer()
        content.addSubview(mtkView)

        let p = makePanel()
        panel = p
        content.addSubview(p)

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Pick up tuning done elsewhere (e.g. the saver's Options sheet) whenever
        // the app comes back to the front.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyStoredToRenderer()
            self?.syncSlidersFromDefaults()
        }

        // Escape / ⌘Q to quit; S saves a 2× screenshot; H toggles the panel.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { NSApp.terminate(nil); return nil }          // esc
            if e.charactersIgnoringModifiers == "q", e.modifierFlags.contains(.command) {
                NSApp.terminate(nil); return nil
            }
            if e.charactersIgnoringModifiers?.lowercased() == "s" {          // screenshot
                self?.takeScreenshot(); return nil
            }
            if e.charactersIgnoringModifiers?.lowercased() == "h" {          // hide/show panel
                if let p = self?.panel { p.isHidden.toggle() }
                return nil
            }
            return e
        }
    }

    /// Render at 2× the current drawable size and save a PNG to the Desktop.
    private func takeScreenshot() {
        let w = Int((mtkView.drawableSize.width * 2).rounded())
        let h = Int((mtkView.drawableSize.height * 2).rounded())
        guard w > 0, h > 0, let img = renderer.snapshot(width: w, height: h) else {
            flash("Screenshot failed"); return
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Swirl XDR \(fmt.string(from: Date())).png"
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            flash("No Desktop found"); return
        }
        let url = desktop.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            flash("Screenshot failed"); return
        }
        CGImageDestinationAddImage(dest, img, nil)
        if CGImageDestinationFinalize(dest) {
            flash("📸 Saved to Desktop (\(w)×\(h))")
        } else {
            flash("Screenshot failed")
        }
    }

    /// Briefly show a message in the panel title, then restore it.
    private func flash(_ message: String) {
        titleLabel?.stringValue = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.titleLabel?.stringValue = "Swirl XDR — Live"
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func syncSlidersFromDefaults() {
        guard let d = defaults else { return }
        for c in controls {
            sliders[c.key]?.doubleValue = Double(d.float(forKey: c.key))
        }
    }

    private func applyStoredToRenderer() {
        guard let d = defaults else { return }
        renderer.speed = d.float(forKey: SwirlSaverView.Key.speed)
        renderer.density = d.float(forKey: SwirlSaverView.Key.density)
        renderer.saturation = d.float(forKey: SwirlSaverView.Key.saturation)
        renderer.brightness = d.float(forKey: SwirlSaverView.Key.brightness)
        renderer.chroma = d.float(forKey: SwirlSaverView.Key.chroma)
        renderer.glassBend = d.float(forKey: SwirlSaverView.Key.glassBend)
        renderer.ripple = d.float(forKey: SwirlSaverView.Key.ripple)
        renderer.waveSize = d.float(forKey: SwirlSaverView.Key.waveSize)
        renderer.grain = d.float(forKey: SwirlSaverView.Key.grain)
    }

    private func makePanel() -> NSView {
        let rowH: CGFloat = 46
        let pad: CGFloat = 18
        let width: CGFloat = 320
        let headerH: CGFloat = 64
        let height = headerH + CGFloat(controls.count) * rowH + pad

        let panel = NSVisualEffectView(frame: NSRect(x: 32, y: 32, width: width, height: height))
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 14
        panel.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "Swirl XDR — Live")
        title.font = .boldSystemFont(ofSize: 15)
        title.textColor = .white
        title.frame = NSRect(x: pad, y: height - 30, width: width - 2 * pad, height: 20)
        panel.addSubview(title)
        titleLabel = title

        let hint = NSTextField(labelWithString: "H hide panel · S = 2× screenshot · Esc to exit")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: pad, y: height - 48, width: width - 2 * pad, height: 14)
        panel.addSubview(hint)

        let d = defaults
        for (i, c) in controls.enumerated() {
            let y = height - headerH - CGFloat(i + 1) * rowH + 8
            let label = NSTextField(labelWithString: c.name)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .white
            label.frame = NSRect(x: pad, y: y + 20, width: width - 2 * pad, height: 15)
            panel.addSubview(label)

            let value = Float(d?.float(forKey: c.key) ?? 0)
            let slider = NSSlider(value: Double(value), minValue: c.min, maxValue: c.max,
                                  target: nil, action: nil)
            slider.frame = NSRect(x: pad, y: y, width: width - 2 * pad, height: 20)
            slider.isContinuous = true

            let t = ActionTarget { [weak self] v in
                guard let self = self else { return }
                c.set(self.renderer, Float(v))
                self.defaults?.set(Float(v), forKey: c.key)
                self.defaults?.synchronize()
            }
            slider.target = t
            slider.action = #selector(ActionTarget.fire(_:))
            targets.append(t)
            sliders[c.key] = slider
            panel.addSubview(slider)
        }
        return panel
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
