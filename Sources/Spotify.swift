import AppKit
import SwiftUI

enum PlayerCommand {
    case previous, toggle, next, skip(Int), seek(Double, String)

    init(_ action: PlayerAction, step: Int) {
        switch action {
        case .toggle: self = .toggle
        case .next: self = .next
        case .previous: self = .previous
        case .rewind: self = .skip(-step)
        case .forward: self = .skip(step)
        }
    }

    var script: String {
        switch self {
        case .previous: return "previous track"
        case .toggle: return "playpause"
        case .next: return "next track"
        case let .skip(offset):
            return "set player position to (my clamp((player position) + \(offset), (duration of current track) / 1000))"
        case let .seek(seconds, id):
            let literal = SpotifyBridge.scriptLiteral(id)
            return """
            if (id of current track as text) is \(literal) then
                set player position to \(seconds)
            end if
            """
        }
    }
}

final class SpotifyBridge {
    private let queue = DispatchQueue(label: "dev.lan4ik.needle.spotify")
    private let appURL = SpotifyBridge.locateSpotify()

    static func locateSpotify() -> URL? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Spotify.app"),
            URL(fileURLWithPath: "/Applications/Spotify.app")
        ]
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client")
            ?? candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func scriptLiteral(_ string: String) -> String {
        let escaped = string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static let snapshot = """
        set song to current track
        if song is missing value then return {}
        set coverLink to artwork url of song
        if coverLink is missing value then set coverLink to ""
        return {id of song, name of song, artist of song, coverLink, duration of song, player position, (player state is playing)}
        """

    func read(command: PlayerCommand?, completion: @escaping (Playback) -> Void) {
        queue.async {
            let result = self.readSynchronously(command)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func readSynchronously(_ command: PlayerCommand?) -> Playback {
        guard let appURL else { return .closed }
        let application = Self.scriptLiteral(appURL.path)
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let body = [command?.script, Self.snapshot].compactMap { $0 }.joined(separator: "\n")
        process.arguments = ["-ss", "-e", """
            on clamp(seconds, durationSeconds)
                if seconds < 0 then return 0
                if seconds > durationSeconds then return durationSeconds
                return seconds
            end clamp
            if application \(application) is not running then return "closed"
            with timeout of 3 seconds
                tell application \(application)
                    \(body)
                end tell
            end timeout
            """]
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return .unavailable }
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if error.contains("(-1743)") { return .denied }
        if error.contains("(-1728)") || error.contains("(-1731)") { return command == nil ? .idle : .unavailable }
        guard process.terminationStatus == 0 else { return .unavailable }
        return Self.decode(output)
    }

    // osascript -ss prints an AppleScript source representation. Each track string
    // is quoted, and may itself contain punctuation, quotes and escape sequences.
    static func decode(_ output: String) -> Playback {
        let source = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if source == "\"closed\"" { return .closed }
        if source == "{}" { return .idle }
        guard source.hasPrefix("{"), source.hasSuffix("}") else { return .unavailable }

        var values: [String] = []
        var field = ""
        var quoted = false
        var escaped = false
        for char in source.dropFirst().dropLast() {
            if escaped {
                field.append(char == "n" ? "\n" : char == "r" ? "\r" : char == "t" ? "\t" : char)
                escaped = false
            } else if quoted && char == "\\" {
                escaped = true
            } else if char == "\"" {
                quoted.toggle()
            } else if char == "," && !quoted {
                values.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else {
                field.append(char)
            }
        }
        values.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !quoted, !escaped, values.count == 7,
              let millis = Double(values[4]), millis.isFinite,
              let seconds = Double(values[5]), seconds.isFinite,
              ["true", "false"].contains(values[6]) else { return .unavailable }
        let duration = max(0, millis / 1000)
        let cover = URL(string: values[3]).flatMap { $0.scheme == "https" ? $0 : nil }
        return .track(Track(id: values[0], title: values[1], artist: values[2], artwork: cover,
                            duration: duration, position: min(max(seconds, 0), duration), playing: values[6] == "true"))
    }
}

final class Player: ObservableObject {
    typealias Completion = (Playback) -> Void

    @Published private(set) var playback: Playback = .closed
    /// Seconds between two reads of the Spotify state.
    var interval: TimeInterval = 1 {
        didSet { if interval != oldValue { schedule() } }
    }
    private let bridge = SpotifyBridge()
    private var timer: Timer?
    private var busy = false
    private var pending: [(command: PlayerCommand, completion: Completion?)] = []
    let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            playback = .track(Track(id: "demo", title: "After Hours", artist: "Демонстрация",
                                    artwork: nil, duration: 228, position: 72, playing: true))
        }
        refresh()
        schedule()
    }

    deinit { timer?.invalidate() }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(0.5, interval), repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = interval * 0.2
    }

    /// Queues a command. `completion` receives the playback state read right after the command ran.
    func send(_ command: PlayerCommand, completion: Completion? = nil) {
        if demo, case var .track(track) = playback {
            switch command {
            case .toggle: track.playing.toggle()
            case .previous: track.position = 0
            case .next: track.position = 0
            case let .skip(offset): track.position = min(max(0, track.position + Double(offset)), track.duration)
            case let .seek(seconds, _): track.position = seconds
            }
            playback = .track(track)
            completion?(playback)
            return
        }
        if case .seek = command, let last = pending.last, case .seek = last.command, last.completion == nil {
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

    private func refresh() {
        if demo {
            if case var .track(track) = playback, track.playing {
                track.position = min(track.duration, track.position + interval)
                if track.position == track.duration { track.playing = false }
                playback = .track(track)
            }
            return
        }
        guard !busy else { return }
        busy = true
        let next = pending.isEmpty ? nil : pending.removeFirst()
        bridge.read(command: next?.command) { [weak self] result in
            guard let self else { return }
            if self.pending.isEmpty { self.playback = result }
            self.busy = false
            next?.completion?(result)
            if !self.pending.isEmpty { self.refresh() }
        }
    }
}
