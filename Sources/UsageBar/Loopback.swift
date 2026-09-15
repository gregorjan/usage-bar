import Foundation
import Network

actor Loopback {
    private var listener: NWListener?

    func waitForCode(port: UInt16, path: String) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
                self.listener = listener
                listener.newConnectionHandler = { connection in
                    connection.start(queue: .main)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                        guard let data, let request = String(data: data, encoding: .utf8),
                              let line = request.split(separator: "\r\n").first,
                              let target = line.split(separator: " ").dropFirst().first
                        else { return }
                        let body = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<html><body style=\"font:16px -apple-system;padding:3rem\">You can close this tab and go back to UsageBar.</body></html>"
                        connection.send(content: Data(body.utf8), completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                        guard !finished,
                              let components = URLComponents(string: "http://127.0.0.1\(target)"),
                              components.path == path else { return }
                        finished = true
                        listener.cancel()
                        var result: [String: String] = [:]
                        components.queryItems?.forEach { result[$0.name] = $0.value }
                        continuation.resume(returning: result)
                    }
                }
                listener.start(queue: .main)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
