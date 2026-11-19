import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var player: Player
    @ObservedObject var publisher: WidgetPublisher

    var body: some View {
        TabView {
            AppearanceSettings(preferences: preferences, publisher: publisher)
                .tabItem { Label("Виджет", systemImage: "rectangle.3.group") }
            GeneralSettings(preferences: preferences)
                .tabItem { Label("Основные", systemImage: "gearshape") }
            HelpSettings(player: player, publisher: publisher)
                .tabItem { Label("Доступ и помощь", systemImage: "questionmark.circle") }
        }
        .frame(width: 820, height: 560)
    }
}

// MARK: Appearance

private struct AppearanceSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var publisher: WidgetPublisher
    @State private var size: CardSize = .medium

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section("Тема") {
                    ThemeGrid(selection: $preferences.style.theme, palette: publisher.snapshot.palette)
                }
                Section("Содержимое") {
                    Picker("Обложка", selection: $preferences.style.artwork) {
                        ForEach(ArtworkShape.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Заголовок «Spotify»", isOn: $preferences.style.showHeader)
                    Toggle("Исполнитель", isOn: $preferences.style.showArtist)
                    Toggle("Полоса прогресса", isOn: $preferences.style.showProgress)
                    Toggle("Время трека", isOn: $preferences.style.showTime)
                        .disabled(!preferences.style.showProgress)
                }
                Section("Кнопки") {
                    Picker("Набор", selection: $preferences.style.controls) {
                        Text("⏮  ⏯  ⏭").tag(ControlSet.tracks)
                        Text("−\(preferences.style.seekStep)  ⏯  +\(preferences.style.seekStep)").tag(ControlSet.seek)
                        Text("Все пять").tag(ControlSet.full)
                    }
                    Picker("Шаг перемотки", selection: $preferences.style.seekStep) {
                        ForEach(WidgetStyle.seekSteps, id: \.self) { Text("\($0) с").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("На маленьком виджете вместо пяти кнопок показываются три.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Вернуть оформление по умолчанию") { preferences.resetStyle() }
                }
            }
            .formStyle(.grouped)
            .frame(width: 410)

            Divider()

            VStack(spacing: 16) {
                Picker("Размер", selection: $size) {
                    ForEach(CardSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                Spacer(minLength: 0)
                TrackPinCard(snapshot: previewSnapshot, style: preferences.style, size: size, inWidget: false)
                    .allowsHitTesting(false)
                    .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                    .animation(.easeInOut(duration: 0.2), value: preferences.style)
                Spacer(minLength: 0)
                Text("Так виджет выглядит на рабочем столе. Тему и кнопки можно сменить и у отдельного виджета: правый клик по нему → «Изменить виджет».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(colors: [Color(red: 0.36, green: 0.47, blue: 0.62), Color(red: 0.62, green: 0.50, blue: 0.62)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.35)
            )
        }
    }

    /// The real current track when something plays, otherwise a sample one.
    private var previewSnapshot: WidgetSnapshot {
        let live = publisher.snapshot
        if live.playback.currentTrack != nil { return live }
        var sample = WidgetSnapshot.preview
        sample.sampledAt = .now
        return sample
    }
}

private struct ThemeGrid: View {
    @Binding var selection: WidgetTheme
    let palette: ArtworkPalette?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
            ForEach(WidgetTheme.allCases) { theme in
                let colors = theme.colors(palette: palette ?? WidgetSnapshot.preview.palette, scheme: scheme)
                let selected = selection == theme
                Button { selection = theme } label: {
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(colors.gradient)
                            .overlay(alignment: .bottomTrailing) {
                                Circle().fill(colors.accent).frame(width: 12, height: 12).padding(6)
                            }
                            .overlay(alignment: .topLeading) {
                                if theme == .artwork || theme == .blur {
                                    Image(systemName: theme == .blur ? "drop.fill" : "photo")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(colors.primary.opacity(0.8))
                                        .padding(6)
                                }
                            }
                            .frame(height: 42)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                                  lineWidth: selected ? 2.5 : 1)
                            )
                        Text(theme.title)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences
    @State private var loginEnabled = LoginItem.enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Запуск") {
                Toggle("Открывать TrackPin при входе в систему", isOn: Binding(
                    get: { loginEnabled },
                    set: { value in
                        loginError = LoginItem.set(value)
                        loginEnabled = LoginItem.enabled
                    }))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Text("Виджет получает трек от приложения, поэтому TrackPin должен работать в фоне.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Иконка в строке меню", isOn: $preferences.showMenuBarIcon)
                if !preferences.showMenuBarIcon {
                    Text("Чтобы вернуться в настройки, открой TrackPin ещё раз из «Программ» или через Spotlight.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Поведение виджета") {
                Picker("Нажатие на виджет", selection: $preferences.tapAction) {
                    ForEach(TapAction.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Кнопка воспроизведения запускает Spotify, если он закрыт", isOn: $preferences.launchSpotifyOnPlay)
                Picker("Проверять Spotify", selection: $preferences.refreshInterval) {
                    Text("Каждую секунду").tag(1.0)
                    Text("Раз в 2 секунды").tag(2.0)
                    Text("Раз в 5 секунд").tag(5.0)
                }
                Text("Чем реже, тем меньше нагрузка, но тем позже виджет заметит трек, переключённый в самом Spotify. Нажатия кнопок виджета отрабатывают сразу.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginEnabled = LoginItem.enabled }
    }
}

// MARK: Help

private struct HelpSettings: View {
    @ObservedObject var player: Player
    @ObservedObject var publisher: WidgetPublisher

    var body: some View {
        Form {
            Section("Состояние") {
                LabeledContent("Spotify", value: spotifyStatus)
                LabeledContent("Связь с виджетом", value: publisher.listening ? "Работает" : "Не запущена")
                if player.playback == .denied {
                    Button("Открыть настройки «Автоматизация»") {
                        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                    }
                }
            }
            Section("Как добавить виджет") {
                Text("""
                1. Щёлкни правой кнопкой по рабочему столу и выбери «Изменить виджеты».
                2. Найди TrackPin в списке слева.
                3. Перетащи «Spotify» или «Обложка» нужного размера на рабочий стол.
                4. Двигай виджет как любой другой. Правый клик по нему → «Изменить виджет» меняет тему и кнопки только для него.
                """)
                .fixedSize(horizontal: false, vertical: true)
                Button("Обновить виджеты") { publisher.reloadWidgets() }
            }
            Section("Виджет серый или без обложки") {
                Text("Когда поверх рабочего стола открыты окна, macOS делает виджеты приглушёнными. Чтобы виджет всегда был цветным, выбери стиль виджетов «Цветной» в разделе «Рабочий стол и Dock».")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Открыть «Рабочий стол и Dock»") {
                    open("x-apple.systempreferences:com.apple.Desktop-Settings.extension")
                }
            }
            Section {
                LabeledContent("Версия", value: version)
                Text("TrackPin — независимый проект и не связан со Spotify.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var spotifyStatus: String {
        switch player.playback {
        case .closed: "Не запущен"
        case .idle: "Ничего не играет"
        case .denied: "Нет доступа"
        case .unavailable: "Не отвечает"
        case let .track(track): track.playing ? "Играет «\(track.title)»" : "На паузе"
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}
