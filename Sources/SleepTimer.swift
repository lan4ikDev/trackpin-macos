import AppKit
import Combine
import UserNotifications

/// Pauses playback after a number of minutes or at the end of the current track. In minutes
/// mode the volume fades out over the last seconds and is restored after the pause.
final class SleepTimer: ObservableObject {
    enum Mode: Equatable {
        case minutes(Int)
        case endOfTrack
    }

    static let presets = [15, 30, 45, 60, 90]
    private static let fade: TimeInterval = 12

    @Published private(set) var mode: Mode?
    /// When playback will be paused. For `endOfTrack` it follows the track's remaining time.
    @Published private(set) var deadline: Date?

    private let player: Player
    private var timer: Timer?
    private var fadeTimer: Timer?
    private var trackID: String?
    private var observation: AnyCancellable?

    init(player: Player) {
        self.player = player
    }

    var isActive: Bool { mode != nil }

    func start(_ mode: Mode) {
        cancel()
        self.mode = mode
        switch mode {
        case let .minutes(minutes):
            setDeadline(Date().addingTimeInterval(TimeInterval(minutes * 60)))
        case .endOfTrack:
            trackID = player.playback.currentTrack?.id
            observation = player.$playback.sink { [weak self] playback in
                DispatchQueue.main.async { self?.followTrack(playback) }
            }
        }
    }

    func cancel() {
        timer?.invalidate()
        fadeTimer?.invalidate()
        timer = nil
        fadeTimer = nil
        observation = nil
        trackID = nil
        mode = nil
        deadline = nil
    }

    private func followTrack(_ playback: Playback) {
        guard mode == .endOfTrack else { return }
        guard let track = playback.currentTrack else { return }
        if trackID == nil { trackID = track.id }
        if track.id != trackID {
            // Spotify already moved on to the next track: stop it right away.
            fire()
            return
        }
        guard track.playing else {
            timer?.invalidate()
            timer = nil
            deadline = nil
            return
        }
        let remaining = max(0, track.duration - track.position) - 0.6
        setDeadline(player.sampledAt.addingTimeInterval(max(0.2, remaining)))
    }

    private func setDeadline(_ date: Date) {
        deadline = date
        timer?.invalidate()
        var fireAt = date
        if case .minutes = mode, date.timeIntervalSinceNow > Self.fade {
            fireAt = date.addingTimeInterval(-Self.fade)
        }
        let timer = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            if case .minutes = self.mode, let deadline = self.deadline, deadline.timeIntervalSinceNow > 1 {
                self.fadeOut(until: deadline)
            } else {
                self.fire()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fadeOut(until deadline: Date) {
        guard let start = player.playback.currentTrack?.volume, start > 0 else {
            let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in self?.fire() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            return
        }
        let total = deadline.timeIntervalSinceNow
        let began = Date()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, Date().timeIntervalSince(began) / total)
            if progress >= 1 {
                timer.invalidate()
                self.fire(restoreVolume: start)
            } else {
                self.player.send(.volume(Int(Double(start) * (1 - progress))))
            }
        }
    }

    private func fire(restoreVolume: Int? = nil) {
        player.send(.pause) { [weak self] _ in
            if let restoreVolume { self?.player.send(.volume(restoreVolume)) }
        }
        cancel()
    }
}

extension SleepTimer.Mode {
    var title: String {
        switch self {
        case let .minutes(minutes): "Через \(minutes) мин"
        case .endOfTrack: "В конце трека"
        }
    }
}

/// Shows a notification with the cover when the track changes.
final class TrackNotifier {
    private var lastID: String?
    private var pending: DispatchWorkItem?
    private var authorized = false

    var enabled = false {
        didSet { if enabled && !oldValue { requestAuthorization() } }
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.authorized = granted }
        }
    }

    /// Call on every playback change. `cover` returns the cover data once it has loaded.
    func update(_ playback: Playback, suppressed: Bool, cover: @escaping () -> Data?) {
        guard let track = playback.currentTrack else { return }
        defer { lastID = track.id }
        // The first track seen after launch is not a change.
        guard let lastID, track.id != lastID else { return }
        pending?.cancel()
        guard enabled, authorized, track.playing, !suppressed else { return }
        // Give the cover a moment to download so the notification can show it.
        let work = DispatchWorkItem { [weak self] in self?.post(track, cover: cover()) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func post(_ track: Track, cover: Data?) {
        let content = UNMutableNotificationContent()
        content.title = track.title
        content.body = track.artist
        content.threadIdentifier = "now-playing"
        if let cover {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("trackpin-cover-\(UUID().uuidString).jpg")
            if (try? cover.write(to: url)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "cover", url: url) {
                content.attachments = [attachment]
            }
        }
        // One notification at a time: the new track replaces the previous one.
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.add(UNNotificationRequest(identifier: "now-playing", content: content, trigger: nil))
    }
}
