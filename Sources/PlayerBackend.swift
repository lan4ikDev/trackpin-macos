import AppKit

/// One music player TrackPin can read and control (Spotify, Apple Music, Yandex Music).
///
/// `Player` calls `read(command:)` on its own serial background queue, never on the main
/// thread, so implementations may block for a moment (AppleScript, Accessibility).
protocol PlayerBackend: AnyObject {
    var source: MusicSource { get }
    /// Apps whose launch and quit should trigger a fresh read.
    var bundleIdentifiers: [String] { get }
    /// Distributed notifications the player posts when it plays, pauses or changes track.
    /// Players without any are polled.
    var changeNotifications: [String] { get }
    /// True when asking the player now would not start an app. Cheap: called on the main thread.
    var isAvailable: Bool { get }
    /// Runs `command` (if any), then reads the current state. Must never launch the player.
    func read(command: PlayerCommand?) -> Playback
    /// Brings the player to the front, or starts it.
    func open()
}

extension PlayerBackend {
    var notifies: Bool { !changeNotifications.isEmpty }

    static func runningApp(_ bundleIdentifiers: [String]) -> NSRunningApplication? {
        for id in bundleIdentifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { return app }
        }
        return nil
    }

    /// Opens the first installed app of `bundleIdentifiers`, or `fallback` in the browser.
    static func openApp(_ bundleIdentifiers: [String], fallback: String) {
        if let running = runningApp(bundleIdentifiers) {
            running.activate()
            return
        }
        for id in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                return
            }
        }
        if let url = URL(string: fallback) { NSWorkspace.shared.open(url) }
    }
}

/// Helpers shared by the AppleScript based players.
enum AppleScript {
    static func literal(_ string: String) -> String {
        let escaped = string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func wrap(_ body: String, bundleIdentifier: String, timeout: Int = 3) -> String {
        """
        with timeout of \(timeout) seconds
            tell application id "\(bundleIdentifier)"
                \(body)
            end tell
        end timeout
        """
    }

    /// Compiled scripts by source. Only touched on the player queue. Commands such as
    /// play/pause are the same text every time, so they are compiled once instead of on every
    /// press (compiling loads the player's scripting dictionary).
    private static var compiled: [String: NSAppleScript] = [:]

    /// Runs a script, compiling it on first use. Returns the result or the error dictionary.
    static func run(_ source: String) -> (NSAppleEventDescriptor?, NSDictionary?) {
        var error: NSDictionary?
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else { return (nil, nil) }
            if fresh.compileAndReturnError(&error) {
                if compiled.count > 64 { compiled.removeAll() }
                compiled[source] = fresh
            }
            script = fresh
        }
        let result = script.executeAndReturnError(&error)
        return (result, error)
    }

    /// Maps an AppleScript error to a playback state. Nil when there was no error, or when
    /// a failed command should not hide the state read after it.
    static func failure(_ error: NSDictionary?, reading: Bool) -> Playback? {
        guard let error else { return nil }
        let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        switch code {
        case -1743: return .denied
        case -600, -609: return .closed
        case -1728, -1731: return reading ? .idle : nil
        default:
            // Browsers refuse scripts until "Allow JavaScript from Apple Events" is turned on.
            let message = (error[NSAppleScript.errorMessage] as? String) ?? ""
            if message.localizedCaseInsensitiveContains("javascript") { return .denied }
            return .unavailable
        }
    }

    /// Decodes `{id, name, artist, artwork url, duration, position, playing[, volume, shuffle, repeat]}`.
    /// - Parameter millis: the duration is in milliseconds (Spotify) instead of seconds (Music).
    static func decodeTrack(_ descriptor: NSAppleEventDescriptor, idPrefix: String = "", millis: Bool,
                            allowedArtworkSchemes: Set<String> = ["https"]) -> Playback {
        let count = descriptor.numberOfItems
        if count == 0 { return descriptor.descriptorType == typeAEList ? .idle : .unavailable }
        guard count == 7 || count == 10 else { return .unavailable }
        func item(_ index: Int) -> NSAppleEventDescriptor? { descriptor.atIndex(index + 1) }
        guard let id = item(0)?.stringValue, let title = item(1)?.stringValue,
              let length = item(4)?.doubleValue, length.isFinite,
              let seconds = item(5)?.doubleValue, seconds.isFinite,
              let playing = item(6)?.booleanValue else { return .unavailable }
        let artist = item(2)?.stringValue ?? ""
        let duration = max(0, millis ? length / 1000 : length)
        let cover = item(3)?.stringValue.flatMap(URL.init(string:))
            .flatMap { allowedArtworkSchemes.contains($0.scheme ?? "") ? $0 : nil }
        var track = Track(id: idPrefix + id, title: title, artist: artist, artwork: cover,
                          duration: duration, position: min(max(seconds, 0), duration), playing: playing)
        if count == 10 {
            track.volume = item(7).map { Int($0.int32Value) }
            track.shuffling = item(8)?.booleanValue
            track.repeating = item(9)?.booleanValue
        }
        return .track(track)
    }
}

extension NSAppleEventDescriptor {
    var doubleValue: Double? {
        switch descriptorType {
        case typeIEEE64BitFloatingPoint, typeIEEE32BitFloatingPoint, typeSInt32, typeSInt16, typeSInt64, typeUInt32:
            guard let coerced = coerce(toDescriptorType: typeIEEE64BitFloatingPoint) else { return nil }
            var value = 0.0
            (coerced.data as NSData).getBytes(&value, length: MemoryLayout<Double>.size)
            return value
        default:
            return stringValue.flatMap(Double.init)
        }
    }
}
