import Foundation
import PharosClientKit

/// Older DSH Hosts allow one WebSocket per peer; multiplex logical streams on it.
actor DshRemoteMux {
    private let socket: URLSessionWebSocketTask
    private var reader: Task<Void, Never>?
    private var streams: [String: AsyncStream<BackendWireEvent>.Continuation] = [:]
    private var closed = false

    init(port: Int, cookie: String) throws {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/api/remote.mux") else {
            throw PharosClientError.operationFailed("Invalid remote DSH stream URL")
        }
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
    }

    deinit { reader?.cancel(); socket.cancel(with: .normalClosure, reason: nil) }

    func isClosed() -> Bool { closed }

    func open(endpoint: String, requestData: Data) async throws -> AsyncStream<BackendWireEvent> {
        guard !closed else { throw PharosClientError.backendUnreachable(backend: "dsh", reason: "Remote event connection closed") }
        if reader == nil {
            let socket = socket
            reader = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        await self?.receive(message)
                    }
                } catch { }
                await self?.finish()
            }
        }
        let id = UUID().uuidString.lowercased()
        let (stream, continuation) = AsyncStream<BackendWireEvent>.makeStream()
        streams[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.cancel(id: id) } }
        guard let payload = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            streams.removeValue(forKey: id)
            throw PharosClientError.operationFailed("Invalid DSH stream request")
        }
        let frame: [String: Any] = ["type": "open", "streamId": id, "endpoint": endpoint, "payload": payload]
        do {
            let data = try JSONSerialization.data(withJSONObject: frame)
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            streams.removeValue(forKey: id)?.finish()
            throw error
        }
        return stream
    }

    private func receive(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let value): data = value
        @unknown default: return
        }
        guard let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = frame["streamId"] as? String, let type = frame["type"] as? String else { return }
        if type == "item", let value = frame["value"] as? [String: Any] {
            streams[id]?.yield(BackendWireEvent(value))
        } else if type == "end" || type == "error" {
            streams.removeValue(forKey: id)?.finish()
        }
    }

    private func cancel(id: String) async {
        guard streams.removeValue(forKey: id) != nil, !closed else { return }
        if let data = try? JSONSerialization.data(withJSONObject: ["type": "cancel", "streamId": id]) {
            try? await socket.send(.string(String(decoding: data, as: UTF8.self)))
        }
    }

    private func finish() {
        closed = true
        let current = streams.values
        streams.removeAll()
        current.forEach { $0.finish() }
    }
}
