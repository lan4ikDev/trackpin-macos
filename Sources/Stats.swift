import Foundation

/// Listening time by day and artist, counted by TrackPin itself from what it sees playing.
///
/// Time is taken from the track position, not the clock: between two reads of the same
/// playing track the position difference is added (capped by the time that passed, so a
/// seek forward does not count), and when the track changes, the rest of the previous one
/// up to where it should have ended. Kept for 60 days in
/// `~/Library/Application Support/TrackPin/stats.json`.
@MainActor
final class ListeningStats: ObservableObject {
    struct Day: Codable, Equatable {
        /// Seconds by artist.
        var artists: [String: Double] = [:]
        /// Plays by "title — artist".
        var tracks: [String: Int] = [:]
        var total: Double { artists.values.reduce(0, +) }
    }

    /// Days by "yyyy-MM-dd" in the user's time zone.
    @Published private(set) var days: [String: Day] = [:]

    private let fileURL: URL?
    private var saveWork: DispatchWorkItem?
    private var last: (track: Track, at: Date)?
    private static let keep = 60
    private static let ioQueue = DispatchQueue(label: "dev.lan4ik.needle.stats", qos: .utility)

    init(fileURL: URL? = ListeningStats.defaultURL) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Day].self, from: data) {
            days = saved
        }
    }

    nonisolated static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TrackPin", isDirectory: true)
            .appendingPathComponent("stats.json")
    }

    static func key(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Called with every playback state TrackPin reads.
    func observe(_ playback: Playback, at now: Date = Date()) {
        let current = playback.currentTrack
        defer { last = current.map { ($0, now) } }
        guard let previous = last, previous.track.playing else {
            if let current, current.playing, current.id != last?.track.id { countPlay(current, at: now) }
            return
        }
        let elapsed = max(0, now.timeIntervalSince(previous.at))
        var listened: Double
        if let current, current.id == previous.track.id {
            listened = current.position - previous.track.position
            if listened < 0 { listened = 0 } // Seeked back or repeat one: count nothing for this gap.
        } else {
            // The previous track played on until it ended or was switched.
            listened = max(0, previous.track.duration - previous.track.position)
            if let current, current.playing { countPlay(current, at: now) }
        }
        add(min(listened, elapsed + 2), artist: previous.track.artist, at: now)
    }

    private func countPlay(_ track: Track, at date: Date) {
        guard !track.title.isEmpty else { return }
        let key = Self.key(for: date)
        days[key, default: Day()].tracks["\(track.title) — \(track.artist)", default: 0] += 1
        scheduleSave()
    }

    private func add(_ seconds: Double, artist: String, at date: Date) {
        guard seconds >= 1 else { return }
        let key = Self.key(for: date)
        let name = artist.isEmpty ? "?" : artist
        days[key, default: Day()].artists[name, default: 0] += seconds
        scheduleSave()
    }

    // MARK: Summaries

    /// The last 7 days, oldest first, including today.
    func week(ending date: Date = Date()) -> [(date: Date, day: Day)] {
        (0..<7).reversed().compactMap { offset in
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: date) else { return nil }
            return (day, days[Self.key(for: day)] ?? Day())
        }
    }

    func topArtists(in week: [(date: Date, day: Day)], limit: Int = 5) -> [(name: String, seconds: Double)] {
        var totals: [String: Double] = [:]
        for entry in week { for (artist, seconds) in entry.day.artists { totals[artist, default: 0] += seconds } }
        return totals.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }

    func topTracks(in week: [(date: Date, day: Day)], limit: Int = 5) -> [(name: String, plays: Int)] {
        var totals: [String: Int] = [:]
        for entry in week { for (track, plays) in entry.day.tracks { totals[track, default: 0] += plays } }
        return totals.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }

    func clear() {
        days = [:]
        scheduleSave()
    }

    // MARK: Saving

    private func scheduleSave() {
        guard let fileURL else { return }
        saveWork?.cancel()
        // Drop days older than `keep`.
        if days.count > Self.keep {
            let cutoff = Self.key(for: Calendar.current.date(byAdding: .day, value: -Self.keep, to: Date()) ?? Date())
            days = days.filter { $0.key >= cutoff }
        }
        let snapshot = days
        let work = DispatchWorkItem {
            Self.ioQueue.async {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Writes pending changes right away, for quitting.
    func flush() {
        guard let fileURL, saveWork != nil else { return }
        saveWork?.cancel()
        saveWork = nil
        guard let data = try? JSONEncoder().encode(days) else { return }
        // After any scheduled save still running, so an older one cannot overwrite this.
        Self.ioQueue.sync {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
