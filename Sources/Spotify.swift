import AppKit
import SwiftUI

enum PlayerCommand: Equatable {
    case previous, toggle, next, skip(Int), seek(Double, String)
    case volume(Int), shuffle(Bool), repeating(Bool)

    init(_ action: PlayerAction, step: Int) {
        switch action {
        case .toggle: self = .toggle
        case .next: self = .next
        case .previous: self = .previous
        case .rewind: self = .skip(-step)
        case .forward: self = .skip(step)
        }
    }

    /// Commands of the same kind replace each other in the queue (a dragged slider sends many).
    var coalesces: Bool {
        switch self {
        case .seek, .volume: true
        default: false
        }
    }

    func sameKind(as other: PlayerCommand) -> Bool {
        switch (self, other) {
        case (.seek, .seek), (.volume, .volume): true
        default: false
        }
    }

    var script: String {
        switch self {
        case .previous: return "previous track"
        case .toggle: return "playpause"
        case .next: return "next track"
        case let .skip(offset):
            return """
            set targetPosition to (player position) + \(offset)
            set trackLength to (duration of current track) / 1000
            if targetPosition < 0 then set targetPosition to 0
            if targetPosition > trackLength then set targetPosition to trackLength
            set player position to targetPosition
            """
        case let .seek(seconds, id):
            let literal = SpotifyBridge.scriptLiteral(id)
            return """
            if (id of current track as text) is \(literal) then
                set player position to \(max(0, seconds))
            end if
            """
        case let .volume(level): return "set sound volume to \(min(max(level, 0), 100))"
        case let .shuffle(on): return "set shuffling to \(on)"
        case let .repeating(on): return "set repeating to \(on)"
        }
    }
}

/// Talks to Spotify through AppleScript.
///
/// The scripts run inside the TrackPin process with `NSAppleScript`. Earlier versions started
/// an `osascript` process for every read, once a second, which macOS rightly reported as
/// high energy use. The snapshot script is compiled once and reused.
final class SpotifyBridge {
    static let bundleIdentifier = "com.spotify.client"

    private let queue = DispatchQueue(label: "dev.lan4ik.needle.spotify", qos: .utility)
    /// Only touched on `queue`.
    private var snapshotScript: NSAppleScript?

    static var isInstalled: Bool { locateSpotify() != nil }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static func locateSpotify() -> URL? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Spotify.app"),
            URL(fileURLWithPath: "/Applications/Spotify.app")
        ]
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            ?? candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func scriptLiteral(_ string: String) -> String {
        let escaped = string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func wrap(_ body: String) -> String {
        """
        with timeout of 3 seconds
            tell application id "\(bundleIdentifier)"
                \(body)
            end tell
        end timeout
        """
    }

    private static let snapshotSource = wrap("""
        set song to current track
        if song is missing value then return {}
        set coverLink to artwork url of song
        if coverLink is missing value then set coverLink to ""
        return {id of song, name of song, artist of song, coverLink, duration of song, player position, (player state is playing), sound volume, shuffling, repeating}
        """)

    /// Runs `command` (if any), then reads the current state. `completion` runs on the main queue.
    func read(command: PlayerCommand?, completion: @escaping (Playback) -> Void) {
        // Never let a script start Spotify: `tell application` launches a closed app.
        guard Self.isRunning else {
            DispatchQueue.main.async { completion(.closed) }
            return
        }
        queue.async {
            let result = self.readSynchronously(command)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func readSynchronously(_ command: PlayerCommand?) -> Playback {
        if let command {
            let script = NSAppleScript(source: Self.wrap(command.script))
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            if let failure = Self.failure(error, reading: false) { return failure }
        }
        if snapshotScript == nil {
            let script = NSAppleScript(source: Self.snapshotSource)
            var error: NSDictionary?
            guard script?.compileAndReturnError(&error) == true else { return .unavailable }
            snapshotScript = script
        }
        var error: NSDictionary?
        guard let result = snapshotScript?.executeAndReturnError(&error) else {
            return Self.failure(error, reading: true) ?? .unavailable
        }
        return Self.decode(result)
    }

    private static func failure(_ error: NSDictionary?, reading: Bool) -> Playback? {
        guard let error else { return nil }
        let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        switch code {
        case -1743: return .denied
        case -600, -609: return .closed
        case -1728, -1731: return reading ? .idle : nil
        default: return .unavailable
        }
    }

    /// Decodes the list returned by the snapshot script. Volume, shuffle and repeat are optional.
    static func decode(_ descriptor: NSAppleEventDescriptor) -> Playback {
        let count = descriptor.numberOfItems
        if count == 0 { return descriptor.descriptorType == typeAEList ? .idle : .unavailable }
        guard count == 7 || count == 10 else { return .unavailable }
        func item(_ index: Int) -> NSAppleEventDescriptor? { descriptor.atIndex(index + 1) }
        guard let id = item(0)?.stringValue, let title = item(1)?.stringValue, let artist = item(2)?.stringValue,
              let millis = item(4)?.doubleValue, millis.isFinite,
              let seconds = item(5)?.doubleValue, seconds.isFinite,
              let playing = item(6)?.booleanValue else { return .unavailable }
        let duration = max(0, millis / 1000)
        let cover = item(3)?.stringValue.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        var track = Track(id: id, title: title, artist: artist, artwork: cover,
                          duration: duration, position: min(max(seconds, 0), duration), playing: playing)
        if count == 10 {
            track.volume = item(7).map { Int($0.int32Value) }
            track.shuffling = item(8)?.booleanValue
            track.repeating = item(9)?.booleanValue
        }
        return .track(track)
    }
}

private extension NSAppleEventDescriptor {
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

/// Reads Spotify as rarely as it can.
///
/// - Spotify posts `com.spotify.client.PlaybackStateChanged` on play, pause and track changes,
///   and TrackPin reads the state right away when it arrives.
/// - The workspace reports when Spotify starts or quits. While it is closed, nothing is polled.
/// - While a TrackPin window is visible (`isForeground`), the state is polled every
///   `foregroundInterval` seconds so the slider follows seeks made in Spotify.
/// - In the background a playing track is polled every `backgroundInterval` seconds (0 turns
///   this off). The widget advances its progress bar on its own.
final class Player: NSObject, ObservableObject {
    typealias Completion = (Playback) -> Void

    @Published private(set) var playback: Playback = .closed
    /// When `playback` was read. The UI extrapolates the position of a playing track from it.
    @Published private(set) var sampledAt = Date()

    var foregroundInterval: TimeInterval = 1 { didSet { if foregroundInterval != oldValue { schedule() } } }
    var backgroundInterval: TimeInterval = 30 { didSet { if backgroundInterval != oldValue { schedule() } } }
    var isForeground = false {
        didSet {
            guard isForeground != oldValue else { return }
            if isForeground { refresh() }
            schedule()
        }
    }

    private let bridge = SpotifyBridge()
    private var timer: Timer?
    private var busy = false
    private var pending: [(command: PlayerCommand, completion: Completion?)] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        super.init()
        if demo {
            playback = .track(Track(id: "demo", title: "After Hours", artist: "Демонстрация",
                                    artwork: nil, duration: 228, position: 72, playing: true,
                                    volume: 70, shuffling: false, repeating: false))
        }
        // `.deliverImmediately`: an accessory app is never active, and AppKit otherwise holds
        // distributed notifications back until the app is activated.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(spotifyChanged),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, suspensionBehavior: .deliverImmediately)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SpotifyBridge.bundleIdentifier else { return }
                // Spotify needs a moment after launch before it answers scripts.
                DispatchQueue.main.asyncAfter(deadline: .now() + (name == NSWorkspace.didLaunchApplicationNotification ? 2 : 0.2)) {
                    self?.refresh()
                }
            })
        }
        refresh()
    }

    deinit {
        timer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    @objc private func spotifyChanged() {
        refresh()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        let interval: TimeInterval
        if isForeground {
            interval = max(0.5, foregroundInterval)
        } else if demo || backgroundInterval <= 0 {
            return
        } else if case let .track(track) = playback, track.playing {
            interval = backgroundInterval
        } else {
            // Paused, idle or closed: Spotify's notifications and the workspace wake us up.
            return
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = interval * (isForeground ? 0.1 : 0.5)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Queues a command. `completion` receives the playback state read right after the command ran.
    func send(_ command: PlayerCommand, completion: Completion? = nil) {
        if demo, case var .track(track) = playback {
            switch command {
            case .toggle: track.playing.toggle()
            case .previous, .next: track.position = 0
            case let .skip(offset): track.position = min(max(0, track.position + Double(offset)), track.duration)
            case let .seek(seconds, _): track.position = seconds
            case let .volume(level): track.volume = level
            case let .shuffle(on): track.shuffling = on
            case let .repeating(on): track.repeating = on
            }
            update(.track(track))
            completion?(playback)
            return
        }
        if command.coalesces, let last = pending.last, last.command.sameKind(as: command), last.completion == nil {
            pending.removeLast()
        }
        pending.append((command, completion))
        refresh()
    }

    func openSpotify() {
        if let url = SpotifyBridge.locateSpotify() {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else if let url = URL(string: "https://www.spotify.com/download/mac/") {
            NSWorkspace.shared.open(url)
        }
    }

    func retry() {
        refresh()
    }

    private func update(_ value: Playback) {
        let wasPlaying = playback.currentTrack?.playing ?? false
        sampledAt = Date()
        if value != playback { playback = value }
        if (value.currentTrack?.playing ?? false) != wasPlaying || timer == nil { schedule() }
    }

    private func refresh() {
        if demo {
            if case var .track(track) = playback, track.playing {
                track.position = min(track.duration, track.position + Date().timeIntervalSince(sampledAt))
                if track.position == track.duration { track.playing = false }
                update(.track(track))
            }
            return
        }
        guard !busy else { return }
        busy = true
        let next = pending.isEmpty ? nil : pending.removeFirst()
        bridge.read(command: next?.command) { [weak self] result in
            guard let self else { return }
            if self.pending.isEmpty { self.update(result) }
            self.busy = false
            next?.completion?(result)
            if !self.pending.isEmpty { self.refresh() }
        }
    }
}
