import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var player: Player
    @ObservedObject var publisher: WidgetPublisher
    @ObservedObject var history: PlayHistory
    var stats: ListeningStats?
    var updater: Updater?
    let showMiniPlayer: () -> Void

    var body: some View {
        TabView {
            AppearanceSettings(preferences: preferences, publisher: publisher)
                .tabItem { Label("Виджет", systemImage: "rectangle.3.group") }
            MiniPlayerSettings(preferences: preferences, history: history, showMiniPlayer: showMiniPlayer)
                .tabItem { Label("Мини-плеер", systemImage: "rectangle.portrait.on.rectangle.portrait") }
            GeneralSettings(preferences: preferences, player: player, updater: updater)
                .tabItem { Label("Основные", systemImage: "gearshape") }
            if let stats {
                StatsView(stats: stats, enabled: preferences.keepHistory)
                    .tabItem { Label("Статистика", systemImage: "chart.bar") }
            }
            HelpSettings(player: player, publisher: publisher)
                .tabItem { Label("Доступ и помощь", systemImage: "questionmark.circle") }
        }
        .frame(width: 820, height: 600)
        .toggleStyle(SettingsSwitchStyle())
    }
}

/// A switch drawn by TrackPin itself. The native switch lost its knob in the settings
/// window on some systems (an empty blue capsule), so this one draws the track and the
/// knob explicitly and keeps its size however long the label is.
private struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsSwitch(configuration: configuration)
    }
}

private struct SettingsSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let on = configuration.isOn
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Capsule()
                .fill(on ? (activeState == .inactive ? Color.gray.opacity(0.55) : Color.accentColor) : Color.primary.opacity(0.18))
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .padding(2)
                }
                .frame(width: 34, height: 20)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: on)
                .onTapGesture { if enabled { configuration.isOn.toggle() } }
                .accessibilityHidden(true)
        }
        .opacity(enabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(on ? "Включено" : "Выключено")
        .accessibilityAction { if enabled { configuration.isOn.toggle() } }
    }
}

/// A labelled slider for an opacity between `range` and 1, shown in percent.
private struct OpacitySlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: 0.05)
                    .frame(minWidth: 140)
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

private struct UpdateSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Section {
            Toggle("Проверять обновления автоматически", isOn: Binding(
                get: { updater.automaticallyChecks },
                set: { updater.automaticallyChecks = $0 }))
            Button("Проверить обновления…") { updater.checkForUpdates() }
        } header: {
            Text("Обновления")
        } footer: {
            Text("Новые версии выходят на странице github.com/lan4ikDev/trackpin-macos/releases. TrackPin проверяет подпись обновления перед установкой.")
        }
    }
}

// MARK: Mini player

private struct MiniPlayerSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var history: PlayHistory
    let showMiniPlayer: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Нажатие на виджет", selection: $preferences.tapAction) {
                    ForEach(TapAction.allCases) { Text($0.title).tag($0) }
                }
                Button("Показать мини-плеер", action: showMiniPlayer)
            } footer: {
                Text("Мини-плеер открывается рядом с местом, где ты нажал на виджет, и закрывается кликом мимо него или клавишей Esc.")
            }
            Section("Вид") {
                Picker("Размер", selection: $preferences.popupSize) {
                    ForEach(PopupSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                OpacitySlider(title: String(localized: "Непрозрачность фона"), value: $preferences.popupOpacity, range: 0.3...1)
                Picker("Фон", selection: $preferences.popupBackground) {
                    ForEach(PopupBackground.allCases) { Text($0.title).tag($0) }
                }
                Picker("Обложка", selection: $preferences.popupCoverShape) {
                    ForEach(ArtworkShape.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Пластинка крутится, пока играет музыка", isOn: $preferences.popupSpinsRecord)
                    .disabled(preferences.popupCoverShape != .circle)
                Picker("Эквалайзер", selection: $preferences.popupVisualizer) {
                    ForEach(PopupVisualizer.allCases) { Text($0.title).tag($0) }
                }
                Text("Анимация идёт только пока мини-плеер открыт и играет музыка, поэтому батарею она почти не тратит. Полоски двигаются в такт условно: TrackPin не слушает звук Spotify.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Громкость", isOn: $preferences.popupShowsVolume)
                Toggle("Перемешивание и повтор", isOn: $preferences.popupShowsModes)
                Toggle("Текст песни", isOn: $preferences.popupShowsLyrics)
                    .help("Синхронизированный текст с lrclib.net. Нажатие на строку перематывает к ней.")
                Text("Цвет кнопок, исполнитель и время трека берутся из настроек виджета.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Поведение") {
                Picker("Где открывать", selection: $preferences.popupPlacement) {
                    ForEach(PopupPlacement.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Анимация открытия", isOn: $preferences.popupAnimated)
                Toggle("Закрывать при клике мимо", isOn: $preferences.popupClosesOnClickOutside)
                Toggle("Жесты: свайп переключает трек, прокрутка меняет громкость", isOn: $preferences.popupGestures)
                Toggle("Горячая клавиша ⌃⌥P открывает и закрывает мини-плеер", isOn: $preferences.hotKey)
            }
            Section {
                Toggle("Запоминать прослушанные треки", isOn: $preferences.keepHistory)
                LabeledContent("В истории", value: String(localized: "\(history.entries.count) из \(PlayHistory.limit)"))
                Button("Очистить историю", role: .destructive) { history.clear() }
                    .disabled(history.entries.isEmpty)
            } header: {
                Text("История")
            } footer: {
                Text("Кнопка с часами в мини-плеере показывает недавно игравшие треки, клик включает трек снова. TrackPin записывает треки сам, пока он запущен, и хранит их только на этом Mac.")
            }
            Section("Клавиши в мини-плеере") {
                LabeledContent("Пробел", value: String(localized: "Пауза и воспроизведение"))
                LabeledContent("← →", value: String(localized: "Перемотка на шаг из настроек виджета"))
                LabeledContent("↑ ↓", value: String(localized: "Громкость"))
                LabeledContent("H", value: String(localized: "Недавно играли"))
                LabeledContent("Esc", value: String(localized: "Закрыть"))
            }
        }
        .formStyle(.grouped)
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
                    ThemeGrid(selection: $preferences.style.theme, palette: publisher.displayPalette,
                              custom: preferences.style.customTheme)
                    if preferences.style.theme == .custom {
                        CustomThemeEditor(theme: $preferences.style.customTheme, palette: publisher.displayPalette)
                    }
                    ThemeFileButtons(preferences: preferences)
                }
                Section("Содержимое") {
                    Picker("Обложка", selection: $preferences.style.artwork) {
                        ForEach(ArtworkShape.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Заголовок с названием плеера", isOn: $preferences.style.showHeader)
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
                    Toggle("Кнопки громкости", isOn: $preferences.style.showVolume)
                    Toggle("Перемотка по краям полосы прогресса", isOn: $preferences.style.seekAroundProgress)
                        .disabled(preferences.style.controls != .tracks)
                    Text("На маленьком виджете вместо пяти кнопок показываются три, а громкости нет. На среднем кнопки громкости стоят в заголовке.")
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
    let custom: CustomTheme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
            ForEach(WidgetTheme.allCases) { theme in
                let colors = theme.colors(palette: palette ?? WidgetSnapshot.preview.palette, scheme: scheme, custom: custom)
                let selected = selection == theme
                Button { selection = theme } label: {
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(colors.gradient)
                            .overlay(alignment: .bottomTrailing) {
                                Circle().fill(colors.accent).frame(width: 12, height: 12).padding(6)
                            }
                            .overlay(alignment: .topLeading) {
                                if theme == .artwork || theme == .blur || theme == .custom {
                                    Image(systemName: theme == .blur ? "drop.fill" : theme == .custom ? "paintpalette.fill" : "photo")
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

// MARK: Theme editor

/// Colors of the «Своя» (custom) theme. Changes reach the widget right away, like any other setting.
private struct CustomThemeEditor: View {
    @Binding var theme: CustomTheme
    let palette: ArtworkPalette?

    var body: some View {
        TextField("Название", text: $theme.name)
        ColorPicker("Фон сверху", selection: color(\.top), supportsOpacity: false)
        ColorPicker("Фон снизу", selection: color(\.bottom), supportsOpacity: false)
        ColorPicker("Акцент: кнопки и прогресс", selection: color(\.accent), supportsOpacity: false)
        HStack {
            Button("Взять цвета обложки") {
                guard let palette else { return }
                theme.top = palette.top
                theme.bottom = palette.bottom
                theme.accent = palette.accent
            }
            .disabled(palette == nil)
            .help("Цвета текущей обложки станут постоянными и не будут меняться вместе с треком")
            Button("Поменять фон местами") { let top = theme.top; theme.top = theme.bottom; theme.bottom = top }
            Spacer()
            Button("Сбросить") { theme = .default }
        }
        Text(theme.dark ? "Фон тёмный, поэтому текст будет светлым." : "Фон светлый, поэтому текст будет тёмным. В мини-плеере светлые темы заменяются графитовой.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func color(_ key: WritableKeyPath<CustomTheme, RGB>) -> Binding<Color> {
        Binding(
            get: { theme[keyPath: key].color },
            set: { if let rgb = RGB(color: $0) { theme[keyPath: key] = rgb } })
    }
}

/// Export the custom theme to a JSON file and import one.
private struct ThemeFileButtons: View {
    @ObservedObject var preferences: Preferences
    @State private var message: String?

    var body: some View {
        HStack {
            Button("Импорт темы…", action: importTheme)
            Button("Экспорт…", action: exportTheme)
                .disabled(preferences.style.theme != .custom)
                .help("Сохранить тему «Своя» в файл JSON, чтобы поделиться ей")
            Spacer()
        }
        if let message {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func exportTheme() {
        let theme = preferences.style.customTheme
        let panel = NSSavePanel()
        panel.title = String(localized: "Экспорт темы")
        panel.allowedContentTypes = [.json]
        // A name without characters that macOS file names cannot hold; never an empty one, which
        // would make a hidden ".json" file.
        let base = theme.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = "\(base.isEmpty ? "TrackPin" : base).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try theme.exportData().write(to: url, options: .atomic)
            message = String(localized: "Тема сохранена в «\(url.lastPathComponent)».")
        } catch {
            message = String(localized: "Не получилось сохранить: \(error.localizedDescription)")
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Импорт темы")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 64 * 1024 else { throw CustomTheme.InvalidFile() }
            let theme = try CustomTheme.importing(data)
            preferences.style.customTheme = theme
            preferences.style.theme = .custom
            message = String(localized: "Тема «\(theme.name)» загружена.")
        } catch {
            message = error.localizedDescription
        }
    }
}

extension RGB {
    /// sRGB components of a color from the color picker.
    init?(color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(r: Double(srgb.redComponent), g: Double(srgb.greenComponent), b: Double(srgb.blueComponent))
    }
}

// MARK: General

private struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var player: Player
    let updater: Updater?
    @State private var loginEnabled = LoginItem.enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Источник музыки", selection: $preferences.sourceSelection) {
                    ForEach(SourceSelection.allCases) { Text($0.title).tag($0) }
                }
                if preferences.sourceSelection == .automatic {
                    Toggle("Искать Яндекс Музыку во вкладках браузера", isOn: $preferences.scansBrowser)
                    LabeledContent("Сейчас", value: player.source.settingsTitle)
                }
                if player.playback == .denied {
                    Text(player.source.accessHint).font(.caption).foregroundStyle(.orange)
                    Button("Открыть настройки доступа") { player.source.requestAccess() }
                }
            } header: {
                Text("Плеер")
            } footer: {
                Text(sourceFooter)
            }
            Section {
                Picker("Язык", selection: $preferences.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Язык применится после перезапуска TrackPin. Виджет на рабочем столе говорит на языке системы.")
            }
            if let updater {
                UpdateSection(updater: updater)
            }
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
                Toggle("Иконка в Dock", isOn: $preferences.showInDock)
                Toggle("Иконка в строке меню", isOn: $preferences.showMenuBarIcon)
                Toggle("Название трека рядом с иконкой", isOn: $preferences.menuBarTitle)
                    .disabled(!preferences.showMenuBarIcon)
                if !preferences.showMenuBarIcon {
                    Text("Чтобы вернуться в настройки, открой TrackPin ещё раз из «Программ» или через Spotlight.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Уведомление при смене трека", isOn: $preferences.notifyOnTrackChange)
                Toggle("⌃⌥Пробел — пауза, ⌃⌥→ и ⌃⌥← — следующий и предыдущий трек", isOn: $preferences.mediaHotKeys)
            } header: {
                Text("Уведомления и горячие клавиши")
            } footer: {
                Text("Уведомление не показывается, пока открыт мини-плеер. Если оно не появляется, разреши уведомления TrackPin в «Системных настройках» → «Уведомления». Таймер сна — в мини-плеере (значок луны) и в меню иконки в строке меню.")
            }
            Section("Поведение виджета") {
                Toggle("Кнопка воспроизведения запускает плеер, если он закрыт", isOn: $preferences.launchSpotifyOnPlay)
            }
            Section {
                Picker("Пока открыт мини-плеер или настройки", selection: $preferences.refreshInterval) {
                    Text("Каждую секунду").tag(1.0)
                    Text("Раз в 2 секунды").tag(2.0)
                    Text("Раз в 5 секунд").tag(5.0)
                }
                Picker("В фоне, пока играет музыка", selection: $preferences.backgroundInterval) {
                    Text("Только по событиям плеера").tag(0.0)
                    Text("Раз в 30 секунд").tag(30.0)
                    Text("Раз в 2 минуты").tag(120.0)
                }
            } header: {
                Text("Энергосбережение")
            } footer: {
                Text("Spotify и Apple Music сами сообщают о паузе и смене трека, и TrackPin обновляет виджет сразу. Опрос в фоне нужен, чтобы заметить перемотку внутри плеера, и для Яндекс Музыки, которая ни о чём не сообщает. На паузе и при закрытом плеере TrackPin почти ничего не опрашивает.")
            }
        }
        .formStyle(.grouped)
        .onAppear { loginEnabled = LoginItem.enabled }
    }

    private var sourceFooter: String {
        switch preferences.sourceSelection {
        case .automatic:
            String(localized: "TrackPin показывает тот плеер, который сейчас играет: Spotify, Apple Music или приложение Яндекс Музыки. Браузер проверяется, только если включить переключатель выше.")
        case .fixed(.spotify), .fixed(.appleMusic):
            String(localized: "Нужно разрешение в разделе «Автоматизация». macOS спросит его при первом обращении.")
        case .fixed(.yandexApp):
            String(localized: "Нужен «Универсальный доступ» для TrackPin: Яндекс Музыка не даёт другим приложениям данных о треке, поэтому TrackPin читает её окно, как VoiceOver. После каждой новой сборки TrackPin доступ может понадобиться выдать заново.")
        case .fixed(.yandexWeb):
            String(localized: "Работает с вкладкой music.yandex.ru в Safari, Chrome, Яндекс Браузере, Arc, Edge, Brave и Vivaldi. В браузере нужно включить «Разрешить JavaScript из Apple Events»: в Safari это меню «Разработка», в Chrome-подобных браузерах «Вид → Разработчикам».")
        }
    }
}

// MARK: Help

private struct HelpSettings: View {
    @ObservedObject var player: Player
    @ObservedObject var publisher: WidgetPublisher

    var body: some View {
        Form {
            Section("Состояние") {
                LabeledContent(player.source.settingsTitle, value: spotifyStatus)
                LabeledContent("Связь с виджетом",
                               value: publisher.listening ? String(localized: "Работает") : String(localized: "Не запущена"))
                if player.playback == .denied {
                    Text(player.source.accessHint).font(.caption).foregroundStyle(.secondary)
                    Button("Открыть настройки доступа") { player.source.requestAccess() }
                }
            }
            Section("Как добавить виджет") {
                Text("""
                1. Щёлкни правой кнопкой по рабочему столу и выбери «Изменить виджеты».
                2. Найди TrackPin в списке слева.
                3. Перетащи «Плеер» или «Обложка» нужного размера на рабочий стол.
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
                Text("TrackPin — независимый проект и не связан со Spotify, Apple или Яндексом.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var spotifyStatus: String {
        switch player.playback {
        case .closed: String(localized: "Не запущен")
        case .idle: String(localized: "Ничего не играет")
        case .denied: String(localized: "Нет доступа")
        case .unavailable: String(localized: "Не отвечает")
        case let .track(track): track.playing ? String(localized: "Играет «\(track.title)»") : String(localized: "На паузе")
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
