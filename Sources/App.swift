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
        if let index = CommandLine.arguments.firstIndex(of: "--render-mini-player"),
           CommandLine.arguments.indices.contains(index + 1) {
            MiniPlayerRender.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Draws the mini player with a demo track into a PNG, for checking its layout without a screen.
@MainActor
enum MiniPlayerRender {
    static func write(to url: URL) {
        let model = MiniPlayerModel()
        model.presented = true
        let view = MiniPlayerView(player: Player(demo: true), preferences: Preferences(defaults: UserDefaults(suiteName: "render") ?? .standard),
                                  publisher: WidgetPublisher(), model: model, close: {}, showSettings: {})
            .background(Color(white: 0.85))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

enum SelfTest {
    static func run() {
        let list = NSAppleEventDescriptor.list()
        let items: [NSAppleEventDescriptor] = [
            .init(string: "spotify:track:001"), .init(string: "One, \"Two\""), .init(string: "Artist"),
            .init(string: "https://i.scdn.co/image/test"), .init(int32: 228000), .init(double: 72.5),
            .init(boolean: true), .init(int32: 64), .init(boolean: false), .init(boolean: true)
        ]
        for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
        guard case let .track(track) = SpotifyBridge.decode(list),
              track.title == "One, \"Two\"",
              track.position == 72.5, track.duration == 228, track.playing,
              track.volume == 64, track.shuffling == false, track.repeating == true,
              track.webLink?.absoluteString == "https://open.spotify.com/track/001",
              SpotifyBridge.decode(.list()) == .idle,
              SpotifyBridge.decode(NSAppleEventDescriptor(string: "bad input")) == .unavailable else {
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
    private lazy var miniPlayer = MiniPlayerController(player: player, preferences: preferences, publisher: publisher)
    private var observations: Set<AnyCancellable> = []
    private var settingsWindow: NSWindow?
    private var status: NSStatusItem?
    private var statusMenu: NSMenu?
    private var hotKey: HotKey?
    private var miniPlayerVisible = false
    private var settingsVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        player.foregroundInterval = preferences.refreshInterval
        player.backgroundInterval = preferences.backgroundInterval
        miniPlayer.showSettings = { [weak self] in self?.showSettings() }
        miniPlayer.onVisibilityChange = { [weak self] visible in
            self?.miniPlayerVisible = visible
            self?.updateForeground()
        }
        publisher.onCommand = { [weak self] action, step, done in
            guard let self else { done(); return }
            self.perform(action, step: step, done: done)
        }
        player.$playback
            .removeDuplicates()
            .combineLatest(preferences.$style.removeDuplicates())
            .sink { [weak self] playback, style in self?.publisher.publish(playback, style: style) }
            .store(in: &observations)
        preferences.$refreshInterval
            .sink { [weak self] interval in self?.player.foregroundInterval = interval }
            .store(in: &observations)
        preferences.$backgroundInterval
            .sink { [weak self] interval in self?.player.backgroundInterval = interval }
            .store(in: &observations)
        preferences.$showMenuBarIcon
            .combineLatest(preferences.$menuBarTitle)
            .sink { [weak self] visible, _ in
                // The sink runs before the new value is stored; read it on the next turn.
                DispatchQueue.main.async { self?.setMenuBarIcon(visible) }
            }
            .store(in: &observations)
        player.$playback
            .map { $0.currentTrack.map { "\($0.title) — \($0.artist)" } }
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateMenuBarTitle() } }
            .store(in: &observations)
        preferences.$hotKey
            .sink { [weak self] enabled in
                self?.hotKey = enabled ? HotKey { [weak self] in self?.miniPlayer.toggle() } : nil
            }
            .store(in: &observations)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? NSWindow) === self.settingsWindow else { return }
                self.settingsVisible = false
                self.updateForeground()
            }
        }

        if !preferences.didOnboard {
            preferences.didOnboard = true
            showSettings()
        }
    }

    /// Poll Spotify often only while the user can see a TrackPin window.
    private func updateForeground() {
        player.isForeground = miniPlayerVisible || settingsVisible
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
                case .player: miniPlayer.show(from: NSEvent.mouseLocation)
                case .settings: showSettings()
                }
            case "settings": showSettings()
            case "player": miniPlayer.show(from: NSEvent.mouseLocation)
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
        if status == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "TrackPin")
            item.button?.imagePosition = .imageLeading
            item.button?.target = self
            item.button?.action = #selector(statusClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            let menu = NSMenu()
            add("Мини-плеер", #selector(showMiniPlayer), to: menu)
            add("Настройки…", #selector(showSettings), to: menu, key: ",")
            add("Открыть Spotify", #selector(openSpotify), to: menu)
            add("Обновить виджеты", #selector(reloadWidgets), to: menu)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Выйти из TrackPin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusMenu = menu
            status = item
        }
        updateMenuBarTitle()
    }

    private func updateMenuBarTitle() {
        guard let button = status?.button else { return }
        guard preferences.menuBarTitle, let track = player.playback.currentTrack else {
            button.title = ""
            return
        }
        let text = "\(track.title) — \(track.artist)"
        button.title = " " + (text.count > 32 ? String(text.prefix(31)) + "…" : text)
        button.font = .menuBarFont(ofSize: 0)
    }

    /// Left click opens the mini player under the icon, right click shows the menu.
    @objc private func statusClicked() {
        guard let button = status?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            status?.menu = statusMenu
            button.performClick(nil)
            status?.menu = nil
            return
        }
        let frame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        miniPlayer.toggle(from: NSPoint(x: frame.midX, y: frame.minY))
    }

    private func add(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func openSpotify() { player.openSpotify() }
    @objc private func reloadWidgets() { publisher.reloadWidgets() }
    @objc private func showMiniPlayer() { miniPlayer.show() }

    // MARK: Windows

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(preferences: preferences, player: player, publisher: publisher,
                                    showMiniPlayer: { [weak self] in self?.miniPlayer.show() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Настройки TrackPin"
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.fullScreenNone]
            window.tabbingMode = .disallowed
            window.contentView = NSHostingView(rootView: view)
            window.center()
            settingsWindow = window
        }
        settingsVisible = true
        updateForeground()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
