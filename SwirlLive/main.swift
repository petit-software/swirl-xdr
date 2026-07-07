//
//  main.swift
//  SwirlLive — companion app for live-tuning the SwirlSaver effect.
//
//  Runs the SAME SwirlRenderer + SwirlCore.metal fullscreen, with an overlay
//  control panel. Because this is an ordinary app (not the screensaver host),
//  it does NOT quit on mouse/keyboard — you can drag the sliders freely. Only
//  Escape (or ⌘Q) exits. Every change is written to the shared ScreenSaverDefaults
//  so the real screensaver reflects your tuning.
//
//  SwirlRenderer.swift is compiled into this app (see build-live.sh), and the
//  metallib is bundled in Resources, so the visuals match the saver exactly.
//

import AppKit
import MetalKit
import ScreenSaver

// A borderless window that can still become key (so sliders are interactive).
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// Wraps a closure as an @objc target/action for controls.
final class ActionTarget: NSObject {
    let cb: (Double) -> Void
    init(_ cb: @escaping (Double) -> Void) { self.cb = cb }
    @objc func fire(_ s: NSSlider) { cb(s.doubleValue) }
}

final class AppController: NSObject, NSApplicationDelegate {
    var window: KeyableWindow!
    var mtkView: MTKView!
    var renderer: SwirlRenderer!
    var targets: [ActionTarget] = []          // retain slider targets
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
        let screen = NSScreen.main ?? NSScreen.screens[0]

        window = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless],
                               backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.setFrame(screen.frame, display: true)

        let content = NSView(frame: screen.frame)
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

        content.addSubview(makePanel())

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Escape / ⌘Q to quit; nothing else exits.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { NSApp.terminate(nil); return nil }          // esc
            if e.charactersIgnoringModifiers == "q", e.modifierFlags.contains(.command) {
                NSApp.terminate(nil); return nil
            }
            return e
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

        let hint = NSTextField(labelWithString: "Drag to tune · saves to the screensaver · Esc to exit")
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
            panel.addSubview(slider)
        }
        return panel
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
