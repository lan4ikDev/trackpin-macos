import Foundation
import ServiceManagement

/// What a click on the widget outside of its buttons does.
enum TapAction: String, CaseIterable, Identifiable {
    case spotify, player, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spotify: "Открыть Spotify"
        case .player: "Открыть плеер TrackPin"
        case .settings: "Открыть настройки TrackPin"
        }
    }
}

final class Preferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var style: WidgetStyle {
        didSet { if let data = try? JSONEncoder().encode(style) { defaults.set(data, forKey: Key.style) } }
    }
    /// Seconds between two reads of the Spotify state.
    @Published var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
    }
    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }
    @Published var tapAction: TapAction {
        didSet { defaults.set(tapAction.rawValue, forKey: Key.tapAction) }
    }
    /// The play button starts Spotify when it is not running.
    @Published var launchSpotifyOnPlay: Bool {
        didSet { defaults.set(launchSpotifyOnPlay, forKey: Key.launchSpotifyOnPlay) }
    }
    @Published var didOnboard: Bool {
        didSet { defaults.set(didOnboard, forKey: Key.didOnboard) }
    }

    static let refreshIntervals: [Double] = [1, 2, 5]

    private enum Key {
        static let style = "widgetStyle"
        static let refreshInterval = "refreshInterval"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let tapAction = "tapAction"
        static let launchSpotifyOnPlay = "launchSpotifyOnPlay"
        static let didOnboard = "didOnboard"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.style), let saved = try? JSONDecoder().decode(WidgetStyle.self, from: data) {
            style = saved
        } else {
            // Settings of TrackPin 2.x.
            var migrated = WidgetStyle()
            if let theme = defaults.string(forKey: "theme").flatMap(WidgetTheme.init(rawValue:)) { migrated.theme = theme }
            if let showTime = defaults.object(forKey: "showTime") as? Bool { migrated.showTime = showTime }
            style = migrated
        }
        let interval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval = Self.refreshIntervals.contains(interval) ? interval : 1
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        tapAction = defaults.string(forKey: Key.tapAction).flatMap(TapAction.init(rawValue:)) ?? .spotify
        launchSpotifyOnPlay = defaults.object(forKey: Key.launchSpotifyOnPlay) as? Bool ?? true
        didOnboard = defaults.bool(forKey: Key.didOnboard)
    }

    func resetStyle() { style = WidgetStyle() }
}

/// Start TrackPin at login through the system "Login Items" list.
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message, or nil on success.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
