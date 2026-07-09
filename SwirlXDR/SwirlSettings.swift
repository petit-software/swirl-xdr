//
//  SwirlSettings.swift
//  Shared settings store for the SwirlSaver screensaver AND the SwirlLive
//  companion app.
//
//  Why not ScreenSaverDefaults / UserDefaults?
//  ------------------------------------------
//  On modern macOS third-party savers run inside Apple's *sandboxed*,
//  out-of-process `legacyScreenSaver` host. That sandbox redirects
//  ~/Library/Preferences into a private container, so a ByHost/UserDefaults
//  suite written by the ordinary (unsandboxed) companion app is invisible to
//  the running saver — they end up reading and writing three different files.
//  App Groups don't help either: the host has no `application-groups`
//  entitlement and a plugin can't extend its host's sandbox.
//
//  BUT the host *does* carry
//      com.apple.security.temporary-exception.files.absolute-path.read-only = "/"
//  i.e. it may READ any file on the real filesystem by absolute path. So we use
//  a plain JSON file at a fixed REAL path: the companion (unsandboxed) writes
//  it, the saver reads it directly with FileManager — bypassing the Preferences
//  container redirect entirely.
//
//  The one catch: inside the sandbox `NSHomeDirectory()` returns the container,
//  not the real home. `getpwuid(getuid())` is not redirected, so we use it to
//  resolve the real home and build the shared absolute path both sides agree on.
//

import Foundation

/// A tiny UserDefaults-shaped store backed by a JSON file at a fixed real path.
/// Shared, verbatim, by the saver and the companion app.
final class SwirlSettings {

    static let shared = SwirlSettings()

    /// Registered defaults — also the fallback for any key missing from disk.
    static let defaults: [String: Float] = [
        SwirlSaverView.Key.speed: 1.2,
        SwirlSaverView.Key.density: 1.4,
        SwirlSaverView.Key.saturation: 0.0,
        SwirlSaverView.Key.brightness: 1.75,
        SwirlSaverView.Key.chroma: 0.009,
        SwirlSaverView.Key.glassBend: 0.035,
        SwirlSaverView.Key.ripple: 0.2425,
        SwirlSaverView.Key.waveSize: 1.80,
        SwirlSaverView.Key.grain: 0.04,
    ]

    private let fileURL: URL
    private var values: [String: Float]

    private init() {
        let dir = SwirlSettings.realHomeDirectory()
            .appendingPathComponent("Library/Application Support/SwirlSaver", isDirectory: true)
        fileURL = dir.appendingPathComponent("settings.json")
        values = SwirlSettings.defaults
        load()
    }

    /// The real home directory, even inside the screensaver sandbox where
    /// NSHomeDirectory()/$HOME point at the redirected container.
    static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home))
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    /// Re-read the shared file from disk. Cheap; call before applying settings
    /// so live edits made by the other process are picked up.
    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (key, raw) in obj {
            if let n = raw as? NSNumber { values[key] = n.floatValue }
        }
    }

    func float(forKey key: String) -> Float {
        values[key] ?? SwirlSettings.defaults[key] ?? 0
    }

    func set(_ value: Float, forKey key: String) {
        values[key] = value
    }

    /// Persist the current values to the shared file (atomic write).
    @discardableResult
    func synchronize() -> Bool {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let obj = values.mapValues { NSNumber(value: $0) }
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        return (try? data.write(to: fileURL, options: .atomic)) != nil
    }
}
