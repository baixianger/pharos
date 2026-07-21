import Foundation
import MeshKit
import MeshKitIroh
import PharosMeshProtocol

public enum MeshIrohRelayPolicy: Sendable {
    case production
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

public typealias MeshIrohRequestHandler = @Sendable (
    _ request: MeshTransportRequest,
    _ remoteEndpointID: PharosMeshProtocol.MeshEndpointID
) async throws -> MeshTransportResponse

public enum MeshIrohAvailability {
    public static var isAvailable: Bool { MeshKitIroh.MeshIrohAvailability.isAvailable }
}

/// Compatibility adapter that preserves Pharos' existing wire protocol while
/// delegating endpoint and QUIC lifecycle to the reusable MeshKit package.
public actor IrohEndpointRuntime {
    private let endpoint: MeshKitIroh.IrohEndpoint

    private init(endpoint: MeshKitIroh.IrohEndpoint) {
        self.endpoint = endpoint
    }

    public static func bind(
        secretKey: Data? = nil,
        expectedEndpointID: PharosMeshProtocol.MeshEndpointID? = nil,
        relayPolicy: MeshIrohRelayPolicy = .production,
        bindAddress: String? = nil
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
            case .disabled: .disabled
            }
            let endpoint = try await MeshKitIroh.IrohEndpoint.bind(
                configuration: try configuration(),
                secretKey: secretKey,
                expectedEndpointID: expected,
                relayPolicy: kitRelayPolicy,
                bindAddress: bindAddress
            )
            return IrohEndpointRuntime(endpoint: endpoint)
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
        do {
            guard let endpointID = MeshKit.MeshEndpointID(
                rawValue: remote.endpointID.rawValue
            ) else { throw MeshIrohError.invalidEndpointID }
            let transport = MeshKitIroh.IrohTransport(
                endpoint: endpoint,
                remote: MeshKitIroh.MeshEndpointAddress(
                    endpointID: endpointID,
                    ticket: remote.ticket
                )
            )
            let response = try await transport.exchange(MeshKit.MeshRequest(
                header: request.header,
                body: request.body,
                timeout: .milliseconds(request.timeoutMilliseconds)
            ))
            return MeshTransportResponse(header: response.header, body: response.body)
        } catch {
            throw mapIrohError(error)
        }
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
}

public struct IrohMeshTransport: PharosMeshProtocol.MeshTransport, Sendable {
    private let runtime: IrohEndpointRuntime
    private let remote: MeshIrohEndpointAddress

    public init(runtime: IrohEndpointRuntime, remote: MeshIrohEndpointAddress) {
        self.runtime = runtime
        self.remote = remote
    }

    public var path: PharosMeshProtocol.MeshTransportPath {
        get async { await runtime.path(to: remote.endpointID) }
    }

    public func localAddressTicket() async throws -> String? {
        try await runtime.localAddress().ticket
    }

    public func exchange(_ request: MeshTransportRequest) async throws -> MeshTransportResponse {
        try request.validate()
        return try await runtime.exchange(request, with: remote)
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
