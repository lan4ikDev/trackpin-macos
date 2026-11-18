import Foundation
import Network

enum WidgetTransport {
    static let kind = "TrackPinSpotify"
    static let address = NWEndpoint.Host("127.0.0.1")
    static let port = NWEndpoint.Port(rawValue: TrackPinBuild.port)!
    static let request = Data(("NEEDLE " + TrackPinBuild.token + "\n").utf8)
    static let maximumResponse = 256 * 1024

    static func requestSnapshot(completion: @escaping (WidgetSnapshot?) -> Void) {
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
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, eof, error in
                if let data { buffer.append(data) }
                guard error == nil, buffer.count <= maximumResponse else { finish(nil); return }
                if eof { finish(try? JSONDecoder().decode(WidgetSnapshot.self, from: buffer)) }
                else if !finished { receive() }
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { error in
                    if error == nil { receive() } else { finish(nil) }
                })
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 1) { finish(nil) }
    }
}
