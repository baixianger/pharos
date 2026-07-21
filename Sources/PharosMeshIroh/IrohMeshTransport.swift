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
    private let endpoint: Endpoint
    private var connections: [MeshEndpointID: Connection] = [:]
    private var servingTask: Task<Void, Never>?
    private var streamServingTasks: [MeshEndpointID: Task<Void, Never>] = [:]
    private var streamServingGenerations: [MeshEndpointID: UUID] = [:]
    private var requestHandler: MeshIrohRequestHandler?

    private init(endpoint: Endpoint) {
        self.endpoint = endpoint
    }
#else
    private init() {}
#endif

    public static func bind(
        secretKey: Data? = nil,
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
        return IrohEndpointRuntime(endpoint: endpoint)
#else
        throw MeshIrohError.unavailableOnPlatform
#endif
    }

    public func localAddress() throws -> MeshIrohEndpointAddress {
#if canImport(IrohLib)
        guard let id = MeshEndpointID(rawValue: endpoint.id().description) else {
            throw MeshIrohError.invalidEndpointID
        }
        let ticket = try EndpointTicket.fromAddr(addr: endpoint.addr()).description
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

    /// Starts accepting the Pharos ALPN. Calling this twice replaces the prior
    /// accept loop; closing the runtime cancels it and closes the endpoint.
    public func startServing(_ handler: @escaping MeshIrohRequestHandler) {
#if canImport(IrohLib)
        requestHandler = handler
        for task in streamServingTasks.values { task.cancel() }
        streamServingTasks.removeAll()
        streamServingGenerations.removeAll()
        for (remoteID, connection) in connections
        where connection.closeReason() == nil {
            beginServingStreams(on: connection, remoteID: remoteID)
        }
        servingTask?.cancel()
        servingTask = Task { [weak self] in
            guard let self else { return }
            await self.acceptLoop()
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
        guard let connection = connections[remote], connection.closeReason() == nil else {
            return .unavailable
        }
        let selected = connection.paths().first(where: \.isSelected)
        if selected?.isRelay == true { return .irohRelay }
        if selected?.isIp == true { return .irohDirect }
        return .unavailable
#else
        return .unavailable
#endif
    }

    public func close() async throws {
#if canImport(IrohLib)
        servingTask?.cancel()
        servingTask = nil
        requestHandler = nil
        for task in streamServingTasks.values { task.cancel() }
        streamServingTasks.removeAll()
        streamServingGenerations.removeAll()
        connections.removeAll()
        try await endpoint.close()
#endif
    }

#if canImport(IrohLib)
    private func connection(to remote: MeshIrohEndpointAddress) async throws -> Connection {
        if let existing = connections[remote.endpointID], existing.closeReason() == nil {
            beginServingStreams(on: existing, remoteID: remote.endpointID)
            return existing
        }
        let ticket = try EndpointTicket.fromString(str: remote.ticket)
        let ticketID = ticket.endpointAddr().id().description
        guard ticketID == remote.endpointID.rawValue else {
            throw MeshIrohError.endpointIdentityMismatch
        }
        let connection = try await endpoint.connect(
            addr: ticket.endpointAddr(),
            alpn: Data(DistributedMeshProtocol.alpn.utf8)
        )
        guard connection.remoteId().description == remote.endpointID.rawValue else {
            try? connection.close(errorCode: 1, reason: Data("identity mismatch".utf8))
            throw MeshIrohError.endpointIdentityMismatch
        }
        connections[remote.endpointID] = connection
        beginServingStreams(
            on: connection, remoteID: remote.endpointID,
            replacingExisting: true
        )
        return connection
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
            guard let remoteID = MeshEndpointID(rawValue: connection.remoteId().description) else {
                try? connection.close(errorCode: 2, reason: Data("invalid endpoint id".utf8))
                return
            }
            connections[remoteID] = connection
            beginServingStreams(
                on: connection, remoteID: remoteID,
                replacingExisting: true
            )
        } catch {
            // Connection-local failures end this peer loop. The endpoint accept
            // loop remains available for a clean reconnect.
        }
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
/// UniFFI cancellation may need the underlying QUIC operation to unwind, so a
/// task-group timeout can report the right error only after an unbounded wait.
/// This single-completion gate returns at the deadline and cancels the losing
/// operation without allowing either task to resume the continuation twice.
private final class MeshIrohExchangeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MeshTransportResponse, any Error>?
    private var exchangeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

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

        let exchangeTask = Task {
            do { finish(.success(try await exchange())) }
            catch { finish(.failure(error)) }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                finish(.failure(MeshIrohError.timeout))
            } catch {
                finish(.failure(error))
            }
        }
        attach(exchangeTask: exchangeTask, timeoutTask: timeoutTask)
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func attach(exchangeTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        lock.lock()
        if isFinished {
            lock.unlock()
            exchangeTask.cancel()
            timeoutTask.cancel()
            return
        }
        self.exchangeTask = exchangeTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    private func finish(_ result: Result<MeshTransportResponse, any Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        let exchangeTask = self.exchangeTask
        let timeoutTask = self.timeoutTask
        self.exchangeTask = nil
        self.timeoutTask = nil
        lock.unlock()

        exchangeTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}
