import Foundation
import Network

enum MeshTransportError: LocalizedError {
    case invalidEndpoint
    case connection(String)
    case emptyResponse
    case oversizedResponse
    case broker(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a valid Tailscale host and port."
        case .connection(let message): "Mesh connection failed: \(message)"
        case .emptyResponse: "The Mesh broker closed without a response."
        case .oversizedResponse: "The Mesh response exceeded 4 MiB."
        case .broker(let message): message
        }
    }
}

actor MeshTCPClient {
    func send(_ request: MeshRequest, host: String, port: UInt16) async throws -> MeshResponse {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MeshTransportError.invalidEndpoint
        }
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        let exchange = MeshExchange(
            connection: NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp),
            payload: payload
        )
        let response = try await exchange.run()
        guard response.ok else { throw MeshTransportError.broker(response.error ?? "Mesh request failed.") }
        return response
    }
}

private final class MeshExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let payload: Data
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<MeshResponse, any Error>?
    private var finished = false

    init(connection: NWConnection, payload: Data) {
        self.connection = connection
        self.payload = payload
    }

    func run() async throws -> MeshResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.writeRequest()
                    case .failed(let error): self.finish(.failure(MeshTransportError.connection(error.localizedDescription)))
                    case .cancelled: self.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: DispatchQueue(label: "me.pai.pharos.mobile.mesh"))
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func writeRequest() {
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(MeshTransportError.connection(error.localizedDescription)))
            } else {
                self.readNext()
            }
        })
    }

    private func readNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if self.buffer.count > 4 * 1024 * 1024 {
                self.finish(.failure(MeshTransportError.oversizedResponse)); return
            }
            if let newline = self.buffer.firstIndex(of: 0x0A) {
                let frame = self.buffer.prefix(upTo: newline)
                do { self.finish(.success(try JSONDecoder().decode(MeshResponse.self, from: frame))) }
                catch { self.finish(.failure(error)) }
            } else if let error {
                self.finish(.failure(MeshTransportError.connection(error.localizedDescription)))
            } else if complete {
                self.finish(.failure(MeshTransportError.emptyResponse))
            } else {
                self.readNext()
            }
        }
    }

    private func finish(_ result: Result<MeshResponse, any Error>) {
        let callback = lock.withLock { () -> CheckedContinuation<MeshResponse, any Error>? in
            guard !finished else { return nil }
            finished = true
            let callback = continuation
            continuation = nil
            return callback
        }
        connection.cancel()
        callback?.resume(with: result)
    }
}

