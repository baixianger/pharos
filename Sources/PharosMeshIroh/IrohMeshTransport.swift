import Foundation
import PharosMeshProtocol

#if canImport(IrohLib)
import IrohLib
#endif

public enum MeshIrohRelayPolicy: Sendable {
    case production
    case disabled
}

/// An opaque, serializable Iroh address. The ticket can contain transient
/// routing hints, but callers must use `endpointID` as peer identity.
public struct MeshIrohEndpointAddress: Equatable, Sendable {
    public var endpointID: MeshEndpointID
    public var ticket: String

    public init(endpointID: MeshEndpointID, ticket: String) {
        self.endpointID = endpointID
        self.ticket = ticket
    }
}

public enum MeshIrohError: Error, Equatable, Sendable {
    case unavailableOnPlatform
    case invalidSecretKey
    case invalidEndpointID
    case invalidAddressTicket
    case endpointIdentityMismatch
    case wrongFrameKind
    case timeout
}

public typealias MeshIrohRequestHandler = @Sendable (
    _ request: MeshTransportRequest,
    _ remoteEndpointID: MeshEndpointID
) async throws -> MeshTransportResponse

public enum MeshIrohAvailability {
    public static var isAvailable: Bool {
#if canImport(IrohLib)
        true
#else
        false
#endif
    }
}

/// Owns one Iroh endpoint and multiplexes short request streams over cached
/// peer connections. It never reads legacy Broker configuration or data paths.
public actor IrohEndpointRuntime {
#if canImport(IrohLib)
    private struct PeerConnection {
        let connection: Connection
        let initiatedLocally: Bool
    }

    private let endpoint: Endpoint
    private let includesRoutingHints: Bool
    private let waitsForRelay: Bool
    private let configuredEndpointID: MeshEndpointID?
    private var connections: [MeshEndpointID: PeerConnection] = [:]
    private var isServing = false
    private var streamServingTasks: [MeshEndpointID: Task<Void, Never>] = [:]
    private var streamServingGenerations: [MeshEndpointID: UUID] = [:]
    private var requestHandler: MeshIrohRequestHandler?

    private init(
        endpoint: Endpoint, includesRoutingHints: Bool,
        configuredEndpointID: MeshEndpointID?, waitsForRelay: Bool
    ) {
        self.endpoint = endpoint
        self.includesRoutingHints = includesRoutingHints
        self.configuredEndpointID = configuredEndpointID
        self.waitsForRelay = waitsForRelay
    }
#else
    private init() {}
#endif

    public static func bind(
        secretKey: Data? = nil,
        expectedEndpointID: MeshEndpointID? = nil,
        relayPolicy: MeshIrohRelayPolicy = .production,
        bindAddress: String? = nil
    ) async throws -> IrohEndpointRuntime {
#if canImport(IrohLib)
        if let secretKey, secretKey.count != 32 { throw MeshIrohError.invalidSecretKey }
        let preset = switch relayPolicy {
        case .production: presetN0()
        case .disabled: presetMinimal()
        }
        let relayMode = switch relayPolicy {
        case .production: RelayMode.defaultMode()
        case .disabled: RelayMode.disabled()
        }
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: preset,
            bindAddr: bindAddress,
            secretKey: secretKey,
            alpns: [Data(DistributedMeshProtocol.alpn.utf8)],
            relayMode: relayMode
        ))
        let includesRoutingHints = true
        let waitsForRelay = switch relayPolicy {
        case .production: true
        case .disabled: false
        }
        return IrohEndpointRuntime(
            endpoint: endpoint, includesRoutingHints: includesRoutingHints,
            configuredEndpointID: expectedEndpointID,
            waitsForRelay: waitsForRelay
        )
#else
        throw MeshIrohError.unavailableOnPlatform
#endif
    }

    public func localAddress() throws -> MeshIrohEndpointAddress {
#if canImport(IrohLib)
        let address = endpoint.addr()
        let id: MeshEndpointID
        if let configuredEndpointID {
            id = configuredEndpointID
        } else {
            guard let derived = MeshEndpointID(
                rawValue: stableEndpointID(address.id())
            ) else { throw MeshIrohError.invalidEndpointID }
            id = derived
        }
        let ticket = try encodeAddressTicket(
            endpointID: id.rawValue,
            relayURL: includesRoutingHints ? address.relayUrl() : nil,
            directAddresses: includesRoutingHints ? address.directAddresses() : []
        )
        return MeshIrohEndpointAddress(endpointID: id, ticket: ticket)
#else
        throw MeshIrohError.unavailableOnPlatform
#endif
    }

    public func secretKeyBytes() throws -> Data {
#if canImport(IrohLib)
        endpoint.secretKey().toBytes()
#else
        throw MeshIrohError.unavailableOnPlatform
#endif
    }

    public func waitUntilOnline() async {
#if canImport(IrohLib)
        if waitsForRelay { await endpoint.online() }
#endif
    }

    /// Starts accepting the Pharos ALPN. Calling this twice updates the handler
    /// without spawning a second accept loop; closing the endpoint ends the loop.
    public func startServing(_ handler: @escaping MeshIrohRequestHandler) {
#if canImport(IrohLib)
        requestHandler = handler
        for task in streamServingTasks.values { task.cancel() }
        streamServingTasks.removeAll()
        streamServingGenerations.removeAll()
        for (remoteID, peer) in connections
        where peer.connection.closeReason() == nil {
            beginServingStreams(on: peer.connection, remoteID: remoteID)
        }
        guard !isServing else { return }
        isServing = true
        Task { [weak self] in
            await self?.acceptLoop()
        }
#endif
    }

    public func exchange(
        _ request: MeshTransportRequest,
        with remote: MeshIrohEndpointAddress
    ) async throws -> MeshTransportResponse {
#if canImport(IrohLib)
        try request.validate()
        let connection = try await connection(to: remote)
        let stream = try await connection.openBi()
        let payload = try MeshStreamFrameCodec.encode(MeshStreamFrame(
            kind: .request, header: request.header, body: request.body
        ))
        try await stream.send().writeAll(buf: payload)
        try await stream.send().finish()
        let responseData = try await stream.recv().readToEnd(
            sizeLimit: UInt32(MeshStreamFrameCodec.maximumFrameBytes)
        )
        let frame = try MeshStreamFrameCodec.decode(responseData)
        guard frame.kind == .response else { throw MeshIrohError.wrongFrameKind }
        let response = MeshTransportResponse(header: frame.header, body: frame.body)
        try response.validate()
        return response
#else
        throw MeshIrohError.unavailableOnPlatform
#endif
    }

    public func path(to remote: MeshEndpointID) -> MeshTransportPath {
#if canImport(IrohLib)
        guard let peer = connections[remote],
              peer.connection.closeReason() == nil else {
            return .unavailable
        }
        let selected = peer.connection.paths().first(where: \.isSelected)
        if selected?.isRelay == true { return .irohRelay }
        if selected?.isIp == true { return .irohDirect }
        return .unavailable
#else
        return .unavailable
#endif
    }

    public func close() async throws {
#if canImport(IrohLib)
        requestHandler = nil
        for task in streamServingTasks.values { task.cancel() }
        streamServingTasks.removeAll()
        streamServingGenerations.removeAll()
        connections.removeAll()
        try await endpoint.close()
        isServing = false
#endif
    }

#if canImport(IrohLib)
    private func connection(to remote: MeshIrohEndpointAddress) async throws -> Connection {
        if let existing = connections[remote.endpointID],
           existing.connection.closeReason() == nil {
            beginServingStreams(on: existing.connection, remoteID: remote.endpointID)
            return existing.connection
        }
        let address = try decodeAddressTicket(remote.ticket)
        let ticketID = stableEndpointID(address.id())
        guard ticketID == remote.endpointID.rawValue else {
            throw MeshIrohError.endpointIdentityMismatch
        }
        let connection = try await endpoint.connect(
            addr: address,
            alpn: Data(DistributedMeshProtocol.alpn.utf8)
        )
        guard stableEndpointID(connection.remoteId()) == remote.endpointID.rawValue else {
            try? connection.close(errorCode: 1, reason: Data("identity mismatch".utf8))
            throw MeshIrohError.endpointIdentityMismatch
        }
        return install(
            connection, remoteID: remote.endpointID, initiatedLocally: true
        )
    }

    private func acceptLoop() async {
        while !Task.isCancelled, let incoming = await endpoint.acceptNext() {
            Task { [weak self] in
                await self?.accept(incoming)
            }
        }
    }

    private func accept(_ incoming: Incoming) async {
        do {
            let accepting = try await incoming.accept()
            guard try await accepting.alpn() == Data(DistributedMeshProtocol.alpn.utf8) else {
                return
            }
            let connection = try await accepting.connect()
            guard let remoteID = MeshEndpointID(
                rawValue: stableEndpointID(connection.remoteId())
            ) else {
                try? connection.close(errorCode: 2, reason: Data("invalid endpoint id".utf8))
                return
            }
            _ = install(connection, remoteID: remoteID, initiatedLocally: false)
        } catch {
            // Connection-local failures end this peer loop. The endpoint accept
            // loop remains available for a clean reconnect.
        }
    }

    /// Simultaneous reconnects can create one QUIC connection in each
    /// direction. Both endpoints independently choose the same survivor: the
    /// lexicographically smaller Endpoint ID owns the dial direction.
    private func install(
        _ candidate: Connection,
        remoteID: MeshEndpointID,
        initiatedLocally: Bool
    ) -> Connection {
        let localID = stableEndpointID(endpoint.id())
        let prefersLocalDial = localID < remoteID.rawValue
        if let existing = connections[remoteID],
           existing.connection.closeReason() == nil {
            let existingIsPreferred = existing.initiatedLocally == prefersLocalDial
            let candidateIsPreferred = initiatedLocally == prefersLocalDial
            guard candidateIsPreferred && !existingIsPreferred else {
                try? candidate.close(
                    errorCode: 0, reason: Data("duplicate connection".utf8)
                )
                return existing.connection
            }
            try? existing.connection.close(
                errorCode: 0, reason: Data("superseded connection".utf8)
            )
        }
        connections[remoteID] = PeerConnection(
            connection: candidate, initiatedLocally: initiatedLocally
        )
        beginServingStreams(
            on: candidate, remoteID: remoteID, replacingExisting: true
        )
        return candidate
    }

    private func stableEndpointID(_ id: EndpointId) -> String {
        id.toBytes().map { String(format: "%02x", $0) }.joined()
    }

    private struct StoredEndpointAddress: Codable {
        let version: Int
        let endpointID: String
        let relayURL: String?
        let directAddresses: [String]
    }

    private func encodeAddressTicket(
        endpointID: String, relayURL: String?, directAddresses: [String]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(StoredEndpointAddress(
            version: 1, endpointID: endpointID,
            relayURL: relayURL, directAddresses: directAddresses.sorted()
        ))
        return "pharos-iroh-v1:" + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodeAddressTicket(_ ticket: String) throws -> EndpointAddr {
        let prefix = "pharos-iroh-v1:"
        if ticket.hasPrefix(prefix) {
            var encoded = String(ticket.dropFirst(prefix.count))
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let data = Data(base64Encoded: encoded),
                  let value = try? JSONDecoder().decode(
                    StoredEndpointAddress.self, from: data
                  ), value.version == 1,
                  let id = try? EndpointId.fromString(s: value.endpointID) else {
                throw MeshIrohError.invalidAddressTicket
            }
            return EndpointAddr(
                id: id, relayUrl: value.relayURL,
                addresses: value.directAddresses
            )
        }
        // Existing pairings remain readable during the transition. Every
        // authenticated RPC response replaces this legacy routing hint with
        // the sender's current versioned Pharos address ticket.
        return try EndpointTicket.fromString(str: ticket).endpointAddr()
    }

    private func beginServingStreams(
        on connection: Connection, remoteID: MeshEndpointID,
        replacingExisting: Bool = false
    ) {
        guard let handler = requestHandler else { return }
        if replacingExisting {
            streamServingTasks[remoteID]?.cancel()
            streamServingTasks[remoteID] = nil
            streamServingGenerations[remoteID] = nil
        }
        guard streamServingTasks[remoteID] == nil else { return }
        let generation = UUID()
        streamServingGenerations[remoteID] = generation
        streamServingTasks[remoteID] = Task { [weak self] in
            await self?.serveStreams(
                on: connection, remoteID: remoteID, handler: handler,
                generation: generation
            )
        }
    }

    private func serveStreams(
        on connection: Connection, remoteID: MeshEndpointID,
        handler: @escaping MeshIrohRequestHandler, generation: UUID
    ) async {
        do {
            while !Task.isCancelled, connection.closeReason() == nil {
                let stream = try await connection.acceptBi()
                try await serve(stream, remoteID: remoteID, handler: handler)
            }
        } catch {
            // A closed connection ends only its stream loop. A later dial or
            // incoming connection installs a new loop for the same endpoint.
        }
        if streamServingGenerations[remoteID] == generation {
            streamServingTasks[remoteID] = nil
            streamServingGenerations[remoteID] = nil
        }
    }

    private func serve(
        _ stream: BiStream,
        remoteID: MeshEndpointID,
        handler: @escaping MeshIrohRequestHandler
    ) async throws {
        let requestData = try await stream.recv().readToEnd(
            sizeLimit: UInt32(MeshStreamFrameCodec.maximumFrameBytes)
        )
        let frame = try MeshStreamFrameCodec.decode(requestData)
        guard frame.kind == .request else { throw MeshIrohError.wrongFrameKind }
        let request = MeshTransportRequest(header: frame.header, body: frame.body)
        try request.validate()
        let response = try await handler(request, remoteID)
        try response.validate()
        let responseData = try MeshStreamFrameCodec.encode(MeshStreamFrame(
            kind: .response, header: response.header, body: response.body
        ))
        try await stream.send().writeAll(buf: responseData)
        try await stream.send().finish()
    }
#endif
}

public struct IrohMeshTransport: MeshTransport, Sendable {
    private let runtime: IrohEndpointRuntime
    private let remote: MeshIrohEndpointAddress

    public init(runtime: IrohEndpointRuntime, remote: MeshIrohEndpointAddress) {
        self.runtime = runtime
        self.remote = remote
    }

    public var path: MeshTransportPath {
        get async { await runtime.path(to: remote.endpointID) }
    }

    public func localAddressTicket() async throws -> String? {
        try await runtime.localAddress().ticket
    }

    public func exchange(_ request: MeshTransportRequest) async throws -> MeshTransportResponse {
        try request.validate()
        let race = MeshIrohExchangeRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(
                    continuation: continuation,
                    exchange: { try await runtime.exchange(request, with: remote) },
                    timeoutMilliseconds: request.timeoutMilliseconds
                )
            }
        } onCancel: {
            race.cancel()
        }
    }
}

/// A structured task group waits for every cancelled child before returning.
/// More importantly, cancelling an in-flight UniFFI QUIC call can invalidate
/// its callback context before Rust completes it. This single-completion gate
/// returns at the deadline but deliberately lets the exchange unwind when its
/// connection eventually succeeds or closes.
private final class MeshIrohExchangeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MeshTransportResponse, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    private enum CompletionSource {
        case exchange
        case timeout
        case cancellation
    }

    func start(
        continuation: CheckedContinuation<MeshTransportResponse, any Error>,
        exchange: @escaping @Sendable () async throws -> MeshTransportResponse,
        timeoutMilliseconds: Int
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        Task {
            do { finish(.success(try await exchange()), source: .exchange) }
            catch { finish(.failure(error), source: .exchange) }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                finish(.failure(MeshIrohError.timeout), source: .timeout)
            } catch {
                finish(.failure(error), source: .timeout)
            }
        }
        attach(timeoutTask: timeoutTask)
    }

    func cancel() {
        finish(.failure(CancellationError()), source: .cancellation)
    }

    private func attach(timeoutTask: Task<Void, Never>) {
        lock.lock()
        if isFinished {
            lock.unlock()
            timeoutTask.cancel()
            return
        }
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    private func finish(
        _ result: Result<MeshTransportResponse, any Error>,
        source: CompletionSource
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        if source != .timeout { timeoutTask?.cancel() }
        continuation?.resume(with: result)
    }
}
