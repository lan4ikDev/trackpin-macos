import SwiftUI

struct RGB: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var color: Color { Color(red: r, green: g, blue: b) }
}

extension RGB {
    /// Reads `#RRGGBB` (the `#` is optional).
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(r: Double((value >> 16) & 0xFF) / 255, g: Double((value >> 8) & 0xFF) / 255, b: Double(value & 0xFF) / 255)
    }

    var hex: String {
        func byte(_ channel: Double) -> Int { Int((min(max(channel, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// Relative luminance, 0 (black) to 1 (white).
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

/// A theme made in the TrackPin theme editor. It is stored with the widget style and is
/// also the format of an exported theme file:
///
///     {"format": "trackpin-theme", "version": 1, "name": "Ночь",
///      "top": "#1E2A38", "bottom": "#0B1220", "accent": "#8CE6FF"}
struct CustomTheme: Codable, Equatable {
    var name: String
    var top: RGB
    var bottom: RGB
    var accent: RGB

    static let format = "trackpin-theme"

    static let `default` = CustomTheme(name: String(localized: "Моя тема"),
                                       // Hex values, so the theme survives a round trip through a theme file unchanged.
                                       top: RGB(hex: "#293352")!,
                                       bottom: RGB(hex: "#0F1224")!,
                                       accent: RGB(hex: "#FF8C6B")!)

    /// Light text on a dark background, or dark text on a light one, picked from the background.
    var dark: Bool { (top.luminance + bottom.luminance) / 2 < 0.55 }

    var colors: ThemeColors {
        ThemeColors(background: [top.color, bottom.color], accent: accent.color, dark: dark)
    }

    init(name: String, top: RGB, bottom: RGB, accent: RGB) {
        self.name = name
        self.top = top
        self.bottom = bottom
        self.accent = accent
    }

    private enum CodingKeys: String, CodingKey { case format, version, name, top, bottom, accent }

    struct InvalidFile: LocalizedError {
        var errorDescription: String? { String(localized: "Это не файл темы TrackPin или в нём неверные цвета.") }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let format = try c.decodeIfPresent(String.self, forKey: .format), format != Self.format { throw InvalidFile() }
        func color(_ key: CodingKeys) throws -> RGB {
            guard let rgb = RGB(hex: try c.decode(String.self, forKey: key)) else { throw InvalidFile() }
            return rgb
        }
        top = try color(.top)
        bottom = try color(.bottom)
        accent = try color(.accent)
        let decodedName = (try? c.decode(String.self, forKey: .name))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        name = decodedName.isEmpty ? Self.default.name : String(decodedName.prefix(40))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.format, forKey: .format)
        try c.encode(1, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encode(top.hex, forKey: .top)
        try c.encode(bottom.hex, forKey: .bottom)
        try c.encode(accent.hex, forKey: .accent)
    }

    /// Pretty JSON for a theme file.
    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func importing(_ data: Data) throws -> CustomTheme {
        do { return try JSONDecoder().decode(CustomTheme.self, from: data) } catch { throw InvalidFile() }
    }
}

/// Colors sampled from the current album artwork by the host app.
struct ArtworkPalette: Codable, Equatable {
    var top: RGB
    var bottom: RGB
    var accent: RGB
}

enum WidgetTheme: String, Codable, CaseIterable, Identifiable {
    case artwork, blur, system, graphite, plum, forest, ocean, sunset, paper, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .artwork: String(localized: "По обложке")
        case .blur: String(localized: "Размытая обложка")
        case .system: String(localized: "Системная")
        case .graphite: String(localized: "Графит")
        case .plum: String(localized: "Слива")
        case .forest: String(localized: "Хвоя")
        case .ocean: String(localized: "Океан")
        case .sunset: String(localized: "Закат")
        case .paper: String(localized: "Бумага")
        case .custom: String(localized: "Своя")
        }
    }

    /// Resolved colors for drawing. `palette` is used by the artwork based themes,
    /// `scheme` by the system theme, `custom` by the theme from the editor.
    func colors(palette: ArtworkPalette?, scheme: ColorScheme, custom: CustomTheme = .default) -> ThemeColors {
        switch self {
        case .custom:
            return custom.colors
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
