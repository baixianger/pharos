import Crypto
import Foundation
import PharosMeshProtocol

public enum MeshTrustPairingError: Error, Equatable, Sendable {
    case endpointKeyMismatch
    case invalidSignature
    case invitationNotYetValid
    case invitationExpired
    case invitationUnknown
    case invitationAlreadyConsumed
    case invitationRecordMismatch
    case acceptanceMismatch
    case duplicateInvitation
    case deviceAlreadyTrusted
    case membershipEpochMismatch
}

public struct MeshInvitationUseRecord: Codable, Equatable, Sendable {
    public var trustGroupID: MeshTrustGroupID
    public var membershipEpoch: UInt64
    public var invitationDigest: Data
    public var nonceDigest: Data
    public var expiresAtMilliseconds: Int64

    public init(trustGroupID: MeshTrustGroupID, membershipEpoch: UInt64,
                invitationDigest: Data,
                nonceDigest: Data, expiresAtMilliseconds: Int64) {
        self.trustGroupID = trustGroupID
        self.membershipEpoch = membershipEpoch
        self.invitationDigest = invitationDigest
        self.nonceDigest = nonceDigest
        self.expiresAtMilliseconds = expiresAtMilliseconds
    }

    public func validate() throws {
        guard membershipEpoch > 0, membershipEpoch <= UInt64(Int64.max),
              invitationDigest.count == 32, nonceDigest.count == 32 else {
            throw MeshTrustPairingError.invitationRecordMismatch
        }
    }
}

public enum MeshInvitationConsumption: Equatable, Sendable {
    case consumed
    case unknown
    case alreadyConsumed
    case mismatch
    case expired
    case deviceAlreadyTrusted
    case membershipEpochMismatch
}

/// The production implementation is backed by the replica SQLite store. The
/// memory implementation below is limited to isolated tests and previews.
public protocol MeshInvitationUseStore: Sendable {
    func register(_ record: MeshInvitationUseRecord) async throws
    func consume(_ record: MeshInvitationUseRecord, accepting device: MeshPairedDevice,
                 at milliseconds: Int64) async throws -> MeshInvitationConsumption
}

public actor MeshMemoryInvitationUseStore: MeshInvitationUseStore {
    private struct State: Sendable {
        var record: MeshInvitationUseRecord
        var consumed = false
    }
    private var records: [Data: State] = [:]
    private var trustedDevices: [MeshTrustGroupID: [MeshDeviceID: MeshPairedDevice]] = [:]

    public init() {}

    public func register(_ record: MeshInvitationUseRecord) throws {
        try record.validate()
        guard records[record.nonceDigest] == nil else {
            throw MeshTrustPairingError.duplicateInvitation
        }
        records[record.nonceDigest] = State(record: record)
    }

    public func consume(_ record: MeshInvitationUseRecord, accepting device: MeshPairedDevice,
                        at milliseconds: Int64)
        throws -> MeshInvitationConsumption {
        try record.validate()
        try device.validateBinding()
        guard var state = records[record.nonceDigest] else { return .unknown }
        guard state.record == record else { return .mismatch }
        guard !state.consumed else { return .alreadyConsumed }
        guard milliseconds < state.record.expiresAtMilliseconds else { return .expired }
        let groupDevices = trustedDevices[record.trustGroupID]?.values ?? [:].values
        guard !groupDevices.contains(where: {
            $0.descriptor.id == device.descriptor.id ||
                $0.descriptor.endpointID == device.descriptor.endpointID
        }) else {
            return .deviceAlreadyTrusted
        }
        state.consumed = true
        records[record.nonceDigest] = state
        trustedDevices[record.trustGroupID, default: [:]][device.descriptor.id] = device
        return .consumed
    }

    public func trustedDevice(in group: MeshTrustGroupID,
                              id: MeshDeviceID) -> MeshPairedDevice? {
        trustedDevices[group]?[id]
    }
}

public struct MeshPairedDevice: Codable, Equatable, Sendable {
    public var descriptor: MeshDeviceDescriptor
    public var signingPublicKey: Data
    public var addressTicket: String

    public init(descriptor: MeshDeviceDescriptor, signingPublicKey: Data,
                addressTicket: String) {
        self.descriptor = descriptor
        self.signingPublicKey = signingPublicKey
        self.addressTicket = addressTicket
    }

    public func validateBinding() throws {
        let expectedEndpoint = signingPublicKey.map { String(format: "%02x", $0) }.joined()
        guard signingPublicKey.count == 32,
              descriptor.endpointID.rawValue == expectedEndpoint else {
            throw MeshTrustPairingError.endpointKeyMismatch
        }
        let trimmedName = descriptor.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard descriptor.protocolVersion == MeshTrustAcceptance.version,
              !descriptor.roles.isEmpty,
              !trimmedName.isEmpty,
              descriptor.displayName == trimmedName,
              descriptor.displayName.utf8.count <= 128,
              !descriptor.displayName.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
              ),
              !addressTicket.isEmpty,
              addressTicket.utf8.count <= MeshTrustInvitation.maximumAddressTicketBytes else {
            throw MeshTrustPairingError.acceptanceMismatch
        }
    }
}

public struct MeshTrustPairingService: Sendable {
    public static let defaultLifetimeMilliseconds: Int64 = 5 * 60 * 1_000
    public static let maximumClockSkewMilliseconds: Int64 = 5 * 60 * 1_000

    private let identity: MeshDeviceIdentity
    private let invitationStore: any MeshInvitationUseStore

    public init(identity: MeshDeviceIdentity, invitationStore: any MeshInvitationUseStore) {
        self.identity = identity
        self.invitationStore = invitationStore
    }

    public func issueInvitation(
        trustGroupID: MeshTrustGroupID,
        membershipEpoch: UInt64,
        inviterAddressTicket: String,
        requestedRoles: Set<MeshDeviceRole>,
        now: Date = Date(),
        lifetimeMilliseconds: Int64 = Self.defaultLifetimeMilliseconds
    ) async throws -> MeshTrustInvitation {
        let issuedAt = milliseconds(now)
        guard lifetimeMilliseconds > 0,
              lifetimeMilliseconds <= MeshTrustInvitation.maximumLifetimeMilliseconds else {
            throw MeshTrustInvitationValidationError.invalidLifetime
        }
        let (expiresAt, overflow) = issuedAt.addingReportingOverflow(lifetimeMilliseconds)
        guard !overflow else { throw MeshTrustInvitationValidationError.invalidLifetime }
        var invitation = MeshTrustInvitation(
            trustGroupID: trustGroupID,
            membershipEpoch: membershipEpoch,
            inviterDeviceID: identity.deviceID,
            inviterEndpointID: try identity.endpointID(),
            inviterAddressTicket: inviterAddressTicket,
            inviterSigningPublicKey: try identity.signingPublicKeyBytes(),
            requestedRoles: requestedRoles,
            issuedAtMilliseconds: issuedAt,
            expiresAtMilliseconds: expiresAt,
            nonce: secureRandomBytes(count: 32)
        )
        try invitation.validateStructure(requireSignature: false)
        invitation.signature = try identity.signature(for: invitation.canonicalSigningBytes())
        try verifyInvitation(invitation, now: now)
        try await invitationStore.register(useRecord(for: invitation))
        return invitation
    }

    public func createAcceptance(
        for invitation: MeshTrustInvitation,
        acceptingAddressTicket: String,
        displayName: String,
        now: Date = Date()
    ) throws -> MeshTrustAcceptance {
        try verifyInvitation(invitation, now: now)
        var acceptance = MeshTrustAcceptance(
            trustGroupID: invitation.trustGroupID,
            membershipEpoch: invitation.membershipEpoch,
            invitationDigest: try digest(invitation.canonicalBytes()),
            invitationNonceDigest: digest(invitation.nonce),
            acceptingDeviceID: identity.deviceID,
            acceptingEndpointID: try identity.endpointID(),
            acceptingAddressTicket: acceptingAddressTicket,
            acceptingSigningPublicKey: try identity.signingPublicKeyBytes(),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            roles: Set(invitation.requestedRoles),
            acceptedAtMilliseconds: milliseconds(now)
        )
        try acceptance.validateStructure(requireSignature: false)
        acceptance.signature = try identity.signature(for: acceptance.canonicalSigningBytes())
        try verifyAcceptance(acceptance, for: invitation, now: now)
        return acceptance
    }

    public func redeem(
        _ acceptance: MeshTrustAcceptance,
        for invitation: MeshTrustInvitation,
        now: Date = Date()
    ) async throws -> MeshPairedDevice {
        try verifyInvitation(invitation, now: now)
        try verifyAcceptance(acceptance, for: invitation, now: now)
        let record = try useRecord(for: invitation)
        let pairedDevice = MeshPairedDevice(
            descriptor: MeshDeviceDescriptor(
                id: acceptance.acceptingDeviceID,
                endpointID: acceptance.acceptingEndpointID,
                displayName: acceptance.displayName,
                roles: Set(acceptance.roles),
                protocolVersion: acceptance.protocolVersion
            ),
            signingPublicKey: acceptance.acceptingSigningPublicKey,
            addressTicket: acceptance.acceptingAddressTicket
        )
        switch try await invitationStore.consume(
            record, accepting: pairedDevice, at: milliseconds(now)
        ) {
        case .consumed: break
        case .unknown: throw MeshTrustPairingError.invitationUnknown
        case .alreadyConsumed: throw MeshTrustPairingError.invitationAlreadyConsumed
        case .mismatch: throw MeshTrustPairingError.invitationRecordMismatch
        case .expired: throw MeshTrustPairingError.invitationExpired
        case .deviceAlreadyTrusted: throw MeshTrustPairingError.deviceAlreadyTrusted
        case .membershipEpochMismatch: throw MeshTrustPairingError.membershipEpochMismatch
        }
        return pairedDevice
    }

    public func verifyInvitation(_ invitation: MeshTrustInvitation, now: Date = Date()) throws {
        try invitation.validateStructure()
        let nowMilliseconds = milliseconds(now)
        guard isNotTooFarInFuture(invitation.issuedAtMilliseconds, relativeTo: nowMilliseconds) else {
            throw MeshTrustPairingError.invitationNotYetValid
        }
        guard nowMilliseconds < invitation.expiresAtMilliseconds else {
            throw MeshTrustPairingError.invitationExpired
        }
        guard endpointID(for: invitation.inviterSigningPublicKey) == invitation.inviterEndpointID else {
            throw MeshTrustPairingError.endpointKeyMismatch
        }
        try verify(
            signature: invitation.signature,
            data: invitation.canonicalSigningBytes(),
            publicKey: invitation.inviterSigningPublicKey
        )
    }

    public func verifyAcceptance(_ acceptance: MeshTrustAcceptance,
                                 for invitation: MeshTrustInvitation,
                                 now: Date = Date()) throws {
        try verifyInvitation(invitation, now: now)
        try acceptance.validateStructure()
        let expectedInvitationDigest = try digest(invitation.canonicalBytes())
        guard acceptance.trustGroupID == invitation.trustGroupID,
              acceptance.membershipEpoch == invitation.membershipEpoch,
              acceptance.invitationDigest == expectedInvitationDigest,
              acceptance.invitationNonceDigest == digest(invitation.nonce),
              acceptance.roles == invitation.requestedRoles,
              isNotTooFarBefore(acceptance.acceptedAtMilliseconds,
                                lowerBound: invitation.issuedAtMilliseconds),
              acceptance.acceptedAtMilliseconds < invitation.expiresAtMilliseconds else {
            throw MeshTrustPairingError.acceptanceMismatch
        }
        let nowMilliseconds = milliseconds(now)
        guard isNotTooFarInFuture(acceptance.acceptedAtMilliseconds,
                                  relativeTo: nowMilliseconds) else {
            throw MeshTrustPairingError.acceptanceMismatch
        }
        guard endpointID(for: acceptance.acceptingSigningPublicKey) == acceptance.acceptingEndpointID else {
            throw MeshTrustPairingError.endpointKeyMismatch
        }
        try verify(
            signature: acceptance.signature,
            data: acceptance.canonicalSigningBytes(),
            publicKey: acceptance.acceptingSigningPublicKey
        )
    }

    private func useRecord(for invitation: MeshTrustInvitation) throws -> MeshInvitationUseRecord {
        MeshInvitationUseRecord(
            trustGroupID: invitation.trustGroupID,
            membershipEpoch: invitation.membershipEpoch,
            invitationDigest: try digest(invitation.canonicalBytes()),
            nonceDigest: digest(invitation.nonce),
            expiresAtMilliseconds: invitation.expiresAtMilliseconds
        )
    }

    private func verify(signature: Data, data: Data, publicKey: Data) throws {
        let key: Curve25519.Signing.PublicKey
        do { key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey) }
        catch { throw MeshTrustPairingError.endpointKeyMismatch }
        guard key.isValidSignature(signature, for: data) else {
            throw MeshTrustPairingError.invalidSignature
        }
    }

    private func endpointID(for publicKey: Data) -> MeshEndpointID? {
        MeshEndpointID(rawValue: publicKey.map { String(format: "%02x", $0) }.joined())
    }

    private func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    private func isNotTooFarInFuture(_ value: Int64, relativeTo reference: Int64) -> Bool {
        guard value > reference else { return true }
        let (difference, overflow) = value.subtractingReportingOverflow(reference)
        return !overflow && difference <= Self.maximumClockSkewMilliseconds
    }

    private func isNotTooFarBefore(_ value: Int64, lowerBound: Int64) -> Bool {
        guard value < lowerBound else { return true }
        let (difference, overflow) = lowerBound.subtractingReportingOverflow(value)
        return !overflow && difference <= Self.maximumClockSkewMilliseconds
    }

    private func secureRandomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
