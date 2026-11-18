import Foundation

struct Track: Codable, Equatable {
    let id: String
    let title: String
    let artist: String
    let artwork: URL?
    let duration: Double
    var position: Double
    var playing: Bool
}

enum Playback: Codable, Equatable {
    case closed, idle, denied, unavailable
    case track(Track)
}

struct WidgetSnapshot: Codable {
    let playback: Playback
    let sampledAt: Date
    let cover: Data?
    let theme: WidgetTheme
    let showTime: Bool

    static let offline = WidgetSnapshot(playback: .closed, sampledAt: .distantPast,
                                        cover: nil, theme: .graphite, showTime: true)
}
