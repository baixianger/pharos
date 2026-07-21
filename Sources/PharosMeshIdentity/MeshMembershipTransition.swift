import Crypto
import Foundation
import PharosMeshProtocol

public enum MeshMembershipTransitionError: Error, Equatable, Sendable {
    case invalidEpoch
    case invalidRoster
    case authorNotController
    case invalidSignature
    case conflictingTransition
}

/// A controller-authorized, single-epoch membership replacement. The complete
/// roster makes revocation deterministic: every surviving device installs the
/// same next-epoch trust set, while devices omitted from it lose RPC authority.
public struct MeshMembershipTransition: Codable, Equatable, Sendable {
    public static let version = 1

    public var version: Int
    public var trustGroupID: MeshTrustGroupID
    public var previousEpoch: UInt64
    public var nextEpoch: UInt64
    public var authorDeviceID: MeshDeviceID
    public var authorEndpointID: MeshEndpointID
    public var roster: [MeshPairedDevice]
    public var signature: Data

    public init(
        version: Int = Self.version,
        trustGroupID: MeshTrustGroupID,
        previousEpoch: UInt64,
        nextEpoch: UInt64,
        authorDeviceID: MeshDeviceID,
        authorEndpointID: MeshEndpointID,
        roster: [MeshPairedDevice],
        signature: Data = Data()
    ) {
        self.version = version
        self.trustGroupID = trustGroupID
        self.previousEpoch = previousEpoch
        self.nextEpoch = nextEpoch
        self.authorDeviceID = authorDeviceID
        self.authorEndpointID = authorEndpointID
        self.roster = roster.sorted { $0.descriptor.endpointID < $1.descriptor.endpointID }
        self.signature = signature
    }

    public func validateStructure(requireSignature: Bool = true) throws {
        guard version == Self.version,
              previousEpoch > 0,
              previousEpoch < UInt64(Int64.max),
              nextEpoch == previousEpoch + 1 else {
            throw MeshMembershipTransitionError.invalidEpoch
        }
        guard roster.count <= MeshSyncVector.maximumRosterEntries else {
            throw MeshMembershipTransitionError.invalidRoster
        }
        var devices = Set<MeshDeviceID>()
        var endpoints = Set<MeshEndpointID>()
        var previousEndpoint: MeshEndpointID?
        for member in roster {
            try member.validateBinding()
            guard devices.insert(member.descriptor.id).inserted,
                  endpoints.insert(member.descriptor.endpointID).inserted,
                  previousEndpoint.map({ $0 < member.descriptor.endpointID }) ?? true else {
                throw MeshMembershipTransitionError.invalidRoster
            }
            previousEndpoint = member.descriptor.endpointID
        }
        guard roster.contains(where: {
            $0.descriptor.id == authorDeviceID &&
                $0.descriptor.endpointID == authorEndpointID &&
                $0.descriptor.roles.contains(.controller)
        }) else { throw MeshMembershipTransitionError.authorNotController }
        if requireSignature, signature.isEmpty {
            throw MeshMembershipTransitionError.invalidSignature
        }
    }

    public func canonicalSigningBytes() throws -> Data {
        var unsigned = self
        unsigned.signature = Data()
        try unsigned.validateStructure(requireSignature: false)
        return try Self.encode(unsigned)
    }

    public func canonicalBytes() throws -> Data {
        try validateStructure()
        return try Self.encode(self)
    }

    public func verifySignature() throws {
        try validateStructure()
        guard let author = roster.first(where: {
            $0.descriptor.id == authorDeviceID && $0.descriptor.endpointID == authorEndpointID
        }) else { throw MeshMembershipTransitionError.authorNotController }
        do {
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: author.signingPublicKey)
            guard key.isValidSignature(signature, for: try canonicalSigningBytes()) else {
                throw MeshMembershipTransitionError.invalidSignature
            }
        } catch let error as MeshMembershipTransitionError {
            throw error
        } catch {
            throw MeshMembershipTransitionError.invalidSignature
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dataEncodingStrategy = .base64
        return try encoder.encode(value)
    }
}

public enum MeshMembershipTransitionSigner {
    public static func sign(
        trustGroupID: MeshTrustGroupID,
        previousEpoch: UInt64,
        identity: MeshDeviceIdentity,
        roster: [MeshPairedDevice]
    ) throws -> MeshMembershipTransition {
        var transition = MeshMembershipTransition(
            trustGroupID: trustGroupID,
            previousEpoch: previousEpoch,
            nextEpoch: previousEpoch + 1,
            authorDeviceID: identity.deviceID,
            authorEndpointID: try identity.endpointID(),
            roster: roster
        )
        transition.signature = try identity.signature(for: transition.canonicalSigningBytes())
        try transition.verifySignature()
        return transition
    }
}
