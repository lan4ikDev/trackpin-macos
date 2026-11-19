import SwiftUI

struct RGB: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var color: Color { Color(red: r, green: g, blue: b) }
}

/// Colors sampled from the current album artwork by the host app.
struct ArtworkPalette: Codable, Equatable {
    var top: RGB
    var bottom: RGB
    var accent: RGB
}

enum WidgetTheme: String, Codable, CaseIterable, Identifiable {
    case artwork, blur, system, graphite, plum, forest, ocean, sunset, paper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .artwork: "По обложке"
        case .blur: "Размытая обложка"
        case .system: "Системная"
        case .graphite: "Графит"
        case .plum: "Слива"
        case .forest: "Хвоя"
        case .ocean: "Океан"
        case .sunset: "Закат"
        case .paper: "Бумага"
        }
    }

    /// Resolved colors for drawing. `palette` is used by the artwork based themes,
    /// `scheme` by the system theme.
    func colors(palette: ArtworkPalette?, scheme: ColorScheme) -> ThemeColors {
        switch self {
        case .artwork, .blur:
            guard let palette else { return WidgetTheme.graphite.colors(palette: nil, scheme: scheme) }
            return ThemeColors(background: [palette.top.color, palette.bottom.color], accent: palette.accent.color,
                               dark: true, artworkBackground: self == .blur)
        case .system:
            return scheme == .dark
                ? ThemeColors(background: [Color(white: 0.17), Color(white: 0.11)], accent: Color(red: 0.12, green: 0.84, blue: 0.38), dark: true)
                : ThemeColors(background: [Color(white: 0.98), Color(white: 0.91)], accent: Color(red: 0.07, green: 0.62, blue: 0.27), dark: false)
        case .graphite:
            return ThemeColors(background: [Color(red: 0.19, green: 0.22, blue: 0.25), Color(red: 0.09, green: 0.11, blue: 0.13)],
                               accent: Color(red: 0.72, green: 0.87, blue: 1), dark: true)
        case .plum:
            return ThemeColors(background: [Color(red: 0.27, green: 0.16, blue: 0.29), Color(red: 0.14, green: 0.08, blue: 0.18)],
                               accent: Color(red: 1, green: 0.76, blue: 0.91), dark: true)
        case .forest:
            return ThemeColors(background: [Color(red: 0.13, green: 0.25, blue: 0.20), Color(red: 0.06, green: 0.14, blue: 0.11)],
                               accent: Color(red: 0.70, green: 0.96, blue: 0.80), dark: true)
        case .ocean:
            return ThemeColors(background: [Color(red: 0.07, green: 0.24, blue: 0.38), Color(red: 0.03, green: 0.10, blue: 0.20)],
                               accent: Color(red: 0.55, green: 0.90, blue: 1), dark: true)
        case .sunset:
            return ThemeColors(background: [Color(red: 0.55, green: 0.22, blue: 0.20), Color(red: 0.24, green: 0.08, blue: 0.20)],
                               accent: Color(red: 1, green: 0.82, blue: 0.55), dark: true)
        case .paper:
            return ThemeColors(background: [Color(red: 0.99, green: 0.97, blue: 0.93), Color(red: 0.93, green: 0.90, blue: 0.84)],
                               accent: Color(red: 0.85, green: 0.35, blue: 0.20), dark: false)
        }
    }
}

struct ThemeColors {
    var background: [Color]
    var accent: Color
    var dark: Bool
    /// Draw the blurred cover behind the content instead of the gradient.
    var artworkBackground = false

    var primary: Color { dark ? .white : Color.black.opacity(0.86) }
    var secondary: Color { primary.opacity(dark ? 0.68 : 0.6) }
    /// Foreground of the filled play button.
    var onAccent: Color { dark ? Color.black.opacity(0.86) : .white }
    var gradient: LinearGradient {
        LinearGradient(colors: background, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
