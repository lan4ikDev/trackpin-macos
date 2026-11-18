import AppKit
import Combine
import SwiftUI

@main
enum TrackPinApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let sample = #"{"spotify:track:001", "One, \"Two\"", "Artist", "https://i.scdn.co/image/test", 228000, 72.5, true}"#
            guard case let .track(track) = SpotifyBridge.decode(sample),
                  track.title == "One, \"Two\"",
                  track.position == 72.5, track.duration == 228, track.playing,
                  SpotifyBridge.decode("{}") == .idle,
                  SpotifyBridge.decode("\"closed\"\n") == .closed,
                  SpotifyBridge.decode("bad input") == .unavailable else {
                fatalError("Playback data could not be decoded")
            }
            print("Playback decoder checks passed")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class Preferences: ObservableObject {
    @Published var theme: WidgetTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }
    @Published var showTime: Bool {
        didSet { UserDefaults.standard.set(showTime, forKey: "showTime") }
    }

    init() {
        theme = WidgetTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .graphite
        showTime = UserDefaults.standard.object(forKey: "showTime") as? Bool ?? true
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private lazy var player = Player(demo: CommandLine.arguments.contains("--demo"))
    private var publisher: WidgetPublisher?
    private var observation: AnyCancellable?
    private var playerWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var status: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        publisher = WidgetPublisher()
        observation = player.$playback
            .combineLatest(preferences.$theme, preferences.$showTime)
            .sink { [weak self] playback, theme, showTime in
                self?.publisher?.publish(playback, theme: theme, showTime: showTime)
            }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "TrackPin")
        let menu = NSMenu()
        add("Открыть плеер", #selector(showPlayer), to: menu)
        add("Настройки…", #selector(showSettings), to: menu)
        add("Открыть Spotify", #selector(openSpotify), to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти из TrackPin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        status = item
    }

    private func add(_ title: String, _ action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "needle-spotify" {
            switch url.host {
            case "toggle": player.send(.toggle)
            case "rewind": player.send(.skip(-15))
            case "forward": player.send(.skip(15))
            case "previous": player.send(.previous)
            case "next": player.send(.next)
            default: break
            }
        }
    }

    @objc private func openSpotify() { player.openSpotify() }

    @objc private func showPlayer() {
        if playerWindow == nil {
            let view = PlayerWindowView(player: player, preferences: preferences) { [weak self] in
                self?.showSettings()
            }
            playerWindow = makeWindow("Плеер TrackPin", size: NSSize(width: 372, height: 166), content: view)
        }
        present(playerWindow)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(preferences: preferences)
            settingsWindow = makeWindow("Настройки TrackPin", size: NSSize(width: 375, height: 162), content: view)
        }
        present(settingsWindow)
    }

    private func makeWindow<Content: View>(_ title: String, size: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: content)
        window.setContentSize(size)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct PlayerWindowView: View {
    @ObservedObject var player: Player
    @ObservedObject var preferences: Preferences
    let showSettings: () -> Void

    var body: some View {
        WidgetView(player: player, theme: preferences.theme, showTime: preferences.showTime,
                   showSettings: showSettings)
    }
}

private struct SettingsView: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Picker("Тема", selection: $preferences.theme) {
                ForEach(WidgetTheme.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Показывать время трека", isOn: $preferences.showTime)
            Text("Чтобы добавить TrackPin, щёлкни по рабочему столу правой кнопкой мыши и выбери «Изменить виджеты». Размер выбирается там же.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}
