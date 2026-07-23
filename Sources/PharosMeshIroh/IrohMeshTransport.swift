import Foundation
import MeshKit
import MeshKitIroh
import PharosMeshProtocol

public enum MeshIrohRelayPolicy: Sendable {
    case production
    case custom(urls: [String])
    case disabled
}

/// Pharos compatibility value around MeshKit's product-neutral address.
public struct MeshIrohEndpointAddress: Equatable, Sendable {
    public var endpointID: PharosMeshProtocol.MeshEndpointID
    public var ticket: String

    public init(endpointID: PharosMeshProtocol.MeshEndpointID, ticket: String) {
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

public struct MeshIrohPeerStatus: Equatable, Sendable {
    public var endpointID: PharosMeshProtocol.MeshEndpointID
    public var path: PharosMeshProtocol.MeshTransportPath
    public var roundTripTimeMilliseconds: UInt64?
    public var transmittedBytes: Int64
    public var receivedBytes: Int64
    public var lostBytes: Int64
}

public typealias MeshIrohRequestHandler = @Sendable (
    _ request: MeshTransportRequest,
    _ remoteEndpointID: PharosMeshProtocol.MeshEndpointID
) async throws -> MeshTransportResponse

public typealias MeshIrohAdmissionPolicy = @Sendable (
    _ remoteEndpointID: PharosMeshProtocol.MeshEndpointID
) async -> Bool

public enum MeshIrohAvailability {
    public static var isAvailable: Bool { MeshKitIroh.MeshIrohAvailability.isAvailable }
}

/// Compatibility adapter that preserves Pharos' existing wire protocol while
/// delegating endpoint and QUIC lifecycle to the reusable MeshKit package.
public actor IrohEndpointRuntime {
    private let endpoint: MeshKitIroh.IrohEndpoint
    private let localEndpointID: MeshKit.MeshEndpointID?
    private let coldConnectionGate = MeshColdConnectionGate()

    private init(
        endpoint: MeshKitIroh.IrohEndpoint,
        localEndpointID: MeshKit.MeshEndpointID?
    ) {
        self.endpoint = endpoint
        self.localEndpointID = localEndpointID
    }

    public static func bind(
        secretKey: Data? = nil,
        expectedEndpointID: PharosMeshProtocol.MeshEndpointID? = nil,
        relayPolicy: MeshIrohRelayPolicy = .production,
        bindAddress: String? = nil,
        admissionPolicy: MeshIrohAdmissionPolicy? = nil
    ) async throws -> IrohEndpointRuntime {
        do {
            let expected = try expectedEndpointID.map { value in
                guard let converted = MeshKit.MeshEndpointID(rawValue: value.rawValue) else {
                    throw MeshIrohError.invalidEndpointID
                }
                return converted
            }
            let kitRelayPolicy: MeshKitIroh.MeshRelayPolicy = switch relayPolicy {
            case .production: .production
            case .custom(let urls): .custom(urls: urls)
            case .disabled: .disabled
            }
            let kitAdmissionPolicy: MeshKitIroh.MeshAdmissionPolicy?
            if let admissionPolicy {
                kitAdmissionPolicy = { remoteID in
                    guard let converted = PharosMeshProtocol.MeshEndpointID(
                        rawValue: remoteID.rawValue
                    ) else { return false }
                    return await admissionPolicy(converted)
                }
            } else {
                kitAdmissionPolicy = nil
            }
            let endpoint = try await MeshKitIroh.IrohEndpoint.bind(
                configuration: try configuration(),
                secretKey: secretKey,
                expectedEndpointID: expected,
                relayPolicy: kitRelayPolicy,
                bindAddress: bindAddress,
                admissionPolicy: kitAdmissionPolicy
            )
            return IrohEndpointRuntime(
                endpoint: endpoint, localEndpointID: expected
            )
        } catch {
            throw mapIrohError(error)
        }
    }

    public func localAddress() async throws -> MeshIrohEndpointAddress {
        do {
            let address = try await endpoint.localAddress()
            guard let endpointID = PharosMeshProtocol.MeshEndpointID(
                rawValue: address.endpointID.rawValue
            ) else { throw MeshIrohError.invalidEndpointID }
            return MeshIrohEndpointAddress(endpointID: endpointID, ticket: address.ticket)
        } catch {
            throw mapIrohError(error)
        }
    }

    public func secretKeyBytes() async throws -> Data {
        do { return try await endpoint.secretKeyBytes() }
        catch { throw mapIrohError(error) }
    }

    public func waitUntilOnline() async {
        await endpoint.waitUntilOnline()
    }

    public func startServing(_ handler: @escaping MeshIrohRequestHandler) async {
        await endpoint.startServing { request, remoteID in
            guard let endpointID = PharosMeshProtocol.MeshEndpointID(
                rawValue: remoteID.rawValue
            ) else { throw MeshIrohError.invalidEndpointID }
            let response = try await handler(
                MeshTransportRequest(
                    header: request.header,
                    body: request.body,
                    timeoutMilliseconds: request.timeout.millisecondsRoundedUp
                ),
                endpointID
            )
            return MeshKit.MeshResponse(header: response.header, body: response.body)
        }
    }

    public func exchange(
        _ request: MeshTransportRequest,
        with remote: MeshIrohEndpointAddress
    ) async throws -> MeshTransportResponse {
        try await exchange(
            request,
            with: remote.endpointID,
            addressTicket: remote.ticket
        )
    }

    public func exchange(
        _ request: MeshTransportRequest,
        with remoteEndpointID: PharosMeshProtocol.MeshEndpointID,
        addressTicket: String? = nil
    ) async throws -> MeshTransportResponse {
        guard let endpointID = MeshKit.MeshEndpointID(
            rawValue: remoteEndpointID.rawValue
        ) else { throw MeshIrohError.invalidEndpointID }
        // Both replicas run the same one-second anti-entropy loop. On a cold
        // path, letting both sides dial at once can make Iroh repeatedly close
        // each side's stream as a duplicate before either canonical connection
        // reaches the pool. Pick one deterministic preferred dialer by stable
        // Endpoint ID. The other side briefly waits for that inbound,
        // bidirectional connection and only falls back to its own dial when the
        // preferred peer is not actually running an outbound loop.
        if let localEndpointID,
           await endpoint.path(to: endpointID) == .unavailable,
           Self.prefersRemoteColdDial(
            localEndpointID: localEndpointID, remoteEndpointID: endpointID
           ) {
            let grace = Self.remoteColdDialGraceMilliseconds(
                requestTimeoutMilliseconds: request.timeoutMilliseconds
            )
            await waitForInboundPath(
                to: endpointID, maximumMilliseconds: grace
            )
        }
        // Sync and presence intentionally run concurrently, but two first
        // requests must not both observe an empty connection pool and create
        // competing QUIC dials for the same peer. Once either request has
        // established a path, Iroh can safely multiplex both RPC streams.
        if await endpoint.path(to: endpointID) == .unavailable {
            await coldConnectionGate.acquire(remoteEndpointID)
            if await endpoint.path(to: endpointID) != .unavailable {
                // Another first request completed while this caller waited.
                // Release immediately so all queued RPCs can multiplex on the
                // established connection instead of serializing whole bodies.
                await coldConnectionGate.release(remoteEndpointID)
                return try await exchangeAfterColdPathGate(
                    request, endpointID: endpointID,
                    remoteEndpointID: remoteEndpointID,
                    addressTicket: addressTicket
                )
            }
            do {
                let response = try await exchangeAfterColdPathGate(
                    request, endpointID: endpointID,
                    remoteEndpointID: remoteEndpointID,
                    addressTicket: addressTicket
                )
                await coldConnectionGate.release(remoteEndpointID)
                return response
            } catch {
                await coldConnectionGate.release(remoteEndpointID)
                throw error
            }
        }
        return try await exchangeAfterColdPathGate(
            request, endpointID: endpointID,
            remoteEndpointID: remoteEndpointID,
            addressTicket: addressTicket
        )
    }

    private func waitForInboundPath(
        to endpointID: MeshKit.MeshEndpointID,
        maximumMilliseconds: Int
    ) async {
        guard maximumMilliseconds > 0 else { return }
        let deadline = Date().addingTimeInterval(
            Double(maximumMilliseconds) / 1_000
        )
        while deadline.timeIntervalSinceNow > 0 {
            if await endpoint.path(to: endpointID) != .unavailable { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func exchangeAfterColdPathGate(
        _ request: MeshTransportRequest,
        endpointID: MeshKit.MeshEndpointID,
        remoteEndpointID: PharosMeshProtocol.MeshEndpointID,
        addressTicket: String?
    ) async throws -> MeshTransportResponse {
        let deadline = Date().addingTimeInterval(
            Double(request.timeoutMilliseconds) / 1_000
        )
        var attempt = 0
        while true {
            let remainingMilliseconds = Int(
                (deadline.timeIntervalSinceNow * 1_000).rounded(.down)
            )
            guard remainingMilliseconds > 0 else { throw MeshIrohError.timeout }
            let hasEstablishedPath: Bool
            switch await endpoint.path(to: endpointID) {
            case .direct, .relay:
                hasEstablishedPath = true
            case .unavailable:
                hasEstablishedPath = false
            }
            let transport = MeshKitIroh.IrohTransport(
                endpoint: endpoint,
                target: MeshKitIroh.MeshDialTarget(
                    endpointID: endpointID,
                    // A ticket is bootstrap material, not a connection key.
                    // Once either side's canonical path exists, dialing again
                    // with the ticket can keep manufacturing duplicates instead
                    // of opening a stream on the surviving connection.
                    addressTicket: Self.effectiveAddressTicket(
                        addressTicket,
                        hasEstablishedPath: hasEstablishedPath,
                        isDuplicateRecovery: attempt > 0
                    )
                )
            )
            let usesBootstrapTicket =
                !hasEstablishedPath &&
                Self.effectiveAddressTicket(
                    addressTicket,
                    hasEstablishedPath: hasEstablishedPath,
                    isDuplicateRecovery: attempt > 0
                ) != nil
            let attemptTimeoutMilliseconds = usesBootstrapTicket
                ? Self.bootstrapTicketAttemptTimeoutMilliseconds(
                    remainingMilliseconds: remainingMilliseconds
                )
                : remainingMilliseconds
            do {
                let response = try await transport.exchange(MeshKit.MeshRequest(
                    header: request.header,
                    body: request.body,
                    timeout: .milliseconds(attemptTimeoutMilliseconds)
                ))
                return MeshTransportResponse(
                    header: response.header, body: response.body
                )
            } catch {
                attempt += 1
                guard attempt < 8 else { throw mapIrohError(error) }
                if usesBootstrapTicket {
                    // Tickets are authenticated routing hints, not durable
                    // addresses. A peer restart or network move can make every
                    // direct address in the saved ticket stale while the same
                    // Endpoint ID is already discoverable through Iroh. Spend
                    // only part of the request budget on the hint, then retry
                    // identity-only under the original overall deadline.
                    continue
                }
                guard Self.isDuplicateConnectionDescription(
                    String(reflecting: error) + " " + error.localizedDescription
                ) else { throw mapIrohError(error) }
                // Simultaneous dials are resolved by Iroh retaining one
                // canonical connection and closing the duplicate. Re-open the
                // stream on that surviving connection after a bounded settling
                // delay. Immediate retries can repeatedly hit the same closing
                // connection before the canonical path reaches the pool.
                let delay = Self.duplicateConnectionRetryDelayMilliseconds(
                    attempt: attempt
                )
                guard deadline.timeIntervalSinceNow * 1_000 > Double(delay + 50)
                else { throw mapIrohError(error) }
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
    }

    static func isDuplicateConnectionDescription(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("duplicate connection")
    }

    static func duplicateConnectionRetryDelayMilliseconds(attempt: Int) -> Int {
        let exponent = min(max(attempt - 1, 0), 3)
        return min(150 * (1 << exponent), 1_000)
    }

    static func prefersRemoteColdDial(
        localEndpointID: MeshKit.MeshEndpointID,
        remoteEndpointID: MeshKit.MeshEndpointID
    ) -> Bool {
        localEndpointID.rawValue > remoteEndpointID.rawValue
    }

    static func remoteColdDialGraceMilliseconds(
        requestTimeoutMilliseconds: Int
    ) -> Int {
        // Preserve more than half of the original request deadline for the
        // responder's fallback dial. A normal 10-second background request
        // gives the preferred relay dial up to 4 seconds to establish.
        max(0, min(4_000, requestTimeoutMilliseconds * 2 / 5))
    }

    static func effectiveAddressTicket(
        _ ticket: String?, hasEstablishedPath: Bool,
        isDuplicateRecovery: Bool
    ) -> String? {
        hasEstablishedPath || isDuplicateRecovery ? nil : ticket
    }

    static func bootstrapTicketAttemptTimeoutMilliseconds(
        remainingMilliseconds: Int
    ) -> Int {
        // Keep at least half of the caller's deadline for endpoint-only
        // discovery, while still allowing a normal cold relay handshake up to
        // 4.5 seconds to use the fresh bootstrap hint.
        max(1, min(4_500, remainingMilliseconds / 2))
    }

    public func path(
        to remote: PharosMeshProtocol.MeshEndpointID
    ) async -> PharosMeshProtocol.MeshTransportPath {
        guard let endpointID = MeshKit.MeshEndpointID(rawValue: remote.rawValue) else {
            return .unavailable
        }
        return switch await endpoint.path(to: endpointID) {
        case .direct: PharosMeshProtocol.MeshTransportPath.irohDirect
        case .relay: PharosMeshProtocol.MeshTransportPath.irohRelay
        case .unavailable: PharosMeshProtocol.MeshTransportPath.unavailable
        }
    }

    public func status(
        of remote: PharosMeshProtocol.MeshEndpointID
    ) async -> MeshIrohPeerStatus? {
        guard let endpointID = MeshKit.MeshEndpointID(rawValue: remote.rawValue) else {
            return nil
        }
        return Self.mapStatus(await endpoint.status(of: endpointID))
    }

    public func statusEvents(
        of remote: PharosMeshProtocol.MeshEndpointID
    ) async -> AsyncStream<MeshIrohPeerStatus> {
        guard let endpointID = MeshKit.MeshEndpointID(rawValue: remote.rawValue) else {
            return AsyncStream { $0.finish() }
        }
        let upstream = await endpoint.statusEvents(of: endpointID)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await status in upstream {
                    if let mapped = Self.mapStatus(status) {
                        continuation.yield(mapped)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func close() async throws {
        do { try await endpoint.close() }
        catch { throw mapIrohError(error) }
    }

    private static func configuration() throws -> MeshKit.MeshConfiguration {
        try MeshKit.MeshConfiguration(
            alpn: DistributedMeshProtocol.alpn,
            maximumHeaderBytes: DistributedMeshProtocol.maximumHeaderBytes,
            maximumBodyBytes: DistributedMeshProtocol.maximumBlobBytes,
            addressTicketNamespace: "pharos",
            frameMagic: 0x50484d31 // PHM1 — preserve existing pairings and peers.
        )
    }

    private static func mapStatus(
        _ status: MeshKitIroh.MeshPeerStatus
    ) -> MeshIrohPeerStatus? {
        guard let endpointID = PharosMeshProtocol.MeshEndpointID(
            rawValue: status.endpointID.rawValue
        ) else { return nil }
        let path: PharosMeshProtocol.MeshTransportPath
        switch status.path {
        case .direct: path = .irohDirect
        case .relay: path = .irohRelay
        case .unavailable: path = .unavailable
        }
        return MeshIrohPeerStatus(
            endpointID: endpointID,
            path: path,
            roundTripTimeMilliseconds: status.roundTripTimeMilliseconds,
            transmittedBytes: status.transmittedBytes,
            receivedBytes: status.receivedBytes,
            lostBytes: status.lostBytes
        )
    }
}

private actor MeshColdConnectionGate {
    private var held: Set<PharosMeshProtocol.MeshEndpointID> = []
    private var waiters: [
        PharosMeshProtocol.MeshEndpointID: [CheckedContinuation<Void, Never>]
    ] = [:]

    func acquire(_ peer: PharosMeshProtocol.MeshEndpointID) async {
        guard !held.insert(peer).inserted else { return }
        await withCheckedContinuation { continuation in
            waiters[peer, default: []].append(continuation)
        }
    }

    func release(_ peer: PharosMeshProtocol.MeshEndpointID) {
        guard var queue = waiters[peer], !queue.isEmpty else {
            held.remove(peer)
            waiters[peer] = nil
            return
        }
        let next = queue.removeFirst()
        waiters[peer] = queue.isEmpty ? nil : queue
        next.resume()
    }
}

public struct IrohMeshTransport: PharosMeshProtocol.MeshTransport, Sendable {
    private let runtime: IrohEndpointRuntime
    private let remoteEndpointID: PharosMeshProtocol.MeshEndpointID
    private let addressTicket: String?

    public init(runtime: IrohEndpointRuntime, remote: MeshIrohEndpointAddress) {
        self.runtime = runtime
        self.remoteEndpointID = remote.endpointID
        self.addressTicket = remote.ticket
    }

    public init(
        runtime: IrohEndpointRuntime,
        remoteEndpointID: PharosMeshProtocol.MeshEndpointID,
        addressTicket: String? = nil
    ) {
        self.runtime = runtime
        self.remoteEndpointID = remoteEndpointID
        self.addressTicket = addressTicket
    }

    public var path: PharosMeshProtocol.MeshTransportPath {
        get async { await runtime.path(to: remoteEndpointID) }
    }

    public func localAddressTicket() async throws -> String? {
        try await runtime.localAddress().ticket
    }

    public func exchange(_ request: MeshTransportRequest) async throws -> MeshTransportResponse {
        try request.validate()
        return try await runtime.exchange(
            request,
            with: remoteEndpointID,
            addressTicket: addressTicket
        )
    }
}

private func mapIrohError(_ error: any Error) -> any Error {
    guard let error = error as? MeshKitIroh.MeshIrohError else { return error }
    return switch error {
    case .unavailableOnPlatform: MeshIrohError.unavailableOnPlatform
    case .invalidSecretKey: MeshIrohError.invalidSecretKey
    case .invalidEndpointID: MeshIrohError.invalidEndpointID
    case .invalidAddressTicket: MeshIrohError.invalidAddressTicket
    case .endpointIdentityMismatch: MeshIrohError.endpointIdentityMismatch
    case .wrongFrameKind: MeshIrohError.wrongFrameKind
    case .timeout: MeshIrohError.timeout
    }
}

private extension Duration {
    var millisecondsRoundedUp: Int {
        let components = self.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        guard !seconds.overflow else { return Int.max }
        let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
        let fractional = components.attoseconds <= 0 ? 0 :
            (components.attoseconds + attosecondsPerMillisecond - 1) /
                attosecondsPerMillisecond
        let total = seconds.partialValue.addingReportingOverflow(Int64(fractional))
        guard !total.overflow, total.partialValue <= Int64(Int.max) else { return Int.max }
        return max(1, Int(total.partialValue))
    }
}
