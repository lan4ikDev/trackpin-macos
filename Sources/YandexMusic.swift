import AppKit
import ApplicationServices

// Yandex Music has no AppleScript dictionary and posts no notifications, and since macOS 15.4
// the system "Now Playing" information is closed to other apps. TrackPin therefore reads it in
// two ways that macOS allows openly:
//
// - The desktop app (Electron) through the Accessibility API: the same tree VoiceOver reads.
//   Needs TrackPin in System Settings → Privacy & Security → Accessibility.
// - A music.yandex.ru tab in Safari or a Chromium browser through AppleScript's "execute
//   javascript". Needs "Allow JavaScript from Apple Events" in the browser.
//
// Both look for the player bar by its buttons and links, so a redesign of Yandex Music can break
// them. They fail softly: the widget then says the player did not answer.

// MARK: - Desktop app

final class YandexAppBridge: PlayerBackend {
    static let bundleIdentifiers = ["ru.yandex.desktop.music", "ru.yandex.music", "ru.yandex.desktop.music.app"]

    let source = MusicSource.yandexApp
    let bundleIdentifiers = YandexAppBridge.bundleIdentifiers
    let changeNotifications: [String] = []

    /// Only touched on the player queue.
    private var bar: AXUIElement?
    private var barPID: pid_t = 0
    private var enabledPID: pid_t = 0

    var isAvailable: Bool { Self.runningApp(bundleIdentifiers) != nil }

    func open() {
        Self.openApp(bundleIdentifiers, fallback: "https://music.yandex.ru/download/")
    }

    /// Asks macOS to add TrackPin to the Accessibility list (shows the system prompt once).
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func read(command: PlayerCommand?) -> Playback {
        guard let app = Self.runningApp(bundleIdentifiers) else { return .closed }
        guard AXIsProcessTrusted() else { return .denied }
        let pid = app.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 1.5)
        if enabledPID != pid {
            // Chromium builds its accessibility tree only for assistive apps that ask for it.
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enabledPID = pid
            bar = nil
        }
        if let command, let before = self.scan(root: root, pid: pid) {
            perform(command, on: before)
            usleep(350_000)
        }
        guard let after = self.scan(root: root, pid: pid) else { return .unavailable }
        return after.playback
    }

    // MARK: Scanning

    private struct Node {
        let element: AXUIElement
        let role: String
        let label: String
        let url: String?
        let text: String
        let frame: CGRect
        let value: Double?
        let maxValue: Double?
        let parent: Int?
    }

    private struct Scan {
        var nodes: [Node]
        var play: Int
        var playing: Bool

        func inBar(_ index: Int) -> Bool {
            abs(nodes[index].frame.midY - nodes[play].frame.midY) < 70
        }

        func button(_ words: [String]) -> AXUIElement? {
            let found = nodes.indices.filter { i in
                nodes[i].role == kAXButtonRole as String && inBar(i) && words.contains { nodes[i].label.hasPrefix($0) }
            }
            return found.min { abs(nodes[$0].frame.midY - nodes[play].frame.midY) < abs(nodes[$1].frame.midY - nodes[play].frame.midY) }
                .map { nodes[$0].element }
        }

        var sliders: [Node] {
            nodes.indices.filter { nodes[$0].role == kAXSliderRole as String && inBar($0) }
                .map { nodes[$0] }.sorted { $0.frame.width > $1.frame.width }
        }

        var playback: Playback {
            let bar = nodes.indices.filter(inBar)
            func links(_ pattern: String) -> [Node] {
                bar.map { nodes[$0] }.filter { $0.role == kAXLinkRole as String && ($0.url?.contains(pattern) ?? false) && !$0.text.isEmpty }
                    .sorted { $0.frame.minX < $1.frame.minX }
            }
            guard let title = links("/track/").first else { return .idle }
            var artists: [String] = []
            for link in links("/artist/") where !artists.contains(link.text) { artists.append(link.text) }

            var position = 0.0, duration = 0.0
            let times = bar.map { nodes[$0] }
                .filter { $0.role == kAXStaticTextRole as String && YandexAppBridge.seconds($0.text) != nil }
                .sorted { $0.frame.minX < $1.frame.minX }
            if times.count >= 2, let start = YandexAppBridge.seconds(times[0].text),
               let end = YandexAppBridge.seconds(times[times.count - 1].text) {
                position = abs(start)
                duration = end < 0 ? position - end : end
            } else if let progress = sliders.first, let max = progress.maxValue, max > 1 {
                duration = max
                position = progress.value ?? 0
            }

            let id = title.url.flatMap(YandexAppBridge.trackID).map { "yandex:track:\($0)" }
                ?? "yandex:app:\(title.text)|\(artists.joined(separator: ", "))"
            let cover = bar.map { nodes[$0] }
                .filter { $0.role == kAXImageRole as String && ($0.url?.hasPrefix("https://") ?? false) }
                .min { $0.frame.minX < $1.frame.minX }
                .flatMap { $0.url }
                .map(YandexAppBridge.largeCover)
                .flatMap(URL.init(string:))
            var track = Track(id: id, title: title.text, artist: artists.joined(separator: ", "), artwork: cover,
                              duration: duration, position: duration > 0 ? min(position, duration) : position, playing: playing)
            if sliders.count >= 2, let volume = sliders.last, let max = volume.maxValue, max > 0 {
                track.volume = Int(((volume.value ?? 0) / max * 100).rounded())
            }
            return .track(track)
        }
    }

    private static let pauseWords = ["пауза", "pause", "приостановить"]
    private static let playWords = ["воспроизв", "play", "слушать", "играть"]

    /// Finds the player bar: the bottom-most play or pause button and what sits next to it.
    /// The subtree that holds them is remembered, so later reads skip the rest of the window.
    private func scan(root: AXUIElement, pid: pid_t) -> Scan? {
        if let bar, barPID == pid, let found = self.scan(from: bar, cacheBar: false) { return found }
        bar = nil
        let windows = Self.attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for window in windows {
            if let found = self.scan(from: window, cacheBar: true) {
                barPID = pid
                return found
            }
        }
        return nil
    }

    private func scan(from start: AXUIElement, cacheBar: Bool) -> Scan? {
        var nodes: [Node] = []
        _ = collect(start, parent: nil, depth: 0, into: &nodes)
        let toggles = nodes.indices.filter { i in
            nodes[i].role == kAXButtonRole as String
                && (Self.pauseWords + Self.playWords).contains { nodes[i].label.hasPrefix($0) }
        }
        guard let play = toggles.max(by: { nodes[$0].frame.midY < nodes[$1].frame.midY }) else { return nil }
        let playing = Self.pauseWords.contains { nodes[play].label.hasPrefix($0) }
        let scan = Scan(nodes: nodes, play: play, playing: playing)
        if cacheBar {
            // The lowest ancestor of the play button that also holds the track link.
            let titles = nodes.indices.filter { scan.inBar($0) && (nodes[$0].url?.contains("/track/") ?? false) }
            if let title = titles.first {
                var chain = Set<Int>()
                var cursor: Int? = play
                while let index = cursor { chain.insert(index); cursor = nodes[index].parent }
                cursor = title
                while let index = cursor, !chain.contains(index) { cursor = nodes[index].parent }
                if let common = cursor { bar = nodes[common].element }
            }
        }
        return scan
    }

    /// Walks the tree depth first. Returns the text of the subtree, used as the name of links.
    @discardableResult
    private func collect(_ element: AXUIElement, parent: Int?, depth: Int, into nodes: inout [Node]) -> String {
        guard depth < 60, nodes.count < 6000 else { return "" }
        let role = Self.attribute(element, kAXRoleAttribute) as? String ?? ""
        let title = Self.attribute(element, kAXTitleAttribute) as? String ?? ""
        let description = Self.attribute(element, kAXDescriptionAttribute) as? String ?? ""
        let value = Self.attribute(element, kAXValueAttribute)
        var url: String?
        if role == kAXLinkRole as String || role == kAXImageRole as String {
            url = (Self.attribute(element, kAXURLAttribute) as? URL)?.absoluteString
        }
        var maxValue: Double?
        if role == kAXSliderRole as String {
            maxValue = (Self.attribute(element, kAXMaxValueAttribute) as? NSNumber)?.doubleValue
        }
        let index = nodes.count
        let label = (description.isEmpty ? title : description)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        nodes.append(Node(element: element, role: role, label: label, url: url, text: "",
                          frame: Self.frame(element), value: (value as? NSNumber)?.doubleValue,
                          maxValue: maxValue, parent: parent))
        var text = role == kAXStaticTextRole as String ? (value as? String ?? "") : ""
        // Buttons hold icons, not names; skipping their children keeps the walk short.
        if role != kAXButtonRole as String, role != kAXSliderRole as String {
            for child in Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                let inner = collect(child, parent: index, depth: depth + 1, into: &nodes)
                if !inner.isEmpty, text.count < 200 { text += text.isEmpty ? inner : " " + inner }
            }
        }
        let own = [title, description].first { !$0.isEmpty } ?? ""
        let name = (role == kAXLinkRole as String && !own.isEmpty ? own : text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let node = nodes[index]
        nodes[index] = Node(element: node.element, role: node.role, label: node.label, url: node.url, text: name,
                            frame: node.frame, value: node.value, maxValue: node.maxValue, parent: node.parent)
        return name
    }

    // MARK: Commands

    private func perform(_ command: PlayerCommand, on scan: Scan) {
        switch command {
        case .toggle:
            AXUIElementPerformAction(scan.nodes[scan.play].element, kAXPressAction as CFString)
        case .pause:
            if scan.playing { AXUIElementPerformAction(scan.nodes[scan.play].element, kAXPressAction as CFString) }
        case .next:
            press(scan.button(["следующ", "next", "вперёд", "вперед"]))
        case .previous:
            press(scan.button(["предыдущ", "previous", "назад"]))
        case .shuffle:
            press(scan.button(["перемеш", "shuffle", "случайн"]))
        case .repeating:
            press(scan.button(["повтор", "repeat"]))
        case let .skip(offset):
            guard let track = scan.playback.currentTrack else { return }
            seek(to: track.position + Double(offset), in: scan, duration: track.duration)
        case let .seek(seconds, _):
            guard let track = scan.playback.currentTrack else { return }
            seek(to: seconds, in: scan, duration: track.duration)
        case let .volume(level):
            let sliders = scan.sliders
            guard sliders.count >= 2, let slider = sliders.last, let max = slider.maxValue else { return }
            AXUIElementSetAttributeValue(slider.element, kAXValueAttribute as CFString,
                                         NSNumber(value: Double(min(Swift.max(level, 0), 100)) / 100 * max))
        }
    }

    private func press(_ element: AXUIElement?) {
        guard let element else { return }
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    private func seek(to seconds: Double, in scan: Scan, duration: Double) {
        guard let slider = scan.sliders.first, let max = slider.maxValue, max > 0, duration > 0 else { return }
        let target = min(Swift.max(seconds, 0), duration)
        // The slider counts in seconds or in its own units; scale to whichever it uses.
        let value = abs(max - duration) < 2 ? target : target / duration * max
        AXUIElementSetAttributeValue(slider.element, kAXValueAttribute as CFString, NSNumber(value: value))
    }

    // MARK: Helpers

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func frame(_ element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        if let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgPoint, &origin)
        }
        if let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    /// "1:23" → 83, "-0:45" → -45, "1:02:03" → 3723. Nil for anything else.
    static func seconds(_ text: String) -> Double? {
        var string = text.trimmingCharacters(in: .whitespaces)
        var sign = 1.0
        if string.hasPrefix("-") || string.hasPrefix("−") { sign = -1; string.removeFirst() }
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isNumber) }) else { return nil }
        let total = parts.reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
        return sign * total
    }

    /// The numeric id in links like `/album/123/track/456`.
    static func trackID(_ link: String) -> String? {
        guard let range = link.range(of: "/track/") else { return nil }
        let id = link[range.upperBound...].prefix { $0.isNumber }
        return id.isEmpty ? nil : String(id)
    }

    /// Yandex covers end in a size such as `/100x100`; ask for a bigger one.
    static func largeCover(_ link: String) -> String {
        guard let range = link.range(of: #"/\d{2,4}x\d{2,4}$"#, options: .regularExpression) else { return link }
        return link.replacingCharacters(in: range, with: "/400x400")
    }
}

// MARK: - Browser tab

final class YandexWebBridge: PlayerBackend {
    struct Browser {
        let bundleIdentifier: String
        let safari: Bool
    }

    static let browsers = [
        Browser(bundleIdentifier: "com.apple.Safari", safari: true),
        Browser(bundleIdentifier: "com.google.Chrome", safari: false),
        Browser(bundleIdentifier: "ru.yandex.desktop.yandex-browser", safari: false),
        Browser(bundleIdentifier: "company.thebrowser.Browser", safari: false),
        Browser(bundleIdentifier: "com.microsoft.edgemac", safari: false),
        Browser(bundleIdentifier: "com.brave.Browser", safari: false),
        Browser(bundleIdentifier: "com.vivaldi.Vivaldi", safari: false),
        Browser(bundleIdentifier: "org.chromium.Chromium", safari: false)
    ]

    let source = MusicSource.yandexWeb
    var bundleIdentifiers: [String] { [] }
    let changeNotifications: [String] = []

    /// Only touched on the player queue.
    private var readScripts: [String: NSAppleScript] = [:]

    var isAvailable: Bool { !runningBrowsers.isEmpty }

    private var runningBrowsers: [Browser] {
        Self.browsers.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleIdentifier).isEmpty }
    }

    func open() {
        if let url = URL(string: "https://music.yandex.ru") { NSWorkspace.shared.open(url) }
    }

    func read(command: PlayerCommand?) -> Playback {
        var denied = false
        var idle = false
        for browser in runningBrowsers {
            var result: NSAppleEventDescriptor?
            var error: NSDictionary?
            if let command {
                let outcome = AppleScript.run(Self.script(for: browser, command: Self.javascript(command)))
                result = outcome.0
                error = outcome.1
            } else {
                if readScripts[browser.bundleIdentifier] == nil {
                    readScripts[browser.bundleIdentifier] = NSAppleScript(source: Self.script(for: browser, command: nil))
                }
                result = readScripts[browser.bundleIdentifier]?.executeAndReturnError(&error)
            }
            if let error {
                if AppleScript.failure(error, reading: true) == .denied { denied = true }
                continue
            }
            guard let text = result?.stringValue, text != "none" else { continue }
            switch Self.decode(text) {
            case let .track(track): return .track(track)
            case .idle: idle = true
            default: continue
            }
        }
        if idle { return .idle }
        return denied ? .denied : .closed
    }

    // MARK: Scripts

    /// The page script. `window.externalAPI` is the documented API of music.yandex.ru; when a
    /// redesign drops it, the script falls back to the Media Session metadata, the `<audio>`
    /// element and the buttons of the player bar.
    private static let pageScript = """
    (function (cmd, arg) {
      function label(b) { return String(b.getAttribute('aria-label') || b.getAttribute('title') || '').trim().toLowerCase(); }
      function button(words, exact) {
        var found = null, all = document.querySelectorAll('button, [role="button"]');
        for (var i = 0; i < all.length; i++) {
          var l = label(all[i]);
          for (var j = 0; j < words.length; j++) { if (exact ? l === words[j] : l.indexOf(words[j]) === 0) { found = all[i]; } }
        }
        return found;
      }
      function media() {
        var all = document.querySelectorAll('audio, video'), pick = null;
        for (var i = 0; i < all.length; i++) { if (all[i].currentSrc && (!pick || !all[i].paused)) { pick = all[i]; } }
        return pick;
      }
      function done() { return JSON.stringify({ ok: true }); }
      var api = window.externalAPI;
      if (api && typeof api.getCurrentTrack === 'function') {
        try {
          if (cmd === 'toggle') { api.togglePause(); return done(); }
          if (cmd === 'pause') { if (api.isPlaying()) { api.togglePause(); } return done(); }
          if (cmd === 'next') { api.next(); return done(); }
          if (cmd === 'previous') { api.prev(); return done(); }
          if (cmd === 'seek') { api.setPosition(arg); return done(); }
          if (cmd === 'skip') { var pr = api.getProgress() || {}; api.setPosition(Math.max(0, Math.min(pr.duration || 0, (pr.position || 0) + arg))); return done(); }
          if (cmd === 'volume') { api.setVolume(arg / 100); return done(); }
          if (cmd === 'shuffle') { if (!!api.getShuffle() !== !!arg) { api.toggleShuffle(); } return done(); }
          if (cmd === 'repeat') { var rr = api.getRepeat(); if ((rr === 1 || rr === 2 || rr === true) !== !!arg) { api.toggleRepeat(); } return done(); }
          var t = api.getCurrentTrack();
          if (!t) { return JSON.stringify({ ok: true, idle: true }); }
          var p = api.getProgress() || {};
          var cover = t.cover ? String(t.cover).replace('%%', '400x400') : '';
          if (cover.indexOf('//') === 0) { cover = 'https:' + cover; }
          var m = String(t.link || '').match(/track\\/(\\d+)/);
          var r = api.getRepeat();
          return JSON.stringify({ ok: true, id: m ? m[1] : '', title: t.title || '',
            artist: (t.artists || []).map(function (a) { return a.title; }).join(', '),
            cover: cover, duration: +(p.duration || t.duration || 0), position: +(p.position || 0),
            playing: !!api.isPlaying(), volume: Math.round((+api.getVolume() || 0) * 100),
            shuffle: !!api.getShuffle(), repeat: r === 1 || r === 2 || r === true });
        } catch (e) {}
      }
      var el = media();
      if (cmd === 'toggle') {
        var b = button(['пауза', 'pause', 'воспроизведение', 'воспроизвести', 'play', 'слушать'], true);
        if (b) { b.click(); } else if (el) { if (el.paused) { el.play(); } else { el.pause(); } }
        return done();
      }
      if (cmd === 'pause') {
        var pb = button(['пауза', 'pause'], true);
        if (pb) { pb.click(); } else if (el && !el.paused) { el.pause(); }
        return done();
      }
      if (cmd === 'next') { var n = button(['следующ', 'next'], false); if (n) { n.click(); } return done(); }
      if (cmd === 'previous') { var v = button(['предыдущ', 'previous'], false); if (v) { v.click(); } return done(); }
      if (cmd === 'shuffle') { var s = button(['перемеш', 'shuffle'], false); if (s) { s.click(); } return done(); }
      if (cmd === 'repeat') { var rp = button(['повтор', 'repeat'], false); if (rp) { rp.click(); } return done(); }
      if (cmd === 'seek') { if (el) { el.currentTime = Math.max(0, arg); } return done(); }
      if (cmd === 'skip') { if (el) { el.currentTime = Math.max(0, Math.min(el.duration || 0, el.currentTime + arg)); } return done(); }
      if (cmd === 'volume') { if (el) { el.volume = Math.max(0, Math.min(1, arg / 100)); } return done(); }
      var ms = navigator.mediaSession, md = ms && ms.metadata;
      if (!md || !md.title) { return JSON.stringify({ ok: true, idle: true }); }
      var art = (md.artwork || []).slice(-1)[0];
      var link = document.querySelector('[class*="PlayerBar"] a[href*="/track/"]');
      var lm = link ? String(link.getAttribute('href')).match(/track\\/(\\d+)/) : null;
      var playing = el ? !el.paused : (ms.playbackState === 'playing' || (ms.playbackState !== 'paused' && !!button(['пауза', 'pause'], true)));
      return JSON.stringify({ ok: true, id: lm ? lm[1] : '', title: md.title, artist: md.artist || '',
        cover: art ? art.src : '', duration: el && isFinite(el.duration) ? el.duration : 0,
        position: el ? el.currentTime : 0, playing: playing, volume: el ? Math.round(el.volume * 100) : null });
    })
    """

    /// The page script called with a command and argument, as one line of JavaScript.
    private static func call(_ command: String, _ argument: Double) -> String {
        let body = pageScript.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return "\(body)('\(command)', \(argument))"
    }

    private static func javascript(_ command: PlayerCommand) -> String {
        switch command {
        case .toggle: call("toggle", 0)
        case .pause: call("pause", 0)
        case .next: call("next", 0)
        case .previous: call("previous", 0)
        case let .skip(offset): call("skip", Double(offset))
        case let .seek(seconds, _): call("seek", max(0, seconds))
        case let .volume(level): call("volume", Double(min(max(level, 0), 100)))
        case let .shuffle(on): call("shuffle", on ? 1 : 0)
        case let .repeating(on): call("repeat", on ? 1 : 0)
        }
    }

    /// Finds the music.yandex tabs, prefers one that plays, runs `command` there, then reads it.
    static func script(for browser: Browser, command: String?) -> String {
        func run(_ tab: String, _ code: String) -> String {
            browser.safari ? "do JavaScript \(code) in \(tab)" : "execute \(tab) javascript \(code)"
        }
        let read = AppleScript.literal(call("", 0))
        let action = command.map { """
            \(run("target", AppleScript.literal($0)))
            delay 0.35
            set state to \(run("target", "readCode"))
            if state is missing value then set state to ""
            """ } ?? ""
        return AppleScript.wrap("""
            set readCode to \(read)
            set found to {}
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        set u to URL of t
                        if u is not missing value and u contains "music.yandex." then set end of found to contents of t
                    end repeat
                end try
            end repeat
            if (count of found) is 0 then return "none"
            set target to item 1 of found
            set state to ""
            repeat with t in found
                set r to \(run("(contents of t)", "readCode"))
                if r is missing value then set r to ""
                if state is "" then set state to r
                if r contains "\\"playing\\":true" then
                    set target to contents of t
                    set state to r
                    exit repeat
                end if
            end repeat
            \(action)
            return state
            """, bundleIdentifier: browser.bundleIdentifier, timeout: 5)
    }

    private struct State: Decodable {
        var idle: Bool?
        var id: String?
        var title: String?
        var artist: String?
        var cover: String?
        var duration: Double?
        var position: Double?
        var playing: Bool?
        var volume: Int?
        var shuffle: Bool?
        var repeating: Bool?

        enum CodingKeys: String, CodingKey {
            case idle, id, title, artist, cover, duration, position, playing, volume, shuffle
            case repeating = "repeat"
        }
    }

    static func decode(_ text: String) -> Playback {
        guard let state = try? JSONDecoder().decode(State.self, from: Data(text.utf8)) else { return .unavailable }
        guard state.idle != true, let title = state.title, !title.isEmpty else { return .idle }
        let artist = state.artist ?? ""
        let id = state.id.flatMap { $0.isEmpty ? nil : "yandex:track:\($0)" } ?? "yandex:web:\(title)|\(artist)"
        let duration = max(0, state.duration.flatMap { $0.isFinite ? $0 : nil } ?? 0)
        let position = max(0, state.position.flatMap { $0.isFinite ? $0 : nil } ?? 0)
        let cover = state.cover.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        var track = Track(id: id, title: title, artist: artist, artwork: cover, duration: duration,
                          position: duration > 0 ? min(position, duration) : position, playing: state.playing ?? false)
        track.volume = state.volume
        track.shuffling = state.shuffle
        track.repeating = state.repeating
        return .track(track)
    }
}
