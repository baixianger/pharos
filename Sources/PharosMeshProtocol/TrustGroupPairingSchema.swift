import Foundation

public enum MeshTrustInvitationValidationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidMembershipEpoch
    case invalidAddressTicket
    case invalidPublicKey
    case invalidRoles
    case invalidLifetime
    case invalidNonce
    case invalidSignature
    case ticketTooLarge
    case invalidTicketEncoding
}

/// Signed QR/deep-link payload. The nonce is a bearer secret, so descriptions
/// are always redacted even though the wire value remains Codable.
public struct MeshTrustInvitation: Codable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public static let version = 1
    public static let maximumLifetimeMilliseconds: Int64 = 10 * 60 * 1_000
    public static let maximumAddressTicketBytes = 16 * 1024

    public var protocolVersion: Int
    public var trustGroupID: MeshTrustGroupID
    public var membershipEpoch: UInt64
    public var inviterDeviceID: MeshDeviceID
    public var inviterEndpointID: MeshEndpointID
    public var inviterAddressTicket: String
    public var inviterSigningPublicKey: Data
    public var requestedRoles: [MeshDeviceRole]
    public var issuedAtMilliseconds: Int64
    public var expiresAtMilliseconds: Int64
    public var nonce: Data
    public var signature: Data

    public init(
        trustGroupID: MeshTrustGroupID,
        membershipEpoch: UInt64,
        inviterDeviceID: MeshDeviceID,
        inviterEndpointID: MeshEndpointID,
        inviterAddressTicket: String,
        inviterSigningPublicKey: Data,
        requestedRoles: Set<MeshDeviceRole>,
        issuedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        nonce: Data,
        signature: Data = Data(),
        protocolVersion: Int = Self.version
    ) {
        self.protocolVersion = protocolVersion
        self.trustGroupID = trustGroupID
        self.membershipEpoch = membershipEpoch
        self.inviterDeviceID = inviterDeviceID
        self.inviterEndpointID = inviterEndpointID
        self.inviterAddressTicket = inviterAddressTicket
        self.inviterSigningPublicKey = inviterSigningPublicKey
        self.requestedRoles = requestedRoles.sorted { $0.rawValue < $1.rawValue }
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.nonce = nonce
        self.signature = signature
    }

    public func validateStructure(requireSignature: Bool = true) throws {
        guard protocolVersion == Self.version else {
            throw MeshTrustInvitationValidationError.unsupportedVersion
        }
        guard membershipEpoch > 0, membershipEpoch <= UInt64(Int64.max) else {
            throw MeshTrustInvitationValidationError.invalidMembershipEpoch
        }
        guard !inviterAddressTicket.isEmpty,
              inviterAddressTicket.utf8.count <= Self.maximumAddressTicketBytes else {
            throw MeshTrustInvitationValidationError.invalidAddressTicket
        }
        guard inviterSigningPublicKey.count == 32 else {
            throw MeshTrustInvitationValidationError.invalidPublicKey
        }
        let normalizedRoles = Set(requestedRoles)
        guard !normalizedRoles.isEmpty, normalizedRoles.count == requestedRoles.count,
              requestedRoles == normalizedRoles.sorted(by: { $0.rawValue < $1.rawValue }) else {
            throw MeshTrustInvitationValidationError.invalidRoles
        }
        let (lifetime, overflow) = expiresAtMilliseconds.subtractingReportingOverflow(
            issuedAtMilliseconds
        )
        guard !overflow, lifetime > 0,
              lifetime <= Self.maximumLifetimeMilliseconds else {
            throw MeshTrustInvitationValidationError.invalidLifetime
        }
        guard nonce.count == 32 else {
            throw MeshTrustInvitationValidationError.invalidNonce
        }
        if requireSignature, signature.count != 64 {
            throw MeshTrustInvitationValidationError.invalidSignature
        }
    }

    public func canonicalSigningBytes() throws -> Data {
        try MeshCanonicalJSON.encode(UnsignedInvitation(self))
    }

    public func canonicalBytes() throws -> Data {
        try MeshCanonicalJSON.encode(self)
    }

    public var description: String {
        "MeshTrustInvitation(group: \(trustGroupID.rawValue.uuidString), secret: <redacted>)"
    }

    public var debugDescription: String { description }

    private struct UnsignedInvitation: Codable {
        var protocolVersion: Int
        var trustGroupID: MeshTrustGroupID
        var membershipEpoch: UInt64
        var inviterDeviceID: MeshDeviceID
        var inviterEndpointID: MeshEndpointID
        var inviterAddressTicket: String
        var inviterSigningPublicKey: Data
        var requestedRoles: [MeshDeviceRole]
        var issuedAtMilliseconds: Int64
        var expiresAtMilliseconds: Int64
        var nonce: Data

        init(_ invitation: MeshTrustInvitation) {
            protocolVersion = invitation.protocolVersion
            trustGroupID = invitation.trustGroupID
            membershipEpoch = invitation.membershipEpoch
            inviterDeviceID = invitation.inviterDeviceID
            inviterEndpointID = invitation.inviterEndpointID
            inviterAddressTicket = invitation.inviterAddressTicket
            inviterSigningPublicKey = invitation.inviterSigningPublicKey
            requestedRoles = invitation.requestedRoles
            issuedAtMilliseconds = invitation.issuedAtMilliseconds
            expiresAtMilliseconds = invitation.expiresAtMilliseconds
            nonce = invitation.nonce
        }
    }
}

public struct MeshTrustAcceptance: Codable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public static let version = 1

    public var protocolVersion: Int
    public var trustGroupID: MeshTrustGroupID
    public var membershipEpoch: UInt64
    public var invitationDigest: Data
    public var invitationNonceDigest: Data
    public var acceptingDeviceID: MeshDeviceID
    public var acceptingEndpointID: MeshEndpointID
    public var acceptingAddressTicket: String
    public var acceptingSigningPublicKey: Data
    public var displayName: String
    public var roles: [MeshDeviceRole]
    public var acceptedAtMilliseconds: Int64
    public var signature: Data

    public init(
        trustGroupID: MeshTrustGroupID,
        membershipEpoch: UInt64,
        invitationDigest: Data,
        invitationNonceDigest: Data,
        acceptingDeviceID: MeshDeviceID,
        acceptingEndpointID: MeshEndpointID,
        acceptingAddressTicket: String,
        acceptingSigningPublicKey: Data,
        displayName: String,
        roles: Set<MeshDeviceRole>,
        acceptedAtMilliseconds: Int64,
        signature: Data = Data(),
        protocolVersion: Int = Self.version
    ) {
        self.protocolVersion = protocolVersion
        self.trustGroupID = trustGroupID
        self.membershipEpoch = membershipEpoch
        self.invitationDigest = invitationDigest
        self.invitationNonceDigest = invitationNonceDigest
        self.acceptingDeviceID = acceptingDeviceID
        self.acceptingEndpointID = acceptingEndpointID
        self.acceptingAddressTicket = acceptingAddressTicket
        self.acceptingSigningPublicKey = acceptingSigningPublicKey
        self.displayName = displayName
        self.roles = roles.sorted { $0.rawValue < $1.rawValue }
        self.acceptedAtMilliseconds = acceptedAtMilliseconds
        self.signature = signature
    }

    public func validateStructure(requireSignature: Bool = true) throws {
        guard protocolVersion == Self.version else {
            throw MeshTrustInvitationValidationError.unsupportedVersion
        }
        guard membershipEpoch > 0, membershipEpoch <= UInt64(Int64.max) else {
            throw MeshTrustInvitationValidationError.invalidMembershipEpoch
        }
        guard invitationDigest.count == 32, invitationNonceDigest.count == 32 else {
            throw MeshTrustInvitationValidationError.invalidNonce
        }
        guard !acceptingAddressTicket.isEmpty,
              acceptingAddressTicket.utf8.count <= MeshTrustInvitation.maximumAddressTicketBytes else {
            throw MeshTrustInvitationValidationError.invalidAddressTicket
        }
        guard acceptingSigningPublicKey.count == 32 else {
            throw MeshTrustInvitationValidationError.invalidPublicKey
        }
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplayName.isEmpty, displayName == trimmedDisplayName,
              displayName.utf8.count <= 128,
              !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MeshTrustInvitationValidationError.invalidTicketEncoding
        }
        let normalizedRoles = Set(roles)
        guard !normalizedRoles.isEmpty, normalizedRoles.count == roles.count,
              roles == normalizedRoles.sorted(by: { $0.rawValue < $1.rawValue }) else {
            throw MeshTrustInvitationValidationError.invalidRoles
        }
        if requireSignature, signature.count != 64 {
            throw MeshTrustInvitationValidationError.invalidSignature
        }
    }

    public func canonicalSigningBytes() throws -> Data {
        try MeshCanonicalJSON.encode(UnsignedAcceptance(self))
    }

    public var description: String {
        "MeshTrustAcceptance(device: \(acceptingDeviceID.rawValue.uuidString), proof: <redacted>)"
    }

    public var debugDescription: String { description }

    private struct UnsignedAcceptance: Codable {
        var protocolVersion: Int
        var trustGroupID: MeshTrustGroupID
        var membershipEpoch: UInt64
        var invitationDigest: Data
        var invitationNonceDigest: Data
        var acceptingDeviceID: MeshDeviceID
        var acceptingEndpointID: MeshEndpointID
        var acceptingAddressTicket: String
        var acceptingSigningPublicKey: Data
        var displayName: String
        var roles: [MeshDeviceRole]
        var acceptedAtMilliseconds: Int64

        init(_ acceptance: MeshTrustAcceptance) {
            protocolVersion = acceptance.protocolVersion
            trustGroupID = acceptance.trustGroupID
            membershipEpoch = acceptance.membershipEpoch
            invitationDigest = acceptance.invitationDigest
            invitationNonceDigest = acceptance.invitationNonceDigest
            acceptingDeviceID = acceptance.acceptingDeviceID
            acceptingEndpointID = acceptance.acceptingEndpointID
            acceptingAddressTicket = acceptance.acceptingAddressTicket
            acceptingSigningPublicKey = acceptance.acceptingSigningPublicKey
            displayName = acceptance.displayName
            roles = acceptance.roles
            acceptedAtMilliseconds = acceptance.acceptedAtMilliseconds
        }
    }
}

public enum MeshTrustInvitationTicket {
    public static let prefix = "pharos-device-v1:"
    public static let maximumBytes = 64 * 1024

    public static func encode(_ invitation: MeshTrustInvitation) throws -> String {
        try invitation.validateStructure()
        let data = try invitation.canonicalBytes()
        guard data.count <= maximumBytes else {
            throw MeshTrustInvitationValidationError.ticketTooLarge
        }
        return prefix + base64URL(data)
    }

    public static func decode(_ ticket: String) throws -> MeshTrustInvitation {
        guard ticket.utf8.count <= maximumBytes * 2, ticket.hasPrefix(prefix) else {
            throw MeshTrustInvitationValidationError.invalidTicketEncoding
        }
        let encoded = String(ticket.dropFirst(prefix.count))
        guard let data = decodeBase64URL(encoded), data.count <= maximumBytes,
              let invitation = try? JSONDecoder().decode(MeshTrustInvitation.self, from: data) else {
            throw MeshTrustInvitationValidationError.invalidTicketEncoding
        }
        try invitation.validateStructure()
        return invitation
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

public enum MeshTrustAcceptanceTicket {
    public static let prefix = "pharos-device-acceptance-v1:"
    public static let maximumBytes = 64 * 1024

    public static func encode(_ acceptance: MeshTrustAcceptance) throws -> String {
        try acceptance.validateStructure()
        let data = try MeshCanonicalJSON.encode(acceptance)
        guard data.count <= maximumBytes else {
            throw MeshTrustInvitationValidationError.ticketTooLarge
        }
        return prefix + base64URL(data)
    }

    public static func decode(_ ticket: String) throws -> MeshTrustAcceptance {
        guard ticket.utf8.count <= maximumBytes * 2, ticket.hasPrefix(prefix) else {
            throw MeshTrustInvitationValidationError.invalidTicketEncoding
        }
        let encoded = String(ticket.dropFirst(prefix.count))
        guard let data = decodeBase64URL(encoded), data.count <= maximumBytes,
              let acceptance = try? JSONDecoder().decode(
                MeshTrustAcceptance.self, from: data
              ) else {
            throw MeshTrustInvitationValidationError.invalidTicketEncoding
        }
        try acceptance.validateStructure()
        return acceptance
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
