import Foundation
import Network
import CryptoKit
import PharosMeshProtocol

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
    func send(_ request: MeshRequest, host: String, port: UInt16,
              preference: MeshTransportPreference = .legacy) async throws -> MeshResponse {
        let response = try await exchange(request, host: host, port: port,
                                          timeout: request.cmd == "events" ? 35 : 5,
                                          preference: preference)
        guard response.ok else { throw MeshTransportError.broker(response.error ?? "Mesh request failed.") }
        return response
    }

    func uploadAttachment(data: Data, name: String, mimeType: String,
                          host: String, port: UInt16,
                          preference: MeshTransportPreference = .legacy) async throws -> MeshAttachment {
        guard !data.isEmpty, data.count <= DistributedMeshProtocol.maximumBlobBytes else {
            throw MeshTransportError.broker("Attachments must be between 1 byte and 25 MiB.")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let attachment = MeshAttachment(id: UUID().uuidString, name: name, mimeType: mimeType,
                                        byteSize: data.count, sha256: digest)
        var request = MeshRequest(cmd: "attachment-put")
        request.attachment = attachment
        let response = try await exchange(request, body: data, host: host, port: port,
                                          preference: preference)
        guard response.ok, let stored = response.attachment else {
            throw MeshTransportError.broker(response.error ?? "Attachment upload failed.")
        }
        return stored
    }

    func downloadAttachment(id: String, host: String, port: UInt16,
                            preference: MeshTransportPreference = .legacy) async throws -> (MeshAttachment, Data) {
        let request = MeshRequest(cmd: "attachment-get", attachmentID: id)
        let transport = try makeTransport(host: host, port: port, preference: preference)
        let frame = try await transport.exchange(.init(header: JSONEncoder().encode(request)))
        let response = try JSONDecoder().decode(MeshResponse.self, from: frame.header)
        guard response.ok, let attachment = response.attachment, let body = frame.body else {
            throw MeshTransportError.broker(response.error ?? "Attachment download failed.")
        }
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        guard digest == attachment.sha256.lowercased() else {
            throw MeshTransportError.broker("Attachment checksum mismatch.")
        }
        return (attachment, body)
    }

    private func exchange(_ request: MeshRequest, body: Data? = nil,
                          host: String, port: UInt16, timeout: TimeInterval = 5,
                          preference: MeshTransportPreference = .legacy) async throws -> MeshResponse {
        let transport = try makeTransport(host: host, port: port, timeout: timeout,
                                          preference: preference)
        let result = try await transport.exchange(.init(header: JSONEncoder().encode(request), body: body,
                                                        timeoutMilliseconds: Int(timeout * 1_000)))
        return try JSONDecoder().decode(MeshResponse.self, from: result.header)
    }

    private func makeTransport(host: String, port: UInt16,
                               timeout: TimeInterval = 5,
                               preference: MeshTransportPreference = .legacy) throws -> NetworkLegacyMeshTransport {
        _ = try preference.resolved(irohAvailable: false)
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let value = NWEndpoint.Port(rawValue: port) else { throw MeshTransportError.invalidEndpoint }
        return NetworkLegacyMeshTransport(host: NWEndpoint.Host(host), port: value, timeout: timeout)
    }
}

private struct NetworkLegacyMeshTransport: MeshTransport, Sendable {
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port
    let timeout: TimeInterval

    var path: MeshTransportPath { get async { .legacyTCP } }

    func exchange(_ request: MeshTransportRequest) async throws -> MeshTransportResponse {
        try request.validate()
        var payload = request.header
        payload.append(0x0A)
        if let body = request.body { payload.append(body) }
        let connection = NWConnection(host: host, port: port, using: .tcp)

        if (try? JSONDecoder().decode(MeshRequest.self, from: request.header).cmd) == "attachment-get" {
            let result = try await MeshDownloadExchange(connection: connection, payload: payload).run()
            return MeshTransportResponse(
                header: try JSONEncoder().encode(MeshResponse(ok: true, attachment: result.0)),
                body: result.1
            )
        }

        let response = try await MeshExchange(connection: connection, payload: payload,
                                              timeout: timeout).run()
        return MeshTransportResponse(header: try JSONEncoder().encode(response))
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
            if self.buffer.count > DistributedMeshProtocol.maximumHeaderBytes {
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
                    guard attachment.byteSize <= DistributedMeshProtocol.maximumBlobBytes else {
                        throw MeshTransportError.oversizedResponse
                    }
                    self.attachment = attachment
                } catch {
                    self.finish(.failure(error)); return
                }
            }

            if let attachment = self.attachment, self.buffer.count >= attachment.byteSize {
                self.finish(.success((attachment, Data(self.buffer.prefix(attachment.byteSize)))))
            } else if self.attachment == nil,
                      self.buffer.count > DistributedMeshProtocol.maximumHeaderBytes {
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
