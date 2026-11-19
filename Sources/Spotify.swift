import AppKit

enum PlayerCommand: Equatable {
    case previous, toggle, pause, next, skip(Int), seek(Double, String)
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
}

/// Talks to Spotify through AppleScript.
///
/// The scripts run inside the TrackPin process with `NSAppleScript`. Earlier versions started
/// an `osascript` process for every read, once a second, which macOS rightly reported as
/// high energy use. The snapshot script is compiled once and reused.
final class SpotifyBridge: PlayerBackend {
    static let bundleIdentifier = "com.spotify.client"

    let source = MusicSource.spotify
    let bundleIdentifiers = [SpotifyBridge.bundleIdentifier]
    let changeNotifications = ["com.spotify.client.PlaybackStateChanged"]

    /// Only touched on the player queue.
    private var snapshotScript: NSAppleScript?

    var isAvailable: Bool { Self.isRunning }

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

    func open() {
        if let url = Self.locateSpotify() {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else if let url = URL(string: "https://www.spotify.com/download/mac/") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func wrap(_ body: String) -> String {
        AppleScript.wrap(body, bundleIdentifier: bundleIdentifier)
    }

    private static let snapshotSource = wrap("""
        set song to current track
        if song is missing value then return {}
        set coverLink to artwork url of song
        if coverLink is missing value then set coverLink to ""
        return {id of song, name of song, artist of song, coverLink, duration of song, player position, (player state is playing), sound volume, shuffling, repeating}
        """)

    static func script(for command: PlayerCommand) -> String {
        switch command {
        case .previous: return "previous track"
        case .toggle: return "playpause"
        case .pause: return "pause"
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
            return """
            if (id of current track as text) is \(AppleScript.literal(id)) then
                set player position to \(max(0, seconds))
            end if
            """
        case let .volume(level): return "set sound volume to \(min(max(level, 0), 100))"
        case let .shuffle(on): return "set shuffling to \(on)"
        case let .repeating(on): return "set repeating to \(on)"
        }
    }

    func read(command: PlayerCommand?) -> Playback {
        // Never let a script start Spotify: `tell application` launches a closed app.
        guard Self.isRunning else { return .closed }
        if let command {
            let (_, error) = AppleScript.run(Self.wrap(Self.script(for: command)))
            if let failure = AppleScript.failure(error, reading: false) { return failure }
        }
        if snapshotScript == nil {
            let script = NSAppleScript(source: Self.snapshotSource)
            var error: NSDictionary?
            guard script?.compileAndReturnError(&error) == true else { return .unavailable }
            snapshotScript = script
        }
        var error: NSDictionary?
        guard let result = snapshotScript?.executeAndReturnError(&error) else {
            return AppleScript.failure(error, reading: true) ?? .unavailable
        }
        return Self.decode(result)
    }

    /// Decodes the list returned by the snapshot script. Volume, shuffle and repeat are optional.
    static func decode(_ descriptor: NSAppleEventDescriptor) -> Playback {
        AppleScript.decodeTrack(descriptor, millis: true)
    }
}
