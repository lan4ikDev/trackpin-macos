import AppKit
import ImageIO
import Network
import UniformTypeIdentifiers
import WidgetKit

final class WidgetPublisher {
    private var listener: NWListener?
    private var response: Data?
    private var lastSnapshot: WidgetSnapshot?
    private var coverURL: URL?
    private var cover: Data?
    private var artworkTask: Task<Void, Never>?

    init() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: WidgetTransport.address, port: WidgetTransport.port)
        listener = try? NWListener(using: params)
        listener?.newConnectionHandler = { [weak self] in self?.serve($0) }
        listener?.stateUpdateHandler = { state in
            if case .ready = state { WidgetCenter.shared.reloadTimelines(ofKind: WidgetTransport.kind) }
            if case let .failed(error) = state { NSLog("TrackPin widget listener: %@", error.localizedDescription) }
        }
        listener?.start(queue: .main)
    }

    deinit { listener?.cancel(); artworkTask?.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        let length = WidgetTransport.request.count
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] bytes, _, _, _ in
            guard bytes == WidgetTransport.request, let response = self?.response else {
                connection.cancel()
                return
            }
            connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { error in
                if error != nil { connection.cancel() }
            })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { connection.cancel() }
    }

    func publish(_ playback: Playback, theme: WidgetTheme, showTime: Bool) {
        var url: URL?
        if case let .track(track) = playback { url = track.artwork }
        if coverURL != url {
            artworkTask?.cancel()
            coverURL = url
            cover = nil
            if let url {
                artworkTask = Task { @MainActor [weak self] in
                    let image = await Self.loadArtwork(url)
                    guard !Task.isCancelled, let self, self.coverURL == url,
                          let previous = self.lastSnapshot else { return }
                    self.cover = image
                    self.publish(previous.playback, theme: previous.theme, showTime: previous.showTime)
                }
            }
        }

        let snapshot = WidgetSnapshot(playback: playback, sampledAt: Date(), cover: cover, theme: theme, showTime: showTime)
        response = try? JSONEncoder().encode(snapshot)
        if needsReload(from: lastSnapshot, to: snapshot) {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetTransport.kind)
        }
        lastSnapshot = snapshot
    }

    private func needsReload(from old: WidgetSnapshot?, to new: WidgetSnapshot) -> Bool {
        guard let old, old.theme == new.theme, old.showTime == new.showTime, old.cover == new.cover else { return true }
        if case let .track(before) = old.playback, case let .track(after) = new.playback {
            let elapsed = before.playing ? new.sampledAt.timeIntervalSince(old.sampledAt) : 0
            return before.id != after.id || before.playing != after.playing
                || abs(min(before.duration, before.position + elapsed) - after.position) > 3
        }
        return old.playback != new.playback
    }

    private static func loadArtwork(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320
              ] as CFDictionary) else { return nil }
        let dataOut = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(dataOut, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? dataOut as Data : nil
    }
}
