import AppKit
import Combine
import SwiftUI

@main
enum TrackPinApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            SelfTest.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

enum SelfTest {
    static func run() {
        let sample = #"{"spotify:track:001", "One, \"Two\"", "Artist", "https://i.scdn.co/image/test", 228000, 72.5, true}"#
        guard case let .track(track) = SpotifyBridge.decode(sample),
              track.title == "One, \"Two\"",
              track.position == 72.5, track.duration == 228, track.playing,
              SpotifyBridge.decode("{}") == .idle,
              SpotifyBridge.decode("\"closed\"\n") == .closed,
              SpotifyBridge.decode("bad input") == .unavailable else {
            fatalError("Playback data could not be decoded")
        }

        let get = WidgetTransport.Request.snapshot
        let skip = WidgetTransport.Request.command(.forward, step: 15)
        guard WidgetTransport.Request(line: get.line) == get,
              WidgetTransport.Request(line: skip.line) == skip,
              WidgetTransport.Request(line: "NEEDLE wrong-token GET\n") == nil,
              WidgetTransport.Request(line: "NEEDLE \(TrackPinBuild.token) DO forward 9999\n") == nil else {
            fatalError("Widget requests could not be parsed")
        }

        var style = WidgetStyle()
        style.theme = .ocean
        style.controls = .full
        guard let data = try? JSONEncoder().encode(WidgetSnapshot(playback: .idle, sampledAt: .now, cover: nil,
                                                                  palette: nil, style: style)),
              let decoded = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              decoded.style == style,
              let partial = try? JSONDecoder().decode(WidgetStyle.self, from: Data(#"{"theme":"plum","seekStep":7}"#.utf8)),
              partial.theme == .plum, partial.seekStep == 15, partial.showTime else {
            fatalError("Widget style could not be decoded")
        }
        print("Self-test passed")
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private lazy var player = Player(demo: CommandLine.arguments.contains("--demo"))
    private let publisher = WidgetPublisher()
    private var observations: Set<AnyCancellable> = []
    private var playerWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var status: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        player.interval = preferences.refreshInterval
        publisher.onCommand = { [weak self] action, step, done in
            guard let self else { done(); return }
            self.perform(action, step: step, done: done)
        }
        player.$playback
            .combineLatest(preferences.$style)
            .sink { [weak self] playback, style in self?.publisher.publish(playback, style: style) }
            .store(in: &observations)
        preferences.$refreshInterval
            .sink { [weak self] interval in self?.player.interval = interval }
            .store(in: &observations)
        preferences.$showMenuBarIcon
            .sink { [weak self] visible in self?.setMenuBarIcon(visible) }
            .store(in: &observations)

        if !preferences.didOnboard {
            preferences.didOnboard = true
            showSettings()
        }
    }

    /// Opening the app again (from Finder or Spotlight) shows the settings, which is the
    /// only way back in when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: Commands

    private func perform(_ action: PlayerAction, step: Int, done: @escaping () -> Void) {
        if action == .toggle, preferences.launchSpotifyOnPlay, player.playback == .closed {
            player.openSpotify()
            done()
            return
        }
        player.send(PlayerCommand(action, step: step)) { [weak self] playback in
            guard let self else { done(); return }
            // Publish right away so the reply and the widget reload already show the new state.
            self.publisher.publish(playback, style: self.preferences.style)
            done()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "needle-spotify" {
            switch url.host {
            case "open":
                switch preferences.tapAction {
                case .spotify: player.openSpotify()
                case .player: showPlayer()
                case .settings: showSettings()
                }
            case "settings": showSettings()
            case "player": showPlayer()
            case "toggle": perform(.toggle, step: 15) {}
            case "rewind": perform(.rewind, step: preferences.style.seekStep) {}
            case "forward": perform(.forward, step: preferences.style.seekStep) {}
            case "previous": perform(.previous, step: 15) {}
            case "next": perform(.next, step: 15) {}
            default: break
            }
        }
    }

    // MARK: Menu bar

    private func setMenuBarIcon(_ visible: Bool) {
        guard visible else {
            if let status { NSStatusBar.system.removeStatusItem(status) }
            status = nil
            return
        }
        guard status == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "TrackPin")
        let menu = NSMenu()
        add("Открыть плеер", #selector(showPlayer), to: menu)
        add("Настройки…", #selector(showSettings), to: menu, key: ",")
        add("Открыть Spotify", #selector(openSpotify), to: menu)
        add("Обновить виджеты", #selector(reloadWidgets), to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти из TrackPin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        status = item
    }

    private func add(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func openSpotify() { player.openSpotify() }
    @objc private func reloadWidgets() { publisher.reloadWidgets() }

    // MARK: Windows

    @objc private func showPlayer() {
        if playerWindow == nil {
            let view = PlayerWindowView(player: player, preferences: preferences, publisher: publisher) { [weak self] in
                self?.showSettings()
            }
            playerWindow = makeWindow("Плеер TrackPin", size: NSSize(width: 372, height: 166), content: view)
        }
        present(playerWindow)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(preferences: preferences, player: player, publisher: publisher)
            settingsWindow = makeWindow("Настройки TrackPin", size: NSSize(width: 820, height: 560), content: view)
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
    @ObservedObject var publisher: WidgetPublisher
    let showSettings: () -> Void

    var body: some View {
        // The player window is always dark; light themes fall back to graphite.
        let themed = preferences.style.theme.colors(palette: publisher.snapshot.palette, scheme: .dark)
        let colors = themed.dark ? themed : WidgetTheme.graphite.colors(palette: nil, scheme: .dark)
        WidgetView(player: player, colors: colors, showTime: preferences.style.showTime, showSettings: showSettings)
    }
}
