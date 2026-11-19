import SwiftUI

/// Which playback buttons the widget shows.
enum ControlSet: String, Codable, CaseIterable, Identifiable {
    /// Previous, play/pause, next.
    case tracks
    /// Rewind, play/pause, fast forward.
    case seek
    /// Previous, rewind, play/pause, fast forward, next (falls back to `tracks` on the small widget).
    case full

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tracks: "Треки"
        case .seek: "Перемотка"
        case .full: "Всё сразу"
        }
    }
}

enum ArtworkShape: String, Codable, CaseIterable, Identifiable {
    case rounded, square, circle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rounded: "Скруглённая"
        case .square: "Квадратная"
        case .circle: "Пластинка"
        }
    }
}

/// Look of the widget, chosen in the TrackPin settings window.
struct WidgetStyle: Codable, Equatable {
    var theme: WidgetTheme = .artwork
    var controls: ControlSet = .tracks
    var seekStep: Int = 15
    var artwork: ArtworkShape = .rounded
    var showHeader = true
    var showArtist = true
    var showProgress = true
    var showTime = true
    /// Colors of the "custom" theme, made in the theme editor.
    var customTheme: CustomTheme = .default
    /// Opacity of the widget background, 0.2 to 1. Text and buttons stay opaque.
    var opacity: Double = 1
    /// Volume buttons on the medium and large widget.
    var showVolume = true
    /// Rewind and fast forward buttons around the progress bar on the medium and large widget.
    var seekAroundProgress = true

    static let opacityRange = 0.2...1.0

    static let seekSteps = [5, 10, 15, 30]

    init() {}

    // Decode field by field so that settings saved by an older version keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = WidgetStyle()
        theme = (try? c.decode(WidgetTheme.self, forKey: .theme)) ?? fallback.theme
        controls = (try? c.decode(ControlSet.self, forKey: .controls)) ?? fallback.controls
        seekStep = (try? c.decode(Int.self, forKey: .seekStep)) ?? fallback.seekStep
        artwork = (try? c.decode(ArtworkShape.self, forKey: .artwork)) ?? fallback.artwork
        showHeader = (try? c.decode(Bool.self, forKey: .showHeader)) ?? fallback.showHeader
        showArtist = (try? c.decode(Bool.self, forKey: .showArtist)) ?? fallback.showArtist
        showProgress = (try? c.decode(Bool.self, forKey: .showProgress)) ?? fallback.showProgress
        showTime = (try? c.decode(Bool.self, forKey: .showTime)) ?? fallback.showTime
        customTheme = (try? c.decode(CustomTheme.self, forKey: .customTheme)) ?? fallback.customTheme
        opacity = (try? c.decode(Double.self, forKey: .opacity)).map { min(max($0, Self.opacityRange.lowerBound), 1) } ?? fallback.opacity
        showVolume = (try? c.decode(Bool.self, forKey: .showVolume)) ?? fallback.showVolume
        seekAroundProgress = (try? c.decode(Bool.self, forKey: .seekAroundProgress)) ?? fallback.seekAroundProgress
        if !Self.seekSteps.contains(seekStep) { seekStep = fallback.seekStep }
    }

    /// Colors of the chosen theme, including the custom one.
    func colors(palette: ArtworkPalette?, scheme: ColorScheme) -> ThemeColors {
        theme.colors(palette: palette, scheme: scheme, custom: customTheme)
    }
}
