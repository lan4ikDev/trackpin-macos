import AppKit
import Combine
import Network
import WidgetKit

/// Serves the current `WidgetSnapshot` to the widget extension over loopback and
/// executes the commands its buttons send. See `WidgetTransport` for the protocol.
final class WidgetPublisher: ObservableObject {
    typealias CommandHandler = (PlayerAction, Int, @escaping () -> Void) -> Void

    @Published private(set) var snapshot: WidgetSnapshot = .offline
    @Published private(set) var listening = false
    /// The current cover, decoded once for the mini player.
    @Published private(set) var coverImage: NSImage?
    /// A small, heavily blurred copy of the cover for backgrounds. Blurring once here is far
    /// cheaper than a live `.blur` modifier that SwiftUI would recompute on every redraw.
    @Published private(set) var blurredCover: NSImage?
    /// Runs a widget command and calls the closure once the new state was published.
    var onCommand: CommandHandler?

    private var listener: NWListener?
    /// The encoded snapshot, built lazily when the widget asks: the app reads the player far more
    /// often than the widget reloads, and the snapshot carries the cover.
    private var encoded: Data?
    /// The artwork URL of the current track.
    private var coverURL: URL?
    /// Loaded covers by artwork URL, newest last, so going back to a recent track shows its
    /// cover at once. Only touched on the main thread.
    private var covers: [URL: Artwork.Loaded] = [:]
    private var coverOrder: [URL] = []
    private var loading: [URL: Task<Void, Never>] = [:]
    /// Covers that failed to load; not retried until the track changes again.
    private var failedCovers: Set<URL> = []
    /// The palette for the app's own windows. It keeps the previous cover's colors while the
    /// new cover loads, to avoid a flash of the fallback theme.
    @Published private(set) var displayPalette: ArtworkPalette?
    private var pendingReload: DispatchWorkItem?
    /// When the widget extension last asked for a snapshot.
    private var lastConnection = Date.distantPast
    private var lastRevival = Date.distantPast
    /// The snapshot the widget received last.
    private var lastServed: WidgetSnapshot?
    private var suppressedUntil = Date.distantPast

    init() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: WidgetTransport.address, port: WidgetTransport.port)
        params.allowLocalEndpointReuse = true
        listener = try? NWListener(using: params)
        listener?.newConnectionHandler = { [weak self] in self?.serve($0) }
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.listening = true
                WidgetCenter.shared.reloadAllTimelines()
            case let .failed(error):
                self?.listening = false
                NSLog("TrackPin widget listener: %@", error.localizedDescription)
            default: break
            }
        }
        listener?.start(queue: .main)
    }

    deinit { listener?.cancel(); loading.values.forEach { $0.cancel() } }

    // MARK: Server

    private func serve(_ connection: NWConnection) {
        Log.player.notice("widget connection")
        lastConnection = Date()
        connection.start(queue: .main)
        receiveLine(on: connection, buffer: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { connection.cancel() }
    }

    private func receiveLine(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: WidgetTransport.maximumRequest) { [weak self] bytes, _, eof, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let bytes { buffer.append(bytes) }
            guard error == nil, buffer.count <= WidgetTransport.maximumRequest else { connection.cancel(); return }
            guard buffer.contains(UInt8(ascii: "\n")) else {
                if eof { connection.cancel() } else { self.receiveLine(on: connection, buffer: buffer) }
                return
            }
            guard let request = WidgetTransport.Request(line: String(decoding: buffer, as: UTF8.self)) else {
                connection.cancel()
                return
            }
            switch request {
            case .snapshot:
                self.reply(on: connection)
            case let .command(action, step):
                Log.player.notice("widget command \(action.rawValue)")
                // WidgetKit reloads the widget by itself once the button's intent returns, so a
                // reload from the app now would only spend the daily budget twice.
                self.suppressReloads(for: 3)
                guard let onCommand = self.onCommand else { self.reply(on: connection); return }
                onCommand(action, step) { [weak self] in self?.reply(on: connection) }
            }
        }
    }

    private func reply(on connection: NWConnection) {
        if encoded == nil { encoded = try? JSONEncoder().encode(snapshot) }
        let sent = snapshot
        guard let response = encoded else { connection.cancel(); return }
        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            if error != nil { connection.cancel() } else { self?.lastServed = sent }
            Log.player.notice("sent \(sent.playback.currentTrack?.title ?? "-"), cover: \(sent.cover != nil), error: \(error != nil)")
        })
    }

    // MARK: Publishing
    //
    // The snapshot is rebuilt from scratch on every change: the playback, and the cover cached
    // for exactly that track's artwork URL (or none). So the widget can never get a cover or
    // colors of another track. Whether to reload the widget is decided in one place,
    // `syncWidget`, by comparing with what the widget actually received last.

    func publish(_ playback: Playback, style: WidgetStyle, source: MusicSource? = nil) {
        let source = source ?? snapshot.source
        let url = playback.currentTrack?.artwork
        if url != coverURL {
            coverURL = url
            if let url { failedCovers.remove(url) }
            startLoadingCover()
        }
        let loaded = url.flatMap { covers[$0] }
        // The mini player keeps showing the previous cover until the new one is there.
        if url == nil || url.map(failedCovers.contains) == true {
            shownCoverURL = nil
            coverImage = nil
            blurredCover = nil
            displayPalette = nil
        } else if let loaded, coverImage == nil || shownCoverURL != url {
            shownCoverURL = url
            coverImage = NSImage(data: loaded.data)
            blurredCover = Artwork.blurred(loaded.widgetData)
            displayPalette = loaded.palette
        }

        let next = WidgetSnapshot(playback: playback, sampledAt: Date(), cover: loaded?.widgetData,
                                  palette: loaded?.palette, style: style, source: source)
        let changed = needsReload(from: snapshot, to: next)
        encoded = nil
        snapshot = next
        if changed {
            // Give a cover that is still downloading a moment, so the widget gets the new track
            // and its cover in one reload; `finishedLoading` syncs again when it arrives.
            let waitForCover = loaded == nil && url.map { loading[$0] != nil } == true
            syncWidget(after: waitForCover ? 1.2 : 0.5)
        }
    }

    /// The URL whose cover the mini player shows.
    private var shownCoverURL: URL?

    private func startLoadingCover() {
        guard let url = coverURL, covers[url] == nil, loading[url] == nil, !failedCovers.contains(url) else { return }
        loading[url] = Task { @MainActor [weak self] in
            let loaded = await Artwork.load(url)
            self?.finishedLoading(url, loaded)
        }
    }

    private func finishedLoading(_ url: URL, _ loaded: Artwork.Loaded?) {
        loading[url] = nil
        Log.player.notice("cover \(loaded == nil ? "failed" : "loaded")\(url == coverURL ? "" : " (for an earlier track)")")
        if let loaded {
            covers[url] = loaded
            coverOrder.removeAll { $0 == url }
            coverOrder.append(url)
            while coverOrder.count > 16 { covers[coverOrder.removeFirst()] = nil }
        } else {
            failedCovers.insert(url)
        }
        // Rebuild the snapshot; it picks the cover up only if it belongs to the current track.
        if url == coverURL { publish(snapshot.playback, style: snapshot.style) }
    }

    /// Reloads the widget if what it last received differs visibly from the current snapshot.
    /// One pending check at a time; a later call can only bring it forward.
    private func syncWidget(after delay: TimeInterval) {
        let due = Date().addingTimeInterval(delay)
        if let pendingDue = pendingReloadDue, pendingDue <= due, pendingReload != nil { return }
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReload = nil
            self.pendingReloadDue = nil
            if Date() < self.suppressedUntil {
                // Right after a widget button WidgetKit reloads by itself; check again after that.
                self.syncWidget(after: self.suppressedUntil.timeIntervalSinceNow + 0.3)
                return
            }
            if let served = self.lastServed, !self.needsReload(from: served, to: self.snapshot) { return }
            Log.player.notice("reload widgets")
            WidgetCenter.shared.reloadAllTimelines()
            self.watchReload()
        }
        pendingReload = work
        pendingReloadDue = due
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    private var pendingReloadDue: Date?

    /// Sometimes the widget extension stops answering reload requests (its process hangs),
    /// and the widget freezes until it is restarted. If a reload brings no request for a
    /// snapshot within a few seconds, end the extension's process: the system starts a fresh
    /// one, and the reload is asked for again. At most once every two minutes.
    private func watchReload() {
        let requested = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.lastConnection < requested,
                  Date().timeIntervalSince(self.lastRevival) > 120 else { return }
            self.lastRevival = Date()
            Log.player.notice("widget did not answer the reload, restarting the extension")
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-x", "TrackPinWidget"]
            try? kill.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    /// Holds back reloads for `seconds`. A reload already scheduled is kept: when it runs, it
    /// waits for the end of the hold and reloads only if the widget has not seen the change.
    private func suppressReloads(for seconds: TimeInterval) {
        suppressedUntil = Date().addingTimeInterval(seconds)
    }

    /// Reloads right away, for an explicit request such as the "Update widgets" button.
    /// Shows `data` as the current cover, for screenshots of the demo track.
    func usePreviewCover(_ data: Data) {
        coverImage = NSImage(data: data)
        blurredCover = Artwork.blurred(data)
        var palette: ArtworkPalette?
        if let image = coverImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            palette = Artwork.palette(of: image)
        }
        snapshot.cover = data
        snapshot.palette = palette
        displayPalette = palette
        encoded = nil
    }

    func reloadWidgets() {
        Log.player.notice("reload widgets (explicit)")
        defer { watchReload() }
        pendingReload?.cancel()
        pendingReload = nil
        pendingReloadDue = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Reload only when something visible changed. A playing track advances on its own
    /// in the widget, so a regular position update does not need a reload.
    private func needsReload(from old: WidgetSnapshot, to new: WidgetSnapshot) -> Bool {
        guard old.hostReachable, old.style == new.style, old.cover == new.cover, old.palette == new.palette,
              old.source == new.source else { return true }
        if let before = old.playback.currentTrack, let after = new.playback.currentTrack {
            let elapsed = before.playing ? new.sampledAt.timeIntervalSince(old.sampledAt) : 0
            return before.id != after.id || before.playing != after.playing || before.title != after.title
                || (new.style.showVolume && before.volume != after.volume)
                || abs(min(before.duration, before.position + elapsed) - after.position) > 3
        }
        return old.playback != new.playback
    }
}
