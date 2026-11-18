import SwiftUI

enum WidgetTheme: String, Codable, CaseIterable, Identifiable {
    case graphite, plum, forest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .graphite: "Графит"
        case .plum: "Слива"
        case .forest: "Хвоя"
        }
    }
    var colors: [Color] {
        switch self {
        case .graphite: [Color(red: 0.19, green: 0.22, blue: 0.25), Color(red: 0.09, green: 0.11, blue: 0.13)]
        case .plum: [Color(red: 0.27, green: 0.16, blue: 0.29), Color(red: 0.14, green: 0.08, blue: 0.18)]
        case .forest: [Color(red: 0.13, green: 0.25, blue: 0.20), Color(red: 0.06, green: 0.14, blue: 0.11)]
        }
    }
    var accent: Color {
        switch self {
        case .graphite: Color(red: 0.72, green: 0.87, blue: 1)
        case .plum: Color(red: 1, green: 0.76, blue: 0.91)
        case .forest: Color(red: 0.70, green: 0.96, blue: 0.80)
        }
    }
}
