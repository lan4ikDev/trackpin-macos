import Foundation

/// One track TrackPin saw playing.
struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let trackID: String
    let title: String
    let artist: String
    let artwork: URL?
    var playedAt: Date

    /// A link to the track on open.spotify.com, for `spotify:track:<id>` identifiers.
    var webLink: URL? {
        Track(id: trackID, title: title, artist: artist, artwork: artwork, duration: 0, position: 0, playing: false).webLink
    }

    /// Spotify can play it again: local files and ads have no playable URI.
    var playable: Bool { trackID.hasPrefix("spotify:track:") || trackID.hasPrefix("spotify:episode:") }
}

/// Recently played tracks, recorded by TrackPin itself.
///
/// Spotify's AppleScript dictionary has no history, so TrackPin writes down every track it
/// sees playing. Tracks played while TrackPin was not running are missing. The list is kept in
/// `~/Library/Application Support/TrackPin/history.json` and capped at `limit` entries.
@MainActor
final class PlayHistory: ObservableObject {
    static let limit = 100

    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL?
    private var saveWork: DispatchWorkItem?
    private static let ioQueue = DispatchQueue(label: "dev.lan4ik.needle.history", qos: .utility)

    /// `fileURL == nil` keeps the history in memory only (previews, demo mode).
    init(fileURL: URL? = PlayHistory.defaultURL) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = Array(saved.prefix(Self.limit))
        }
    }

    nonisolated static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TrackPin", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    /// Notes that `track` is playing. Called for every read of a playing track: reads of the
    /// same play are ignored, and the same track playing again right after itself (repeat one,
    /// a long pause) moves the latest entry's time instead of adding a second one.
    func record(_ track: Track) {
        guard track.playing, !track.id.isEmpty, !track.id.hasPrefix("spotify:ad:") else { return }
        if var latest = entries.first, latest.trackID == track.id {
            // Repeat one: count it again once the previous play is well over.
            if Date().timeIntervalSince(latest.playedAt) < max(track.duration, 60) { return }
            latest.playedAt = Date()
            entries[0] = latest
        } else {
            entries.insert(HistoryEntry(trackID: track.id, title: track.title, artist: track.artist,
                                        artwork: track.artwork, playedAt: Date()), at: 0)
            if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        }
        scheduleSave()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    func clear() {
        entries = []
        scheduleSave()
    }

    /// Plays the track in Spotify again.
    func play(_ entry: HistoryEntry) {
        guard entry.playable else { return }
        SpotifyScript.play(uri: entry.trackID)
    }

    /// Writes at most once every few seconds, off the main thread.
    private func scheduleSave() {
        guard let fileURL else { return }
        saveWork?.cancel()
        let snapshot = entries
        let work = DispatchWorkItem {
            Self.ioQueue.async {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Writes pending changes right away, for quitting.
    func flush() {
        guard let work = saveWork else { return }
        saveWork = nil
        work.cancel()
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// One-off scripts that run outside the `Player` command queue.
enum SpotifyScript {
    private static let queue = DispatchQueue(label: "dev.lan4ik.needle.spotify-play", qos: .userInitiated)

    /// Plays `uri` in the Spotify app. Works without Spotify Premium. Does nothing while Spotify
    /// is closed, because `tell application` would launch it without asking.
    static func play(uri: String) {
        guard SpotifyBridge.isRunning, uri.hasPrefix("spotify:") else { return }
        let source = """
        with timeout of 3 seconds
            tell application id "\(SpotifyBridge.bundleIdentifier)" to play track \(AppleScript.literal(uri))
        end timeout
        """
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("TrackPin play track: %@", error) }
        }
    }
}
