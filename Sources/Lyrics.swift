import CryptoKit
import Foundation

/// One line of synced lyrics: when it starts, in seconds from the start of the track.
struct LyricLine: Equatable, Identifiable {
    let id: Int
    let time: Double
    let text: String
}

enum Lyrics: Equatable {
    /// Lines with timestamps, sorted by time.
    case synced([LyricLine])
    /// Text without timestamps.
    case plain(String)
    case instrumental
    case notFound

    /// The index of the line that is sung at `position`, or nil before the first line.
    static func currentLine(in lines: [LyricLine], at position: Double) -> Int? {
        // Light up a line a moment early: it reads better than a late one.
        let time = position + 0.25
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    /// Parses LRC text: `[mm:ss.xx] line`, several timestamps per line allowed, tags such
    /// as `[ar:Artist]` ignored.
    static func parseLRC(_ text: String) -> [LyricLine] {
        var timed: [(time: Double, text: String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw).drop(while: \.isWhitespace)
            var times: [Double] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                guard let time = seconds(rest[rest.index(after: rest.startIndex)..<close]) else { break }
                times.append(time)
                rest = rest[rest.index(after: close)...]
            }
            let line = rest.trimmingCharacters(in: .whitespaces)
            for time in times { timed.append((time, line)) }
        }
        timed.sort { $0.time < $1.time }
        return timed.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }

    private static func seconds(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]),
              let seconds = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
              minutes >= 0, seconds >= 0 else { return nil }
        return minutes * 60 + seconds
    }
}

/// Loads lyrics for the track in the mini player and keeps them in memory and on disk.
@MainActor
final class LyricsStore: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded(Lyrics)
        case failed
    }

    @Published private(set) var phase: Phase = .loading
    /// The track `phase` belongs to.
    @Published private(set) var key: String?
    private var memory: [String: Lyrics] = [:]
    private var task: Task<Void, Never>?

    /// The track's identity for lyrics. Not the duration: Yandex Music shows the remaining time,
    /// so the duration TrackPin derives from it can move by a second between reads, which would
    /// reload the lyrics and reset their scroll each time.
    static func key(for track: Track) -> String {
        "\(track.id)\n\(track.artist.lowercased())\n\(track.title.lowercased())"
    }

    /// What to show for `track`: `.loading` until `load` finished for this very track.
    func phase(for track: Track) -> Phase {
        key == Self.key(for: track) ? phase : .loading
    }

    func load(_ track: Track, force: Bool = false) {
        let key = Self.key(for: track)
        guard force || key != self.key || phase == .failed else { return }
        task?.cancel()
        self.key = key
        if let cached = memory[key] {
            phase = .loaded(cached)
            return
        }
        phase = .loading
        let title = track.title, artist = track.artist, duration = track.duration
        task = Task { [weak self] in
            let result = await LRCLIB.lyrics(title: title, artist: artist, duration: duration, key: key)
            guard !Task.isCancelled, let self, self.key == key else { return }
            if let result {
                self.memory[key] = result
                self.phase = .loaded(result)
            } else {
                self.phase = .failed
            }
        }
    }
}

/// lrclib.net: a free lyrics database with synced lyrics, no account or key needed.
enum LRCLIB {
    private struct Record: Codable {
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?

        var lyrics: Lyrics {
            if let synced = syncedLyrics, case let lines = Lyrics.parseLRC(synced), !lines.isEmpty {
                return .synced(lines)
            }
            if let plain = plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
                return .plain(plain)
            }
            return instrumental == true ? .instrumental : .notFound
        }

        var hasText: Bool {
            !(syncedLyrics ?? "").isEmpty || !(plainLyrics ?? "").isEmpty
        }
    }

    /// What is stored on disk. `record == nil`: lrclib has nothing for the track.
    private struct Entry: Codable {
        var record: Record?
        var savedAt: Date
    }

    private static let base = URL(string: "https://lrclib.net/api/")!
    /// A missing track may be added to lrclib later: ask again after this long.
    private static let notFoundLifetime: TimeInterval = 3 * 24 * 3600

    /// Returns nil when lrclib could not be reached.
    static func lyrics(title: String, artist: String, duration: Double, key: String) async -> Lyrics? {
        let file = cacheFile(for: key)
        if let file, let data = try? Data(contentsOf: file),
           let entry = try? JSONDecoder().decode(Entry.self, from: data),
           entry.record != nil || Date().timeIntervalSince(entry.savedAt) < notFoundLifetime {
            return entry.record?.lyrics ?? .notFound
        }
        do {
            let record = try await find(title: title, artist: artist, duration: duration)
            if let file, let data = try? JSONEncoder().encode(Entry(record: record, savedAt: Date())) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            return record?.lyrics ?? .notFound
        } catch {
            return nil
        }
    }

    private static func find(title: String, artist: String, duration: Double) async throws -> Record? {
        // The exact match first, then a search with "- Remastered", "(feat. …)" and the like removed.
        if let record = try await get(title: title, artist: artist, duration: duration), record.hasText || record.instrumental == true {
            return record
        }
        let simple = simplified(title)
        let candidates = try await search(title: simple, artist: artist)
        let close = candidates.filter { record in
            guard duration > 0, let length = record.duration else { return true }
            return abs(length - duration) <= 5
        }
        return close.first { !($0.syncedLyrics ?? "").isEmpty }
            ?? close.first { !($0.plainLyrics ?? "").isEmpty }
            ?? close.first { $0.instrumental == true }
    }

    private static func get(title: String, artist: String, duration: Double) async throws -> Record? {
        var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        guard let (data, status) = try await request("get", items) else { return nil }
        if status == 404 || status == 400 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func search(title: String, artist: String) async throws -> [Record] {
        let items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        guard let (data, status) = try await request("search", items) else { return [] }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private static func request(_ path: String, _ items: [URLQueryItem]) async throws -> (Data, Int)? {
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3"
        // lrclib asks clients to name themselves.
        request.setValue("TrackPin \(version) (https://github.com/lan4ikDev/trackpin-macos)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// "Song - Remastered 2011" → "Song", "Song (feat. X)" → "Song".
    static func simplified(_ title: String) -> String {
        var result = title
        if let dash = result.range(of: " - ") { result = String(result[..<dash.lowerBound]) }
        for marker in ["(feat", "(with", "(ft.", "[feat", "(Remaster", "(Live"] {
            if let range = result.range(of: marker, options: .caseInsensitive) {
                result = String(result[..<range.lowerBound])
            }
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    private static func cacheFile(for key: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "TrackPin", isDirectory: true)
            .appendingPathComponent("Lyrics", isDirectory: true)
        return folder.appendingPathComponent(name + ".json")
    }
}
