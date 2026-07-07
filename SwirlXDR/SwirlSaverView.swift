//
//  SwirlSaverView.swift
//  SwirlSaver
//
//  Hosts the neon liquid-marble shader inside a ScreenSaverView. The @objc name
//  matches INFOPLIST_KEY_NSPrincipalClass so the system can instantiate this
//  class from the bundle.
//
//  Lifecycle handling (self-driving MTKView, exit(0) on stop, fresh config
//  sheet each open) follows the hard-won pattern from liquid-glass-screensaver:
//  on modern macOS third-party savers run in the out-of-process
//  `legacyScreenSaver` host, which does not reliably tear savers down.
//

import ScreenSaver
import MetalKit

@objc(SwirlSaverView)
class SwirlSaverView: ScreenSaverView {

    private var metalView: MTKView?
    private var renderer: SwirlRenderer?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
    }

    private func commonInit() {
        animationTimeInterval = 1.0 / 60.0
        setupLifecycleObservers()
        setupMetal()
    }

    private func setupMetal() {
        guard metalView == nil else { return }

        let mtkView = MTKView(frame: bounds)
        // Self-driving: the MTKView's own display link renders at 60fps even if
        // the wedged host drops animateOneFrame/startAnimation calls.
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.autoresizingMask = [.width, .height]
        mtkView.autoResizeDrawable = false   // renderer caps the drawable size

        guard let renderer = SwirlRenderer(metalView: mtkView) else { return }
        applySettings(to: renderer)

        addSubview(mtkView)
        mtkView.frame = bounds
        self.metalView = mtkView
        self.renderer = renderer
    }

    private func teardownMetal() {
        metalView?.removeFromSuperview()
        metalView = nil
        renderer = nil
    }

    override func startAnimation() {
        super.startAnimation()
        setupMetal()
    }

    override func stopAnimation() {
        super.stopAnimation()
        teardownMetal()
    }

    override func removeFromSuperview() {
        teardownMetal()
        super.removeFromSuperview()
    }

    override func animateOneFrame() {
        // Rendering is driven by the MTKView's own display link.
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            metalView?.layer?.contentsScale = window.backingScaleFactor
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window = self.window {
            metalView?.layer?.contentsScale = window.backingScaleFactor
        }
    }

    // MARK: - Host process lifecycle
    //
    // ⚠️ Do not remove exit(0). The out-of-process legacyScreenSaver host does
    // not reliably tear savers down; without this the Preview button works only
    // once and the host lingers holding GPU resources. Exiting on stop/sleep
    // lets macOS spawn a fresh host for the next run.
    private func setupLifecycleObservers() {
        DistributedNotificationCenter.default.addObserver(
            self, selector: #selector(screensaverWillStop),
            name: Notification.Name("com.apple.screensaver.willstop"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
    }

    @objc private func screensaverWillStop(_ notification: Notification) { exit(0) }
    @objc private func systemWillSleep(_ notification: Notification) { exit(0) }

    // MARK: - Settings

    // All keys are shared with the companion "SwirlLive" app, which writes here
    // so the real screensaver reflects whatever you tuned live.
    enum Key {
        static let speed = "speed"
        static let density = "density"
        static let saturation = "saturation"
        static let brightness = "brightness"
        static let chroma = "chroma"
        static let glassBend = "glassBend"
        static let ripple = "ripple"
        static let waveSize = "waveSize"
        static let grain = "grain"
    }

    static var saverDefaults: ScreenSaverDefaults? {
        // Constant module name (NOT the bundle id): the companion SwirlLive app
        // compiles this class in too, where the bundle id would be the app's —
        // a fixed name guarantees both processes share the same settings suite.
        let module = "com.bartbak.SwirlSaver"
        let d = ScreenSaverDefaults(forModuleWithName: module)
        d?.register(defaults: [
            Key.speed: 1.2, Key.density: 1.4, Key.saturation: 0.0,
            Key.brightness: 1.75, Key.chroma: 0.009, Key.glassBend: 0.035,
            Key.ripple: 0.2425, Key.waveSize: 1.80, Key.grain: 0.04,
        ])
        return d
    }

    // The Options sheet only exposes Speed + Detail, but every parameter is read
    // here so the companion app can drive the rest.
    private func applySettings(to renderer: SwirlRenderer) {
        guard let d = Self.saverDefaults else { return }
        renderer.speed = d.float(forKey: Key.speed)
        renderer.density = d.float(forKey: Key.density)
        renderer.saturation = d.float(forKey: Key.saturation)
        renderer.brightness = d.float(forKey: Key.brightness)
        renderer.chroma = d.float(forKey: Key.chroma)
        renderer.glassBend = d.float(forKey: Key.glassBend)
        renderer.ripple = d.float(forKey: Key.ripple)
        renderer.waveSize = d.float(forKey: Key.waveSize)
        renderer.grain = d.float(forKey: Key.grain)
    }

    // MARK: - Configure sheet

    private var configSheet: NSWindow?
    private var speedSlider: NSSlider?
    private var densitySlider: NSSlider?

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        // Fresh sheet every open (a cached window from a wedged host re-presents frozen).
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 190),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Swirl"
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 190))
        let d = Self.saverDefaults

        func addRow(_ title: String, y: CGFloat, min: Double, max: Double, value: Double) -> NSSlider {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 24, y: y + 22, width: 240, height: 18)
            content.addSubview(label)
            let slider = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
            slider.frame = NSRect(x: 24, y: y, width: 352, height: 22)
            content.addSubview(slider)
            return slider
        }

        speedSlider   = addRow("Speed",  y: 134, min: 0.0, max: 3.0, value: Double(d?.float(forKey: Key.speed) ?? 1.2))
        densitySlider = addRow("Detail", y: 78,  min: 0.25, max: 3.0, value: Double(d?.float(forKey: Key.density) ?? 1.4))

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelConfig))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 208, y: 18, width: 84, height: 32)
        content.addSubview(cancel)

        let done = NSButton(title: "Done", target: self, action: #selector(saveConfig))
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        done.frame = NSRect(x: 300, y: 18, width: 84, height: 32)
        content.addSubview(done)

        window.contentView = content
        configSheet = window
        return window
    }

    @objc private func saveConfig() {
        if let d = Self.saverDefaults {
            if let s = speedSlider { d.set(Float(s.doubleValue), forKey: Key.speed) }
            if let s = densitySlider { d.set(Float(s.doubleValue), forKey: Key.density) }
            d.synchronize()
        }
        if let renderer { applySettings(to: renderer) }
        dismissConfig()
    }

    @objc private func cancelConfig() { dismissConfig() }

    private func dismissConfig() {
        if let window = configSheet {
            window.sheetParent?.endSheet(window)
            configSheet = nil
        }
        speedSlider = nil; densitySlider = nil
    }
}
