import AppKit

/// A small timing log in ~/Library/Logs/TrackPin.log (the unified log is not readable
/// without admin rights), used to find where a command loses time.
enum Log {
    static let player = FileLog()
}

final class FileLog {
    private let queue = DispatchQueue(label: "dev.lan4ik.needle.log", qos: .utility)
    private let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TrackPin.log")
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func notice(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { [url] in
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// Which player TrackPin follows: one chosen in the settings, or whichever is playing.
enum SourceSelection: Hashable, Identifiable {
    case automatic
    case fixed(MusicSource)

    static var allCases: [SourceSelection] { [.automatic] + MusicSource.allCases.map(SourceSelection.fixed) }

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .automatic: "automatic"
        case let .fixed(source): source.rawValue
        }
    }

    init?(rawValue: String) {
        if rawValue == "automatic" { self = .automatic; return }
        guard let source = MusicSource(rawValue: rawValue) else { return nil }
        self = .fixed(source)
    }

    var title: String {
        switch self {
        case .automatic: String(localized: "Автоматически: тот, что играет")
        case let .fixed(source): source.settingsTitle
        }
    }
}

/// Reads the chosen player as rarely as it can.
///
/// - Spotify and Apple Music post a distributed notification on play, pause and track changes,
///   and TrackPin reads the state right away when it arrives.
/// - The workspace reports when a player starts or quits. While it is closed, nothing is polled.
/// - While a TrackPin window is visible (`isForeground`), the state is polled every
///   `foregroundInterval` seconds so the slider follows seeks made in the player.
/// - In the background a playing track is polled every `backgroundInterval` seconds (0 turns
///   this off), and once more right after it should have ended. Yandex Music posts nothing, so
///   it is also polled while paused.
/// - In automatic mode, when the current player is not playing, the other running players are
///   asked too (at most every `probeInterval` seconds), and TrackPin switches to one that plays.
final class Player: NSObject, ObservableObject {
    typealias Completion = (Playback) -> Void

    @Published private(set) var playback: Playback = .closed
    /// When `playback` was read. The UI extrapolates the position of a playing track from it.
    @Published private(set) var sampledAt = Date()
    /// The player `playback` comes from.
    @Published private(set) var source: MusicSource = .spotify

    var selection: SourceSelection = .automatic {
        didSet {
            guard selection != oldValue else { return }
            if case let .fixed(fixed) = selection, fixed != source {
                source = fixed
                pending.removeAll()
            }
            refresh(probe: true)
        }
    }
    /// Automatic mode also looks for Yandex Music in browser tabs. Off by default: asking a
    /// browser makes macOS show an automation prompt for it.
    var scansBrowser = false {
        didSet { if scansBrowser != oldValue { refresh(probe: true) } }
    }

    var foregroundInterval: TimeInterval = 1 { didSet { if foregroundInterval != oldValue { schedule() } } }
    var backgroundInterval: TimeInterval = 30 { didSet { if backgroundInterval != oldValue { schedule() } } }
    var isForeground = false {
        didSet {
            guard isForeground != oldValue else { return }
            if isForeground { refresh(probe: true) }
            schedule()
        }
    }

    /// Seconds between two looks at the other players in automatic mode.
    private let probeInterval: TimeInterval = 5
    private let backends: [MusicSource: PlayerBackend]
    private let queue = DispatchQueue(label: "dev.lan4ik.needle.player", qos: .utility)
    private var timer: Timer?
    private var busy = false
    /// A refresh was asked for while another one ran.
    private var again = false
    private var lastProbe = Date.distantPast
    /// `expected` is the play state a play/pause should lead to: Spotify can still report the
    /// old state for a moment right after the command.
    private var pending: [(command: PlayerCommand, completion: Completion?, expected: Bool?)] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        let all: [PlayerBackend] = [SpotifyBridge(), AppleMusicBridge(), YandexAppBridge(), YandexWebBridge()]
        backends = Dictionary(uniqueKeysWithValues: all.map { ($0.source, $0) })
        super.init()
        if demo {
            playback = .track(Track(id: "demo", title: "Midnight Drive", artist: "TrackPin",
                                    artwork: nil, duration: 228, position: 72, playing: true,
                                    volume: 70, shuffling: false, repeating: false))
        }
        // `.deliverImmediately`: an accessory app is never active, and AppKit otherwise holds
        // distributed notifications back until the app is activated.
        for backend in all {
            for name in backend.changeNotifications {
                DistributedNotificationCenter.default().addObserver(
                    self, selector: #selector(playerChanged(_:)), name: NSNotification.Name(name),
                    object: nil, suspensionBehavior: .deliverImmediately)
            }
        }
        let watched = Set(all.flatMap(\.bundleIdentifiers) + YandexWebBridge.browsers.map(\.bundleIdentifier))
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let id = app?.bundleIdentifier, watched.contains(id) else { return }
                if name == NSWorkspace.didLaunchApplicationNotification {
                    self?.followLaunch()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.refresh(probe: true) }
                }
            })
        }
        refresh(probe: true)
    }

    /// A freshly started player needs a few seconds before it answers and restores its last
    /// track. Read it a handful of times with growing gaps until a track shows up, instead of
    /// once after a fixed delay that was either too early or needlessly late.
    private func followLaunch() {
        launchGeneration += 1
        let generation = launchGeneration
        for delay in [0.4, 1, 2, 3.5, 5.5, 8, 12, 18] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.launchGeneration == generation else { return }
                if self.playback.currentTrack != nil {
                    self.launchGeneration += 1 // Found it: stop the remaining reads.
                    return
                }
                self.refresh(probe: true)
            }
        }
    }

    deinit {
        timer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    /// Bumped to cancel the reads scheduled by `followLaunch`.
    private var launchGeneration = 0

    private var backend: PlayerBackend { backends[source]! }

    @objc private func playerChanged(_ note: Notification) {
        // Spotify and Music both say "Player State": "Playing" in the notification. In automatic
        // mode a player that starts playing takes over right away.
        if selection == .automatic, (note.userInfo?["Player State"] as? String) == "Playing",
           let origin = backends.values.first(where: { $0.changeNotifications.contains(note.name.rawValue) }),
           origin.source != source {
            source = origin.source
            pending.removeAll()
        }
        refresh()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        var interval: TimeInterval?
        let track = playback.currentTrack
        if isForeground {
            interval = max(0.5, foregroundInterval)
        } else if demo {
            return
        } else if backgroundInterval > 0 {
            if track?.playing == true || !backend.notifies {
                interval = backgroundInterval
            } else if selection == .automatic, backends.values.contains(where: { !$0.notifies && isCandidate($0) }) {
                // Paused here, but Yandex Music may start without telling anyone.
                interval = max(backgroundInterval, 30)
            }
            if !backend.notifies, track?.playing == true { interval = min(interval ?? 5, 5) }
        }
        // Read again just after the track should have ended, so the next one shows up on time.
        if let track, track.playing, track.duration > 0 {
            let ending = track.duration - track.position + 1.5
            interval = min(interval ?? ending, max(ending, 1))
        }
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.refresh() }
        timer.tolerance = interval * (isForeground ? 0.1 : 0.3)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Queues a command. `completion` receives the playback state read right after the command ran.
    func send(_ command: PlayerCommand, completion: Completion? = nil) {
        Log.player.notice("send \(String(describing: command)), busy: \(self.busy)")
        if demo, case var .track(track) = playback {
            switch command {
            case .toggle: track.playing.toggle()
            case .pause: track.playing = false
            case .previous, .next: track.position = 0
            case let .skip(offset): track.position = min(max(0, track.position + Double(offset)), track.duration)
            case let .seek(seconds, _): track.position = seconds
            case let .volume(level): track.volume = level
            case let .shuffle(on): track.shuffling = on
            case let .repeating(on): track.repeating = on
            }
            update(.track(track), from: source)
            completion?(playback)
            return
        }
        // Show the new play state right away; the read after the command confirms it.
        var expected: Bool?
        if command == .toggle || command == .pause, case var .track(track) = playback {
            if track.playing { track.position = min(track.duration, track.position + Date().timeIntervalSince(sampledAt)) }
            track.playing = command == .pause ? false : !track.playing
            expected = track.playing
            sampledAt = Date()
            playback = .track(track)
        }
        if command.coalesces, let last = pending.last, last.command.sameKind(as: command), last.completion == nil {
            pending.removeLast()
        }
        pending.append((command, completion, expected))
        refresh()
    }

    /// Opens the current player.
    func openPlayer() {
        backend.open()
    }

    func retry() {
        refresh(probe: true)
    }

    private func update(_ value: Playback, from origin: MusicSource) {
        sampledAt = Date()
        if origin != source { source = origin }
        if value != playback { playback = value }
        schedule()
    }

    private func isCandidate(_ backend: PlayerBackend) -> Bool {
        if backend.source == .yandexWeb && !scansBrowser { return false }
        return backend.isAvailable
    }

    /// How interesting a state is in automatic mode: playing beats paused beats nothing.
    private static func rank(_ playback: Playback) -> Int {
        switch playback {
        case let .track(track): track.playing ? 3 : 2
        case .idle: 1
        case .closed, .denied, .unavailable: 0
        }
    }

    private func refresh(probe forced: Bool = false) {
        if demo {
            if case var .track(track) = playback, track.playing {
                track.position = min(track.duration, track.position + Date().timeIntervalSince(sampledAt))
                if track.position == track.duration { track.playing = false }
                update(.track(track), from: source)
            }
            return
        }
        guard !busy else {
            again = true
            return
        }
        busy = true
        let next = pending.isEmpty ? nil : pending.removeFirst()
        let active = backend
        var others: [PlayerBackend] = []
        if selection == .automatic, next == nil, forced || Date().timeIntervalSince(lastProbe) >= probeInterval {
            // Players that notify come first: they answer fastest.
            others = MusicSource.allCases.compactMap { backends[$0] }
                .filter { $0.source != active.source && isCandidate($0) }
            lastProbe = Date()
        }
        let queued = Date()
        queue.async {
            let started = Date()
            var result = active.read(command: next?.command)
            // Right after play/pause the player may still answer with the old state. Read again
            // briefly until it agrees, so the widget does not show (and keep) the stale state.
            if let expected = next?.expected {
                var attempts = 0
                while attempts < 6, let track = result.currentTrack, track.playing != expected {
                    usleep(120_000)
                    result = active.read(command: nil)
                    attempts += 1
                }
                if attempts > 0 { Log.player.notice("play state settled after \(attempts) extra reads") }
            }
            if let command = next?.command {
                Log.player.notice("command \(String(describing: command)): waited \(Int(started.timeIntervalSince(queued) * 1000)) ms, ran \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
            var origin = active.source
            if Self.rank(result) < 3 {
                for other in others {
                    let candidate = other.read(command: nil)
                    if Self.rank(candidate) > Self.rank(result) {
                        result = candidate
                        origin = other.source
                        if Self.rank(result) == 3 { break }
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // When the source changed meanwhile (a choice in the settings, or another player
                // started), this read is stale: drop it and read the new source.
                let stillValid = self.source == active.source
                if !stillValid { self.again = true }
                if self.pending.isEmpty, stillValid { self.update(result, from: origin) }
                self.busy = false
                next?.completion?(result)
                if !self.pending.isEmpty || self.again {
                    self.again = false
                    self.refresh()
                }
            }
        }
    }
}

extension MusicSource {
    /// What to allow when the player answers with `.denied`.
    var accessHint: String {
        switch self {
        case .spotify, .appleMusic:
            String(localized: "Разреши TrackPin управлять \(title) в разделе «Автоматизация».")
        case .yandexApp:
            String(localized: "Включи TrackPin в разделе «Универсальный доступ»: так он видит плеер Яндекс Музыки.")
        case .yandexWeb:
            String(localized: "Разреши TrackPin управлять браузером в разделе «Автоматизация» и включи в браузере «Разрешить JavaScript из Apple Events».")
        }
    }

    /// Opens the part of System Settings that `accessHint` talks about.
    func requestAccess() {
        let pane: String
        if self == .yandexApp {
            YandexAppBridge.requestAccess()
            pane = "Privacy_Accessibility"
        } else {
            pane = "Privacy_Automation"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
