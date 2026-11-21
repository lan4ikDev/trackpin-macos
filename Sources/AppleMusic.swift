import AppKit

/// Talks to the Music app (Apple Music) through AppleScript.
///
/// Music posts `com.apple.Music.playerInfo` on play, pause and track changes. It has no
/// artwork URL, so the cover is read as image data once per track and written to the caches
/// folder; `Artwork.load` reads it from there like a downloaded cover.
final class AppleMusicBridge: PlayerBackend {
    static let bundleIdentifier = "com.apple.Music"

    let source = MusicSource.appleMusic
    let bundleIdentifiers = [AppleMusicBridge.bundleIdentifier]
    let changeNotifications = ["com.apple.Music.playerInfo"]

    /// Only touched on the player queue.
    private var snapshotScript: NSAppleScript?
    private var coverTrackID: String?
    private var coverFile: URL?
    /// Covers left over from an earlier run are removed once, before the first new one is
    /// written; within a run each cover is deleted when the track changes.
    private var removedOldCovers = false

    var isAvailable: Bool { Self.runningApp(bundleIdentifiers) != nil }

    func open() {
        Self.openApp(bundleIdentifiers, fallback: "https://music.apple.com")
    }

    private static func wrap(_ body: String) -> String {
        AppleScript.wrap(body, bundleIdentifier: bundleIdentifier)
    }

    /// Radio streams have no duration; the persistent ID identifies a track for the seek check.
    private static let snapshotSource = wrap("""
        if player state is stopped then return {}
        set song to current track
        set songLength to duration of song
        if songLength is missing value then set songLength to 0
        set songArtist to artist of song
        if songArtist is missing value then set songArtist to ""
        return {persistent ID of song, name of song, songArtist, "", songLength, player position, (player state is playing), sound volume, shuffle enabled, (song repeat is not off)}
        """)

    private static let coverSource = wrap("""
        set song to current track
        if (count of artworks of song) is 0 then return {persistent ID of song, ""}
        return {persistent ID of song, raw data of artwork 1 of song}
        """)

    static let idPrefix = "music:"

    static func script(for command: PlayerCommand) -> String {
        switch command {
        case .previous: return "previous track"
        case .toggle: return "playpause"
        case .pause: return "pause"
        case .next: return "next track"
        case let .skip(offset):
            return """
            set targetPosition to (player position) + \(offset)
            set trackLength to duration of current track
            if targetPosition < 0 then set targetPosition to 0
            if trackLength is not missing value and targetPosition > trackLength then set targetPosition to trackLength
            set player position to targetPosition
            """
        case let .seek(seconds, id):
            let persistentID = id.hasPrefix(idPrefix) ? String(id.dropFirst(idPrefix.count)) : id
            return """
            if (persistent ID of current track) is \(AppleScript.literal(persistentID)) then
                set player position to \(max(0, seconds))
            end if
            """
        case let .volume(level): return "set sound volume to \(min(max(level, 0), 100))"
        case let .shuffle(on): return "set shuffle enabled to \(on)"
        case let .repeating(on): return "set song repeat to \(on ? "all" : "off")"
        }
    }

    func read(command: PlayerCommand?) -> Playback {
        // `tell application` would start Music.
        guard Self.runningApp(bundleIdentifiers) != nil else { return .closed }
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
        let decoded = AppleScript.decodeTrack(result, idPrefix: Self.idPrefix, millis: false)
        guard let track = decoded.currentTrack else { return decoded }
        return .track(Track(id: track.id, title: track.title, artist: track.artist, artwork: cover(for: track.id),
                      duration: track.duration, position: track.position, playing: track.playing,
                      volume: track.volume, shuffling: track.shuffling, repeating: track.repeating))
    }

    /// The cover of the current track as a file, read once per track.
    private func cover(for trackID: String) -> URL? {
        if trackID == coverTrackID { return coverFile }
        coverTrackID = trackID
        if let old = coverFile { try? FileManager.default.removeItem(at: old) }
        coverFile = nil
        // The id comes with the artwork in one call: the track may change between the snapshot
        // read and this one, and the next track's cover must not be saved under this id.
        let (result, _) = AppleScript.run(Self.coverSource)
        guard let result, result.numberOfItems == 2,
              Self.idPrefix + (result.atIndex(1)?.stringValue ?? "") == trackID || result.atIndex(1)?.stringValue == trackID else {
            coverTrackID = nil // Try again on the next read.
            return nil
        }
        guard let artwork = result.atIndex(2), artwork.descriptorType != typeUnicodeText else { return nil }
        let data = artwork.data
        guard data.count > 64 else { return nil }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "TrackPin", isDirectory: true)
            .appendingPathComponent("MusicArtwork", isDirectory: true)
        if !removedOldCovers {
            removedOldCovers = true
            try? FileManager.default.removeItem(at: folder)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The name changes with the track, so the publisher sees a new URL and loads it.
        let safe = trackID.filter { $0.isLetter || $0.isNumber }
        let file = folder.appendingPathComponent("\(safe)-\(UUID().uuidString.prefix(8)).img")
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        coverFile = file
        return file
    }
}
