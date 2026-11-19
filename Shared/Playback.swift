import Foundation

struct Track: Codable, Equatable {
    let id: String
    let title: String
    let artist: String
    let artwork: URL?
    let duration: Double
    var position: Double
    var playing: Bool
    /// Player settings read together with the track. Optional, so snapshots cached by
    /// older versions still decode.
    var volume: Int? = nil
    var shuffling: Bool? = nil
    var repeating: Bool? = nil

    /// A link to the track on open.spotify.com, for `spotify:track:<id>` identifiers.
    var webLink: URL? {
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify" else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }
}

enum Playback: Codable, Equatable {
    case closed, idle, denied, unavailable
    case track(Track)

    var currentTrack: Track? {
        if case let .track(track) = self { return track }
        return nil
    }
}

/// Everything the widget needs to draw itself. The host app builds it and
/// hands it to the widget extension over the loopback transport.
struct WidgetSnapshot: Codable, Equatable {
    var playback: Playback
    var sampledAt: Date
    var cover: Data?
    var palette: ArtworkPalette?
    var style: WidgetStyle

    /// `sampledAt == .distantPast` means the host app has never answered.
    static let offline = WidgetSnapshot(playback: .closed, sampledAt: .distantPast,
                                        cover: nil, palette: nil, style: WidgetStyle())

    var hostReachable: Bool { sampledAt != .distantPast }

    static var preview: WidgetSnapshot {
        WidgetSnapshot(
            playback: .track(Track(id: "preview", title: "After Hours", artist: "TrackPin",
                                   artwork: nil, duration: 228, position: 74, playing: true)),
            sampledAt: .now, cover: nil,
            palette: ArtworkPalette(top: RGB(r: 0.36, g: 0.20, b: 0.42), bottom: RGB(r: 0.12, g: 0.08, b: 0.20),
                                    accent: RGB(r: 1, g: 0.78, b: 0.93)),
            style: WidgetStyle()
        )
    }
}
