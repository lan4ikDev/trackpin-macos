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
    /// The encoded snapshot, built lazily when the widget asks: the app reads Spotify far more
    /// often than the widget reloads, and the snapshot carries the cover.
    private var encoded: Data?
    private var coverURL: URL?
    private var cover: Data?
    private var palette: ArtworkPalette?
    private var artworkTask: Task<Void, Never>?

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

    deinit { listener?.cancel(); artworkTask?.cancel() }

    // MARK: Server

    private func serve(_ connection: NWConnection) {
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
                guard let onCommand = self.onCommand else { self.reply(on: connection); return }
                onCommand(action, step) { [weak self] in self?.reply(on: connection) }
            }
        }
    }

    private func reply(on connection: NWConnection) {
        if encoded == nil { encoded = try? JSONEncoder().encode(snapshot) }
        guard let response = encoded else { connection.cancel(); return }
        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { error in
            if error != nil { connection.cancel() }
        })
    }

    // MARK: Publishing

    func publish(_ playback: Playback, style: WidgetStyle) {
        let url = playback.currentTrack?.artwork
        if coverURL != url {
            artworkTask?.cancel()
            coverURL = url
            cover = nil
            palette = nil
            coverImage = nil
            blurredCover = nil
            if let url {
                artworkTask = Task { @MainActor [weak self] in
                    let artwork = await Artwork.load(url)
                    guard !Task.isCancelled, let self, self.coverURL == url else { return }
                    self.cover = artwork?.data
                    self.palette = artwork?.palette
                    self.coverImage = artwork.flatMap { NSImage(data: $0.data) }
                    self.blurredCover = artwork.flatMap { Artwork.blurred($0.data) }
                    self.publish(self.snapshot.playback, style: self.snapshot.style)
                }
            }
        }

        let next = WidgetSnapshot(playback: playback, sampledAt: Date(), cover: cover, palette: palette, style: style)
        encoded = nil
        let reload = needsReload(from: snapshot, to: next)
        snapshot = next
        if reload { reloadWidgets() }
    }

    func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Reload only when something visible changed. A playing track advances on its own
    /// in the widget, so a regular position update does not need a reload.
    private func needsReload(from old: WidgetSnapshot, to new: WidgetSnapshot) -> Bool {
        guard old.hostReachable, old.style == new.style, old.cover == new.cover, old.palette == new.palette else { return true }
        if let before = old.playback.currentTrack, let after = new.playback.currentTrack {
            let elapsed = before.playing ? new.sampledAt.timeIntervalSince(old.sampledAt) : 0
            return before.id != after.id || before.playing != after.playing || before.title != after.title
                || abs(min(before.duration, before.position + elapsed) - after.position) > 3
        }
        return old.playback != new.playback
    }
}
