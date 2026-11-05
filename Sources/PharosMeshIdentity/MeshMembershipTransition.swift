import Crypto
import Foundation
import PharosMeshProtocol

public enum MeshMembershipTransitionError: Error, Equatable, Sendable {
    case invalidEpoch
    case invalidRoster
    case authorNotController
    case invalidSignature
    case quorumRequired
    case insufficientQuorum(required: Int, actual: Int)
    case previousControllerSetMismatch
    case conflictingTransition
}

/// The immutable cryptographic identity of a controller in the epoch being
/// replaced. Display names and address tickets are deliberately excluded:
/// neither is authorization material and both may change independently.
public struct MeshMembershipControllerIdentity: Codable, Equatable, Hashable, Sendable {
    public var deviceID: MeshDeviceID
    public var endpointID: MeshEndpointID
    public var signingPublicKey: Data

    public init(
        deviceID: MeshDeviceID, endpointID: MeshEndpointID,
        signingPublicKey: Data
    ) {
        self.deviceID = deviceID
        self.endpointID = endpointID
        self.signingPublicKey = signingPublicKey
    }

    public init(_ device: MeshPairedDevice) {
        self.init(
            deviceID: device.descriptor.id,
            endpointID: device.descriptor.endpointID,
            signingPublicKey: device.signingPublicKey
        )
    }

    public func validate() throws {
        guard signingPublicKey.count == 32,
              endpointID.rawValue.utf8.count == 64 else {
            throw MeshMembershipTransitionError.invalidRoster
        }
    }
}

/// One controller vote over the proposal bytes. A controller's author
/// signature is stored in the transition's existing `signature` field; this
/// array carries the remaining quorum votes without changing v1 wire bytes.
public struct MeshMembershipApproval: Codable, Equatable, Sendable {
    public var deviceID: MeshDeviceID
    public var endpointID: MeshEndpointID
    public var signature: Data

    public init(
        deviceID: MeshDeviceID, endpointID: MeshEndpointID,
        signature: Data
    ) {
        self.deviceID = deviceID
        self.endpointID = endpointID
        self.signature = signature
    }
}

/// A controller-authorized, single-epoch membership replacement. The complete
/// roster makes revocation deterministic: every surviving device installs the
/// same next-epoch trust set, while devices omitted from it lose RPC authority.
public struct MeshMembershipTransition: Codable, Equatable, Sendable {
    public static let version = 1
    public static let quorumVersion = 2

    public var version: Int
    public var trustGroupID: MeshTrustGroupID
    public var previousEpoch: UInt64
    public var nextEpoch: UInt64
    public var authorDeviceID: MeshDeviceID
    public var authorEndpointID: MeshEndpointID
    public var roster: [MeshPairedDevice]
    /// Present only when a controller removes itself from the next epoch. Old
    /// transitions omit this field, preserving their canonical bytes.
    public var departingAuthor: MeshPairedDevice?
    /// Version-two certificate context. Nil in every legacy transition so its
    /// canonical JSON and historical signature remain byte-for-byte stable.
    public var previousControllers: [MeshMembershipControllerIdentity]?
    public var approvals: [MeshMembershipApproval]?
    public var signature: Data

    public init(
        version: Int = Self.version,
        trustGroupID: MeshTrustGroupID,
        previousEpoch: UInt64,
        nextEpoch: UInt64,
        authorDeviceID: MeshDeviceID,
        authorEndpointID: MeshEndpointID,
        roster: [MeshPairedDevice],
        departingAuthor: MeshPairedDevice? = nil,
        previousControllers: [MeshMembershipControllerIdentity]? = nil,
        approvals: [MeshMembershipApproval]? = nil,
        signature: Data = Data()
    ) {
        self.version = version
        self.trustGroupID = trustGroupID
        self.previousEpoch = previousEpoch
        self.nextEpoch = nextEpoch
        self.authorDeviceID = authorDeviceID
        self.authorEndpointID = authorEndpointID
        self.roster = roster.sorted { $0.descriptor.endpointID < $1.descriptor.endpointID }
        self.departingAuthor = departingAuthor
        self.previousControllers = previousControllers?.sorted {
            $0.endpointID < $1.endpointID
        }
        self.approvals = approvals?.sorted { $0.endpointID < $1.endpointID }
        self.signature = signature
    }

    public var signingAuthor: MeshPairedDevice? {
        roster.first {
            $0.descriptor.id == authorDeviceID &&
                $0.descriptor.endpointID == authorEndpointID
        } ?? departingAuthor
    }

    public func validateStructure(requireSignature: Bool = true) throws {
        guard version == Self.version || version == Self.quorumVersion,
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
        guard let author = signingAuthor,
              author.descriptor.id == authorDeviceID,
              author.descriptor.endpointID == authorEndpointID,
              author.descriptor.roles.contains(.controller) else {
            throw MeshMembershipTransitionError.authorNotController
        }
        try author.validateBinding()
        if let departingAuthor {
            guard !roster.contains(where: {
                $0.descriptor.id == departingAuthor.descriptor.id ||
                    $0.descriptor.endpointID == departingAuthor.descriptor.endpointID
            }), roster.contains(where: { $0.descriptor.roles.contains(.controller) }) else {
                throw MeshMembershipTransitionError.invalidRoster
            }
        }
        if version == Self.quorumVersion {
            guard let previousControllers, !previousControllers.isEmpty,
                  previousControllers.count <= MeshSyncVector.maximumRosterEntries,
                  roster.contains(where: { $0.descriptor.roles.contains(.controller) })
            else { throw MeshMembershipTransitionError.invalidRoster }
            var controllerDevices = Set<MeshDeviceID>()
            var controllerEndpoints = Set<MeshEndpointID>()
            var previousControllerEndpoint: MeshEndpointID?
            for controller in previousControllers {
                try controller.validate()
                guard controllerDevices.insert(controller.deviceID).inserted,
                      controllerEndpoints.insert(controller.endpointID).inserted,
                      previousControllerEndpoint.map({ $0 < controller.endpointID }) ?? true
                else { throw MeshMembershipTransitionError.invalidRoster }
                previousControllerEndpoint = controller.endpointID
            }
            guard previousControllers.contains(where: {
                $0.deviceID == authorDeviceID && $0.endpointID == authorEndpointID
            }) else { throw MeshMembershipTransitionError.authorNotController }

            var approvalDevices = Set<MeshDeviceID>()
            var approvalEndpoints = Set<MeshEndpointID>()
            var previousApprovalEndpoint: MeshEndpointID?
            for approval in approvals ?? [] {
                guard approval.deviceID != authorDeviceID,
                      approval.endpointID != authorEndpointID,
                      !approval.signature.isEmpty,
                      approvalDevices.insert(approval.deviceID).inserted,
                      approvalEndpoints.insert(approval.endpointID).inserted,
                      previousApprovalEndpoint.map({ $0 < approval.endpointID }) ?? true,
                      previousControllers.contains(where: {
                          $0.deviceID == approval.deviceID &&
                              $0.endpointID == approval.endpointID
                      }) else { throw MeshMembershipTransitionError.invalidSignature }
                previousApprovalEndpoint = approval.endpointID
            }
            if requireSignature {
                let actual = 1 + (approvals?.count ?? 0)
                let required = Self.quorumSize(controllerCount: previousControllers.count)
                guard actual >= required else {
                    throw MeshMembershipTransitionError.insufficientQuorum(
                        required: required, actual: actual
                    )
                }
            }
        } else if previousControllers != nil || approvals != nil {
            throw MeshMembershipTransitionError.invalidRoster
        }
        if requireSignature, signature.isEmpty {
            throw MeshMembershipTransitionError.invalidSignature
        }
    }

    public func canonicalSigningBytes() throws -> Data {
        var unsigned = self
        unsigned.signature = Data()
        if version == Self.quorumVersion { unsigned.approvals = nil }
        try unsigned.validateStructure(requireSignature: false)
        return try Self.encode(unsigned)
    }

    public func canonicalBytes() throws -> Data {
        try validateStructure()
        return try Self.encode(self)
    }

    public static func decodeCanonical(
        _ data: Data
    ) throws -> MeshMembershipTransition {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        let transition = try decoder.decode(MeshMembershipTransition.self, from: data)
        try transition.verifySignature()
        return transition
    }

    public func verifySignature() throws {
        try validateStructure()
        let authorKey: Data
        if version == Self.quorumVersion {
            guard let author = previousControllers?.first(where: {
                $0.deviceID == authorDeviceID && $0.endpointID == authorEndpointID
            }) else { throw MeshMembershipTransitionError.authorNotController }
            authorKey = author.signingPublicKey
        } else {
            guard let author = signingAuthor else {
                throw MeshMembershipTransitionError.authorNotController
            }
            authorKey = author.signingPublicKey
        }
        do {
            let bytes = try canonicalSigningBytes()
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: authorKey)
            guard key.isValidSignature(signature, for: bytes) else {
                throw MeshMembershipTransitionError.invalidSignature
            }
            if version == Self.quorumVersion {
                for approval in approvals ?? [] {
                    guard let controller = previousControllers?.first(where: {
                        $0.deviceID == approval.deviceID &&
                            $0.endpointID == approval.endpointID
                    }) else { throw MeshMembershipTransitionError.invalidSignature }
                    let approvalKey = try Curve25519.Signing.PublicKey(
                        rawRepresentation: controller.signingPublicKey
                    )
                    guard approvalKey.isValidSignature(approval.signature, for: bytes) else {
                        throw MeshMembershipTransitionError.invalidSignature
                    }
                }
            }
        } catch let error as MeshMembershipTransitionError {
            throw error
        } catch {
            throw MeshMembershipTransitionError.invalidSignature
        }
    }

    public static func quorumSize(controllerCount: Int) -> Int {
        controllerCount / 2 + 1
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
        roster: [MeshPairedDevice],
        departingAuthor: MeshPairedDevice? = nil
    ) throws -> MeshMembershipTransition {
        var transition = MeshMembershipTransition(
            trustGroupID: trustGroupID,
            previousEpoch: previousEpoch,
            nextEpoch: previousEpoch + 1,
            authorDeviceID: identity.deviceID,
            authorEndpointID: try identity.endpointID(),
            roster: roster,
            departingAuthor: departingAuthor
        )
        transition.signature = try identity.signature(for: transition.canonicalSigningBytes())
        try transition.verifySignature()
        return transition
    }

    /// Creates the author-signed portion of a v2 proposal. It is intentionally
    /// not a committable transition until `certify` attaches a majority.
    public static func propose(
        trustGroupID: MeshTrustGroupID,
        previousEpoch: UInt64,
        identity: MeshDeviceIdentity,
        previousControllers: [MeshMembershipControllerIdentity],
        roster: [MeshPairedDevice],
        departingAuthor: MeshPairedDevice? = nil
    ) throws -> MeshMembershipTransition {
        var proposal = MeshMembershipTransition(
            version: MeshMembershipTransition.quorumVersion,
            trustGroupID: trustGroupID,
            previousEpoch: previousEpoch,
            nextEpoch: previousEpoch + 1,
            authorDeviceID: identity.deviceID,
            authorEndpointID: try identity.endpointID(),
            roster: roster,
            departingAuthor: departingAuthor,
            previousControllers: previousControllers,
            approvals: nil
        )
        proposal.signature = try identity.signature(
            for: proposal.canonicalSigningBytes()
        )
        try proposal.verifyAuthorSignature()
        return proposal
    }

    public static func approve(
        _ proposal: MeshMembershipTransition,
        with identity: MeshDeviceIdentity
    ) throws -> MeshMembershipApproval {
        let endpointID = try identity.endpointID()
        guard proposal.version == MeshMembershipTransition.quorumVersion,
              proposal.previousControllers?.contains(where: {
                  $0.deviceID == identity.deviceID &&
                      $0.endpointID == endpointID
              }) == true else {
            throw MeshMembershipTransitionError.authorNotController
        }
        try proposal.verifyAuthorSignature()
        return MeshMembershipApproval(
            deviceID: identity.deviceID,
            endpointID: endpointID,
            signature: try identity.signature(
                for: proposal.canonicalSigningBytes()
            )
        )
    }

    public static func certify(
        _ proposal: MeshMembershipTransition,
        approvals: [MeshMembershipApproval]
    ) throws -> MeshMembershipTransition {
        guard proposal.version == MeshMembershipTransition.quorumVersion else {
            throw MeshMembershipTransitionError.invalidEpoch
        }
        var certified = proposal
        certified.approvals = approvals.sorted { $0.endpointID < $1.endpointID }
        try certified.verifySignature()
        return certified
    }
}

public extension MeshMembershipTransition {
    func verifyAuthorSignature() throws {
        try validateStructure(requireSignature: false)
        guard !signature.isEmpty,
              let author = previousControllers?.first(where: {
                  $0.deviceID == authorDeviceID && $0.endpointID == authorEndpointID
              }) else { throw MeshMembershipTransitionError.invalidSignature }
        do {
            let key = try Curve25519.Signing.PublicKey(
                rawRepresentation: author.signingPublicKey
            )
            guard key.isValidSignature(signature, for: try canonicalSigningBytes()) else {
                throw MeshMembershipTransitionError.invalidSignature
            }
        } catch let error as MeshMembershipTransitionError {
            throw error
        } catch {
            throw MeshMembershipTransitionError.invalidSignature
        }
    }
}
