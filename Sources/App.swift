import AppKit
import Carbon.HIToolbox
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
        if let index = CommandLine.arguments.firstIndex(of: "--render-settings"),
           CommandLine.arguments.indices.contains(index + 1) {
            MiniPlayerRender.writeSettings(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
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
        let player = Player(demo: true)
        let sleep = SleepTimer(player: player)
        if CommandLine.arguments.contains("--sleep") { sleep.start(.minutes(30)) }
        let publisher = WidgetPublisher()
        publisher.usePreviewCover(demoCover())
        let preferences = Preferences(defaults: UserDefaults(suiteName: "render") ?? .standard)
        preferences.popupShowsLyrics = CommandLine.arguments.contains("--lyrics")
        let view = MiniPlayerView(player: player, preferences: preferences,
                                  publisher: publisher, history: PlayHistory(fileURL: nil), model: model,
                                  sleepTimer: sleep, lyrics: LyricsStore(), close: {}, showSettings: {})
            .background(wallpaper)
        drawWithAppKit(view, to: url)
        writeWidgets(next: url)
    }

    /// Draws `view` through a real (off screen) window, so AppKit backed controls such as
    /// progress bars render as they do on screen, at 2x.
    private static func drawWithAppKit<V: View>(_ view: V, to url: URL) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        hosting.layoutSubtreeIfNeeded()
        let pixels = NSSize(width: size.width * 2, height: size.height * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static var wallpaper: some View {
        LinearGradient(colors: [Color(red: 0.29, green: 0.42, blue: 0.62), Color(red: 0.58, green: 0.45, blue: 0.62),
                                Color(red: 0.86, green: 0.6, blue: 0.52)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// An abstract cover for screenshots, so they show no real album art.
    static func demoCover() -> Data {
        let side = 600
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let gradient = NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.45, blue: 0.38, alpha: 1),
                                               NSColor(srgbRed: 0.55, green: 0.22, blue: 0.62, alpha: 1),
                                               NSColor(srgbRed: 0.12, green: 0.14, blue: 0.38, alpha: 1)])
            gradient?.draw(in: rect, angle: -60)
            let center = NSPoint(x: rect.midX, y: rect.midY * 0.92)
            for (index, radius) in [250.0, 195, 140, 85].enumerated() {
                let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                NSColor.white.withAlphaComponent(0.10 + Double(index) * 0.05).setStroke()
                ring.lineWidth = 3
                ring.stroke()
            }
            NSColor(srgbRed: 1, green: 0.85, blue: 0.55, alpha: 0.95).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 44, y: center.y - 44, width: 88, height: 88)).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return Data() }
        return jpeg
    }

    /// Every settings tab, drawn by AppKit into PNGs (`<path>-<tab>.png`), so real controls
    /// such as switches show up as they do on screen.
    static func writeSettings(to url: URL) {
        _ = NSApplication.shared
        let preferences = Preferences(defaults: UserDefaults(suiteName: "render") ?? .standard)
        let player = Player(demo: true)
        let publisher = WidgetPublisher()
        publisher.usePreviewCover(demoCover())
        player.objectWillChange.send()
        let view = SettingsView(preferences: preferences, player: player, publisher: publisher,
                                history: PlayHistory(fileURL: nil), showMiniPlayer: {})
            .environment(\.controlActiveState, .key)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let tabs = CommandLine.arguments.contains("--all-tabs") ? 4 : 1
        for tab in 0..<tabs {
            if tab > 0, let tabView = Self.find(NSTabView.self, in: hosting) { tabView.selectTabViewItem(at: tab) }
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let target = url.deletingPathExtension().appendingPathExtension("\(tab).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: target)
        }
        window.orderOut(nil)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }

    /// The medium and large widget faces with a demo track, next to the mini player image.
    private static func writeWidgets(next url: URL) {
        var snapshot = WidgetSnapshot.preview
        if case var .track(track) = snapshot.playback {
            track.volume = 64
            snapshot.playback = .track(track)
        }
        let publisher = WidgetPublisher()
        publisher.usePreviewCover(demoCover())
        snapshot.cover = publisher.snapshot.cover
        snapshot.palette = publisher.snapshot.palette
        let style = WidgetStyle()
        var ocean = style
        ocean.theme = .ocean
        let view = HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 24) {
                TrackPinCard(snapshot: snapshot, style: style, size: .medium, inWidget: false)
                HStack(spacing: 24) {
                    TrackPinCard(snapshot: snapshot, style: ocean, size: .small, inWidget: false)
                    TrackPinCard(snapshot: snapshot, style: style, size: .small, inWidget: false)
                }
            }
            TrackPinCard(snapshot: snapshot, style: style, size: .large, inWidget: false)
        }
        .padding(32)
        .background(wallpaper)
        drawWithAppKit(view, to: url.deletingPathExtension().appendingPathExtension("widgets.png"))
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

        let web = #"{"ok":true,"id":"42","title":"Song","artist":"A, B","cover":"https://avatars.yandex.net/x/400x400","duration":200,"position":12.5,"playing":true,"volume":55,"shuffle":false,"repeat":true}"#
        guard case let .track(yandex) = YandexWebBridge.decode(web),
              yandex.id == "yandex:track:42", yandex.artist == "A, B", yandex.position == 12.5,
              yandex.playing, yandex.volume == 55, yandex.repeating == true,
              yandex.webLink?.absoluteString == "https://music.yandex.ru/track/42",
              YandexWebBridge.decode(#"{"ok":true,"idle":true}"#) == .idle,
              YandexWebBridge.decode("none") == .unavailable,
              YandexAppBridge.seconds("3:05") == 185, YandexAppBridge.seconds("-0:45") == -45,
              YandexAppBridge.seconds("1:02:03") == 3723, YandexAppBridge.seconds("Песня") == nil,
              YandexAppBridge.trackID("/album/1/track/77?x=1") == "77",
              YandexAppBridge.largeCover("https://avatars.yandex.net/get/a/100x100") == "https://avatars.yandex.net/get/a/400x400",
              SourceSelection.allCases.allSatisfy({ SourceSelection(rawValue: $0.rawValue) == $0 }) else {
            fatalError("Yandex Music data could not be decoded")
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
        let theme = CustomTheme(name: "Ночь", top: RGB(hex: "#1E2A38")!, bottom: RGB(hex: "0b1220")!, accent: RGB(hex: "#8CE6FF")!)
        guard let exported = try? theme.exportData(),
              let imported = try? CustomTheme.importing(exported),
              imported == theme, imported.top.hex == "#1E2A38", imported.bottom.hex == "#0B1220", theme.dark,
              (try? CustomTheme.importing(Data(##"{"top":"#zzz","bottom":"#000000","accent":"#FFFFFF"}"##.utf8))) == nil,
              (try? CustomTheme.importing(Data(##"{"format":"other","top":"#000000","bottom":"#000000","accent":"#FFFFFF"}"##.utf8))) == nil else {
            fatalError("Theme files could not be read")
        }
        print("Self-test passed")
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let updater = Updater()
    private lazy var player = Player(demo: CommandLine.arguments.contains("--demo"))
    private let publisher = WidgetPublisher()
    private let history = PlayHistory(fileURL: CommandLine.arguments.contains("--demo") ? nil : PlayHistory.defaultURL)
    private lazy var miniPlayer = MiniPlayerController(player: player, preferences: preferences, publisher: publisher,
                                                       history: history, sleepTimer: sleepTimer)
    private var observations: Set<AnyCancellable> = []
    private var settingsWindow: NSWindow?
    private var status: NSStatusItem?
    private var statusMenu: NSMenu?
    private var sleepMenuItem: NSMenuItem?
    private var hotKeys: HotKeys?
    private lazy var sleepTimer = SleepTimer(player: player)
    private let notifier = TrackNotifier()
    private var miniPlayerVisible = false
    private var settingsVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        player.selection = preferences.sourceSelection
        player.scansBrowser = preferences.scansBrowser
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
            .combineLatest(preferences.$style.removeDuplicates(), player.$source.removeDuplicates())
            .sink { [weak self] playback, style, source in self?.publisher.publish(playback, style: style, source: source) }
            .store(in: &observations)
        preferences.$sourceSelection
            .sink { [weak self] selection in self?.player.selection = selection }
            .store(in: &observations)
        preferences.$scansBrowser
            .sink { [weak self] scans in self?.player.scansBrowser = scans }
            .store(in: &observations)
        // `record` ignores repeated reads of the same play, so every playing read can go in.
        player.$playback
            .compactMap(\.currentTrack)
            .filter(\.playing)
            .sink { [weak self] track in
                guard let self, self.preferences.keepHistory else { return }
                self.history.record(track)
            }
            .store(in: &observations)
        preferences.$refreshInterval
            .sink { [weak self] interval in self?.player.foregroundInterval = interval }
            .store(in: &observations)
        preferences.$backgroundInterval
            .sink { [weak self] interval in self?.player.backgroundInterval = interval }
            .store(in: &observations)
        preferences.$showInDock
            .removeDuplicates()
            .sink { visible in
                NSApp.setActivationPolicy(visible ? .regular : .accessory)
            }
            .store(in: &observations)
        // The widget only stays current while TrackPin runs, so start it at login unless the
        // user turned that off.
        if !preferences.didSetUpLoginItem {
            preferences.didSetUpLoginItem = true
            if !LoginItem.enabled { _ = LoginItem.set(true) }
        }
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
            .combineLatest(preferences.$mediaHotKeys)
            .sink { [weak self] miniPlayerKey, mediaKeys in self?.registerHotKeys(miniPlayer: miniPlayerKey, media: mediaKeys) }
            .store(in: &observations)
        preferences.$notifyOnTrackChange
            .sink { [weak self] enabled in self?.notifier.enabled = enabled }
            .store(in: &observations)
        player.$playback
            .sink { [weak self] playback in
                guard let self else { return }
                self.notifier.update(playback, suppressed: self.miniPlayerVisible) { [weak self] in
                    self?.publisher.snapshot.cover
                }
            }
            .store(in: &observations)
        sleepTimer.$mode
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateSleepMenu() } }
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

    private func registerHotKeys(miniPlayer showMiniPlayer: Bool, media: Bool) {
        hotKeys = nil
        var bindings: [HotKeys.Binding] = []
        let modifiers = HotKeys.controlOption
        if showMiniPlayer {
            bindings.append(.init(keyCode: kVK_ANSI_P, modifiers: modifiers) { [weak self] in self?.miniPlayer.toggle() })
        }
        if media {
            bindings.append(.init(keyCode: kVK_Space, modifiers: modifiers) { [weak self] in self?.perform(.toggle, step: 15) {} })
            bindings.append(.init(keyCode: kVK_RightArrow, modifiers: modifiers) { [weak self] in self?.perform(.next, step: 15) {} })
            bindings.append(.init(keyCode: kVK_LeftArrow, modifiers: modifiers) { [weak self] in self?.perform(.previous, step: 15) {} })
        }
        if !bindings.isEmpty { hotKeys = HotKeys(bindings) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        history.flush()
    }

    /// Poll the player often only while the user can see a TrackPin window.
    private func updateForeground() {
        player.isForeground = miniPlayerVisible || settingsVisible
    }

    /// Right click on the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let playing = player.playback.currentTrack?.playing == true
        if let track = player.playback.currentTrack {
            let now = NSMenuItem(title: "\(track.title) — \(track.artist)", action: nil, keyEquivalent: "")
            now.isEnabled = false
            menu.addItem(now)
            menu.addItem(.separator())
        }
        add(playing ? String(localized: "Пауза") : String(localized: "Воспроизвести"), #selector(dockToggle), to: menu)
        add(String(localized: "Следующий трек"), #selector(dockNext), to: menu)
        add(String(localized: "Предыдущий трек"), #selector(dockPrevious), to: menu)
        menu.addItem(.separator())
        add(String(localized: "Мини-плеер"), #selector(showMiniPlayer), to: menu)
        return menu
    }

    @objc private func dockToggle() { perform(.toggle, step: 15) {} }
    @objc private func dockNext() { perform(.next, step: 15) {} }
    @objc private func dockPrevious() { perform(.previous, step: 15) {} }

    /// Opening the app again (from Finder or Spotlight) shows the settings, which is the
    /// only way back in when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: Commands

    /// When play/pause was last run, to drop the second click of a double click.
    private var lastToggle = Date.distantPast

    private func perform(_ action: PlayerAction, step: Int, done: @escaping () -> Void) {
        // A double click on a widget button runs its intent twice, about 0.15 s apart, and the
        // second play/pause undoes the first. Ignore a toggle that follows another that closely.
        if action == .toggle {
            if Date().timeIntervalSince(lastToggle) < 0.5 {
                Log.player.notice("ignored a second toggle")
                done()
                return
            }
            lastToggle = Date()
        }
        if action == .toggle, preferences.launchSpotifyOnPlay, player.playback == .closed {
            player.openPlayer()
            done()
            return
        }
        let volume = player.playback.currentTrack?.volume
        player.send(PlayerCommand(action, step: step, volume: volume)) { [weak self] playback in
            guard let self else { done(); return }
            // Publish right away so the reply and the widget reload already show the new state.
            self.publisher.publish(playback, style: self.preferences.style, source: self.player.source)
            done()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "needle-spotify" {
            switch url.host {
            case "open":
                switch preferences.tapAction {
                case .spotify: player.openPlayer()
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
            add(String(localized: "Мини-плеер"), #selector(showMiniPlayer), to: menu)
            add(String(localized: "Настройки…"), #selector(showSettings), to: menu, key: ",")
            let sleep = NSMenuItem(title: String(localized: "Таймер сна"), action: nil, keyEquivalent: "")
            sleep.submenu = NSMenu()
            menu.addItem(sleep)
            sleepMenuItem = sleep
            add(String(localized: "Открыть плеер"), #selector(openPlayer), to: menu)
            add(String(localized: "Обновить виджеты"), #selector(reloadWidgets), to: menu)
            add(String(localized: "Проверить обновления…"), #selector(checkForUpdates), to: menu)
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Выйти из TrackPin"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusMenu = menu
            status = item
            updateSleepMenu()
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

    private func updateSleepMenu() {
        guard let menu = sleepMenuItem?.submenu else { return }
        menu.removeAllItems()
        let current = sleepTimer.mode
        for minutes in SleepTimer.presets {
            let item = NSMenuItem(title: String(localized: "\(minutes) минут"), action: #selector(startSleep(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            item.state = current == .minutes(minutes) ? .on : .off
            menu.addItem(item)
        }
        let end = NSMenuItem(title: String(localized: "В конце трека"), action: #selector(startSleep(_:)), keyEquivalent: "")
        end.target = self
        end.tag = 0
        end.state = current == .endOfTrack ? .on : .off
        menu.addItem(end)
        if current != nil {
            menu.addItem(.separator())
            let off = NSMenuItem(title: String(localized: "Выключить таймер"), action: #selector(cancelSleep), keyEquivalent: "")
            off.target = self
            menu.addItem(off)
        }
        sleepMenuItem?.title = current.map { String(localized: "Таймер сна: \($0.title.lowercased())") } ?? String(localized: "Таймер сна")
    }

    @objc private func startSleep(_ sender: NSMenuItem) {
        sleepTimer.start(sender.tag == 0 ? .endOfTrack : .minutes(sender.tag))
    }

    @objc private func cancelSleep() { sleepTimer.cancel() }

    private func add(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func openPlayer() { player.openPlayer() }
    @objc private func reloadWidgets() { publisher.reloadWidgets() }
    @objc private func checkForUpdates() { updater.checkForUpdates() }
    @objc private func showMiniPlayer() { miniPlayer.show() }

    // MARK: Windows

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(preferences: preferences, player: player, publisher: publisher, history: history,
                                    updater: updater, showMiniPlayer: { [weak self] in self?.miniPlayer.show() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = String(localized: "Настройки TrackPin")
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
