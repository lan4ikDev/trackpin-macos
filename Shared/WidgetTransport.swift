import Foundation
import Network

/// Loopback protocol between the widget extension (client) and the TrackPin app (server).
///
/// The widget is sandboxed and has no App Group, so it cannot read the app's files.
/// Instead it opens a TCP connection to 127.0.0.1, sends one line and reads a JSON
/// encoded `WidgetSnapshot` until the server closes the connection. The token is
/// generated per checkout by `scripts/configure.sh`, so other local processes
/// cannot drive Spotify through this port by accident.
enum WidgetTransport {
    static let kind = "TrackPinSpotify"
    static let coverKind = "TrackPinCover"
    static let address = NWEndpoint.Host("127.0.0.1")
    static let port = NWEndpoint.Port(rawValue: TrackPinBuild.port)!
    static let maximumRequest = 256
    static let maximumResponse = 1 << 20

    enum Request: Equatable {
        case snapshot
        case command(PlayerAction, step: Int)

        var line: String {
            switch self {
            case .snapshot: "NEEDLE \(TrackPinBuild.token) GET\n"
            case let .command(action, step): "NEEDLE \(TrackPinBuild.token) DO \(action.rawValue) \(step)\n"
            }
        }

        /// Parses a request line received by the server. Returns nil for a wrong token or malformed input.
        init?(line: String) {
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
            guard parts.count >= 3, parts[0] == "NEEDLE", parts[1] == TrackPinBuild.token else { return nil }
            switch parts[2] {
            case "GET" where parts.count == 3:
                self = .snapshot
            case "DO" where parts.count == 5:
                guard let action = PlayerAction(rawValue: parts[3]), let step = Int(parts[4]),
                      (1...120).contains(step) else { return nil }
                self = .command(action, step: step)
            default:
                return nil
            }
        }

        var timeout: Double {
            if case .snapshot = self { return 1.5 }
            return 6 // AppleScript may take a few seconds when the player is busy.
        }
    }

    static func send(_ request: Request) async -> WidgetSnapshot? {
        await withCheckedContinuation { continuation in
            send(request) { continuation.resume(returning: $0) }
        }
    }

    static func send(_ request: Request, completion: @escaping (WidgetSnapshot?) -> Void) {
        let queue = DispatchQueue(label: "dev.lan4ik.needle.widget.request")
        let connection = NWConnection(host: address, port: port, using: .tcp)
        var buffer = Data()
        var finished = false

        func finish(_ response: WidgetSnapshot?) {
            guard !finished else { return }
            finished = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(response)
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, eof, error in
                if let data { buffer.append(data) }
                guard error == nil, buffer.count <= maximumResponse else { finish(nil); return }
                if eof { finish(try? JSONDecoder().decode(WidgetSnapshot.self, from: buffer)) }
                else if !finished { receive() }
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(request.line.utf8), completion: .contentProcessed { error in
                    if error == nil { receive() } else { finish(nil) }
                })
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + request.timeout) { finish(nil) }
    }
}
