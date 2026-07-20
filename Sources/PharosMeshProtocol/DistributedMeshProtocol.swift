import Foundation

/// Stable constants shared by every Pharos transport implementation.
public enum DistributedMeshProtocol {
    public static let version = 1
    public static let alpn = "me.pai.pharos/mesh/1"
    public static let maximumHeaderBytes = 4 * 1024 * 1024
    public static let maximumBlobBytes = 25 * 1024 * 1024
}

/// An Iroh Endpoint ID is deliberately opaque at the application boundary.
/// Iroh owns its textual encoding; Pharos only normalizes surrounding
/// whitespace and rejects values that cannot safely enter logs or pairing data.
public struct MeshEndpointID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        self.rawValue = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct MeshDeviceID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

public struct MeshTrustGroupID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

public enum MeshDeviceRole: String, Codable, CaseIterable, Sendable {
    case controller
    case host
    case replica
}

/// The user's preference, not the currently observed network path.
public enum MeshTransportPreference: String, Codable, CaseIterable, Sendable {
    /// Existing local UDS or remote TCP/Tailscale behavior.
    case legacy
    /// Require identity-addressed Iroh connectivity; never silently use TCP.
    case iroh
    /// Prefer Iroh and permit an explicitly configured migration fallback.
    case automatic
}

/// What carried a particular connection. IP addresses are intentionally absent:
/// path diagnostics must never become peer identity.
public enum MeshTransportPath: String, Codable, CaseIterable, Sendable {
    case local
    case legacyTCP = "legacy-tcp"
    case irohDirect = "iroh-direct"
    case irohRelay = "iroh-relay"
    case unavailable
}

public struct MeshDeviceDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: MeshDeviceID
    public var endpointID: MeshEndpointID
    public var displayName: String
    public var roles: Set<MeshDeviceRole>
    public var protocolVersion: Int

    public init(id: MeshDeviceID = MeshDeviceID(), endpointID: MeshEndpointID,
                displayName: String, roles: Set<MeshDeviceRole>,
                protocolVersion: Int = DistributedMeshProtocol.version) {
        self.id = id
        self.endpointID = endpointID
        self.displayName = displayName
        self.roles = roles
        self.protocolVersion = protocolVersion
    }
}

/// A privacy-safe snapshot suitable for Settings, CLI diagnostics, and logs.
public struct MeshConnectionSnapshot: Codable, Equatable, Sendable {
    public var peer: MeshDeviceID
    public var path: MeshTransportPath
    public var connected: Bool
    public var lastChange: Date

    public init(peer: MeshDeviceID, path: MeshTransportPath,
                connected: Bool, lastChange: Date) {
        self.peer = peer
        self.path = path
        self.connected = connected
        self.lastChange = lastChange
    }
}

/// Transport-neutral request framing. Legacy sockets and Iroh QUIC streams both
/// exchange the same header/body boundary, so application protocol code does not
/// know whether a connection was direct, relayed, local, or legacy TCP.
public struct MeshTransportRequest: Sendable, Equatable {
    public var header: Data
    public var body: Data?
    public var timeoutMilliseconds: Int

    public init(header: Data, body: Data? = nil, timeoutMilliseconds: Int = 5_000) {
        self.header = header
        self.body = body
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public func validate() throws {
        guard !header.isEmpty else { throw MeshTransportContractError.emptyHeader }
        guard header.count <= DistributedMeshProtocol.maximumHeaderBytes else {
            throw MeshTransportContractError.headerTooLarge
        }
        guard body?.count ?? 0 <= DistributedMeshProtocol.maximumBlobBytes else {
            throw MeshTransportContractError.bodyTooLarge
        }
        guard timeoutMilliseconds > 0 else {
            throw MeshTransportContractError.invalidTimeout
        }
    }
}

public struct MeshTransportResponse: Sendable, Equatable {
    public var header: Data
    public var body: Data?

    public init(header: Data, body: Data? = nil) {
        self.header = header
        self.body = body
    }

    public func validate() throws {
        guard !header.isEmpty else { throw MeshTransportContractError.emptyHeader }
        guard header.count <= DistributedMeshProtocol.maximumHeaderBytes else {
            throw MeshTransportContractError.headerTooLarge
        }
        guard body?.count ?? 0 <= DistributedMeshProtocol.maximumBlobBytes else {
            throw MeshTransportContractError.bodyTooLarge
        }
    }
}

public enum MeshTransportContractError: Error, Equatable, Sendable {
    case emptyHeader
    case headerTooLarge
    case bodyTooLarge
    case invalidTimeout
}

/// Implemented by legacy sockets first, then by Iroh. Keeping bytes at this
/// boundary lets the existing JSON protocol migrate without coupling domain
/// models to a networking SDK.
public protocol MeshTransport: Sendable {
    var path: MeshTransportPath { get async }
    func exchange(_ request: MeshTransportRequest) async throws -> MeshTransportResponse
}
