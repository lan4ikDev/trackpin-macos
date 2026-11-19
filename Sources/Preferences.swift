import Foundation
import CoreGraphics
import ServiceManagement

/// What a click on the widget outside of its buttons does.
enum TapAction: String, CaseIterable, Identifiable {
    case spotify, player, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spotify: "Открыть Spotify"
        case .player: "Открыть мини-плеер"
        case .settings: "Открыть настройки TrackPin"
        }
    }
}

enum PopupSize: String, CaseIterable, Identifiable {
    case compact, regular, large
    var id: String { rawValue }
    var width: CGFloat {
        switch self {
        case .compact: 248
        case .regular: 296
        case .large: 352
        }
    }
    var title: String {
        switch self {
        case .compact: "Компактный"
        case .regular: "Обычный"
        case .large: "Большой"
        }
    }
}

enum PopupBackground: String, CaseIterable, Identifiable {
    /// The blurred album cover.
    case artwork
    /// The widget theme's gradient.
    case theme
    /// Translucent system material.
    case glass
    var id: String { rawValue }
    var title: String {
        switch self {
        case .artwork: "Размытая обложка"
        case .theme: "Тема виджета"
        case .glass: "Стекло"
        }
    }
}

enum PopupPlacement: String, CaseIterable, Identifiable {
    case cursor, center
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cursor: "Рядом с курсором"
        case .center: "По центру экрана"
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
    /// Seconds between two reads of a playing track while no TrackPin window is open. 0: only
    /// when Spotify reports a change.
    @Published var backgroundInterval: Double {
        didSet { defaults.set(backgroundInterval, forKey: Key.backgroundInterval) }
    }
    @Published var menuBarTitle: Bool {
        didSet { defaults.set(menuBarTitle, forKey: Key.menuBarTitle) }
    }
    @Published var hotKey: Bool {
        didSet { defaults.set(hotKey, forKey: Key.hotKey) }
    }
    @Published var popupSize: PopupSize {
        didSet { defaults.set(popupSize.rawValue, forKey: Key.popupSize) }
    }
    @Published var popupBackground: PopupBackground {
        didSet { defaults.set(popupBackground.rawValue, forKey: Key.popupBackground) }
    }
    @Published var popupPlacement: PopupPlacement {
        didSet { defaults.set(popupPlacement.rawValue, forKey: Key.popupPlacement) }
    }
    @Published var popupAnimated: Bool {
        didSet { defaults.set(popupAnimated, forKey: Key.popupAnimated) }
    }
    @Published var popupClosesOnClickOutside: Bool {
        didSet { defaults.set(popupClosesOnClickOutside, forKey: Key.popupClosesOnClickOutside) }
    }
    @Published var popupShowsVolume: Bool {
        didSet { defaults.set(popupShowsVolume, forKey: Key.popupShowsVolume) }
    }
    @Published var popupShowsModes: Bool {
        didSet { defaults.set(popupShowsModes, forKey: Key.popupShowsModes) }
    }
    @Published var popupCoverShape: ArtworkShape {
        didSet { defaults.set(popupCoverShape.rawValue, forKey: Key.popupCoverShape) }
    }
    @Published var didOnboard: Bool {
        didSet { defaults.set(didOnboard, forKey: Key.didOnboard) }
    }

    static let refreshIntervals: [Double] = [1, 2, 5]
    static let backgroundIntervals: [Double] = [0, 30, 120]

    private enum Key {
        static let style = "widgetStyle"
        static let refreshInterval = "refreshInterval"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let tapAction = "tapAction"
        static let launchSpotifyOnPlay = "launchSpotifyOnPlay"
        static let didOnboard = "didOnboard"
        static let backgroundInterval = "backgroundInterval"
        static let menuBarTitle = "menuBarTitle"
        static let hotKey = "hotKey"
        static let popupSize = "popupSize"
        static let popupBackground = "popupBackground"
        static let popupPlacement = "popupPlacement"
        static let popupAnimated = "popupAnimated"
        static let popupClosesOnClickOutside = "popupClosesOnClickOutside"
        static let popupShowsVolume = "popupShowsVolume"
        static let popupShowsModes = "popupShowsModes"
        static let popupCoverShape = "popupCoverShape"
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
        tapAction = defaults.string(forKey: Key.tapAction).flatMap(TapAction.init(rawValue:)) ?? .player
        launchSpotifyOnPlay = defaults.object(forKey: Key.launchSpotifyOnPlay) as? Bool ?? true
        didOnboard = defaults.bool(forKey: Key.didOnboard)
        let background = defaults.object(forKey: Key.backgroundInterval) as? Double ?? 30
        backgroundInterval = Self.backgroundIntervals.contains(background) ? background : 30
        menuBarTitle = defaults.bool(forKey: Key.menuBarTitle)
        hotKey = defaults.object(forKey: Key.hotKey) as? Bool ?? true
        popupSize = defaults.string(forKey: Key.popupSize).flatMap(PopupSize.init(rawValue:)) ?? .regular
        popupBackground = defaults.string(forKey: Key.popupBackground).flatMap(PopupBackground.init(rawValue:)) ?? .artwork
        popupPlacement = defaults.string(forKey: Key.popupPlacement).flatMap(PopupPlacement.init(rawValue:)) ?? .cursor
        popupAnimated = defaults.object(forKey: Key.popupAnimated) as? Bool ?? true
        popupClosesOnClickOutside = defaults.object(forKey: Key.popupClosesOnClickOutside) as? Bool ?? true
        popupShowsVolume = defaults.object(forKey: Key.popupShowsVolume) as? Bool ?? true
        popupShowsModes = defaults.object(forKey: Key.popupShowsModes) as? Bool ?? true
        popupCoverShape = defaults.string(forKey: Key.popupCoverShape).flatMap(ArtworkShape.init(rawValue:)) ?? .rounded
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
