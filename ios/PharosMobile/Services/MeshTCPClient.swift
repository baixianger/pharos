import Foundation
import Network
import CryptoKit

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
    /// Submit one capability-gated Agent Runtime request through the durable
    /// Broker -> Host Node command route. The phone never dials a Host UDS or
    /// vendor App Server directly.
    func agentRuntimeRPC(_ jsonRPC: String, nodeID: String, profile: MeshProfile,
                         timeout: Duration = .seconds(15)) async throws -> String {
        var enqueue = MeshRequest(cmd: "node-command-enqueue")
        enqueue.nodeID = nodeID
        enqueue.action = "agentRPC"
        enqueue.payload = jsonRPC
        enqueue.idempotencyKey = "mobile-agent-rpc:\(UUID().uuidString)"
        enqueue.deadline = Date().timeIntervalSince1970 + 60
        enqueue.maxAttempts = 1
        enqueue.authToken = profile.controlToken
        let accepted = try await send(enqueue, host: profile.host, port: profile.port)
        guard let commandID = accepted.command?.id else {
            throw MeshTransportError.broker("Broker did not return an Agent Runtime command ID.")
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            var status = MeshRequest(cmd: "node-command-list")
            status.nodeID = nodeID
            status.authToken = profile.controlToken
            let response = try await send(status, host: profile.host, port: profile.port)
            if let command = response.commands?.first(where: { $0.id == commandID }) {
                switch command.state {
                case "succeeded":
                    guard let result = command.result else {
                        throw MeshTransportError.broker("Agent Runtime returned no result.")
                    }
                    return result
                case "failed", "expired", "canceled":
                    throw MeshTransportError.broker(command.result ?? "Agent Runtime command \(command.state).")
                default:
                    break
                }
            }
            try await clock.sleep(for: .milliseconds(250))
        }
        throw MeshTransportError.connection("Agent Runtime command timed out.")
    }

    func send(_ request: MeshRequest, host: String, port: UInt16) async throws -> MeshResponse {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MeshTransportError.invalidEndpoint
        }
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        let exchange = MeshExchange(
            connection: NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp),
            payload: payload,
            timeout: request.cmd == "events" ? 35 : 5
        )
        let response = try await exchange.run()
        guard response.ok else { throw MeshTransportError.broker(response.error ?? "Mesh request failed.") }
        return response
    }

    func uploadAttachment(data: Data, name: String, mimeType: String,
                          host: String, port: UInt16) async throws -> MeshAttachment {
        guard !data.isEmpty, data.count <= 25 * 1024 * 1024 else {
            throw MeshTransportError.broker("Attachments must be between 1 byte and 25 MiB.")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let attachment = MeshAttachment(id: UUID().uuidString, name: name, mimeType: mimeType,
                                        byteSize: data.count, sha256: digest)
        var request = MeshRequest(cmd: "attachment-put")
        request.attachment = attachment
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        payload.append(data)
        let exchange = MeshExchange(
            connection: NWConnection(host: NWEndpoint.Host(host),
                                     port: try validatedPort(host: host, port: port), using: .tcp),
            payload: payload
        )
        let response = try await exchange.run()
        guard response.ok, let stored = response.attachment else {
            throw MeshTransportError.broker(response.error ?? "Attachment upload failed.")
        }
        return stored
    }

    func downloadAttachment(id: String, host: String, port: UInt16) async throws -> (MeshAttachment, Data) {
        var request = MeshRequest(cmd: "attachment-get")
        request.attachmentID = id
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        let exchange = MeshDownloadExchange(
            connection: NWConnection(host: NWEndpoint.Host(host),
                                     port: try validatedPort(host: host, port: port), using: .tcp),
            payload: payload
        )
        let result = try await exchange.run()
        let digest = SHA256.hash(data: result.1).map { String(format: "%02x", $0) }.joined()
        guard digest == result.0.sha256.lowercased() else {
            throw MeshTransportError.broker("Attachment checksum mismatch.")
        }
        return result
    }

    private func validatedPort(host: String, port: UInt16) throws -> NWEndpoint.Port {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let value = NWEndpoint.Port(rawValue: port) else { throw MeshTransportError.invalidEndpoint }
        return value
    }
}

private final class MeshExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let payload: Data
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<MeshResponse, any Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var finished = false
    private let timeout: TimeInterval

    init(connection: NWConnection, payload: Data, timeout: TimeInterval = 5) {
        self.connection = connection
        self.payload = payload
        self.timeout = timeout
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
                let queue = DispatchQueue(label: "me.pai.pharos.mobile.mesh")
                let timeout = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(MeshTransportError.connection("The Broker did not respond in time.")))
                }
                lock.withLock { timeoutWorkItem = timeout }
                queue.asyncAfter(deadline: .now() + self.timeout, execute: timeout)
                connection.start(queue: queue)
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
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            let callback = continuation
            continuation = nil
            return callback
        }
        connection.cancel()
        callback?.resume(with: result)
    }
}

private final class MeshDownloadExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let payload: Data
    private let lock = NSLock()
    private var buffer = Data()
    private var attachment: MeshAttachment?
    private var continuation: CheckedContinuation<(MeshAttachment, Data), any Error>?
    private var finished = false

    init(connection: NWConnection, payload: Data) {
        self.connection = connection
        self.payload = payload
    }

    func run() async throws -> (MeshAttachment, Data) {
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
                connection.start(queue: DispatchQueue(label: "me.pai.pharos.mobile.mesh-download"))
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func writeRequest() {
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { self.finish(.failure(MeshTransportError.connection(error.localizedDescription))) }
            else { self.readNext() }
        })
    }

    private func readNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }

            if self.attachment == nil, let newline = self.buffer.firstIndex(of: 0x0A) {
                let header = self.buffer.prefix(upTo: newline)
                self.buffer.removeSubrange(...newline)
                do {
                    let response = try JSONDecoder().decode(MeshResponse.self, from: header)
                    guard response.ok, let attachment = response.attachment else {
                        throw MeshTransportError.broker(response.error ?? "Attachment download failed.")
                    }
                    guard attachment.byteSize <= 25 * 1024 * 1024 else { throw MeshTransportError.oversizedResponse }
                    self.attachment = attachment
                } catch {
                    self.finish(.failure(error)); return
                }
            }

            if let attachment = self.attachment, self.buffer.count >= attachment.byteSize {
                self.finish(.success((attachment, Data(self.buffer.prefix(attachment.byteSize)))))
            } else if self.attachment == nil, self.buffer.count > 4 * 1024 * 1024 {
                self.finish(.failure(MeshTransportError.oversizedResponse))
            } else if let error {
                self.finish(.failure(MeshTransportError.connection(error.localizedDescription)))
            } else if complete {
                self.finish(.failure(MeshTransportError.emptyResponse))
            } else {
                self.readNext()
            }
        }
    }

    private func finish(_ result: Result<(MeshAttachment, Data), any Error>) {
        let callback = lock.withLock { () -> CheckedContinuation<(MeshAttachment, Data), any Error>? in
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
