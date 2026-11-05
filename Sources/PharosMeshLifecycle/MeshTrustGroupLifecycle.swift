import Foundation
import PharosMeshIdentity
import PharosMeshIroh
import PharosMeshProtocol
import PharosMeshReplica

public enum MeshExistingGroupDisposition: Equatable, Sendable {
    case archive
    case leave
}

public enum MeshTrustGroupLifecycleError: Error, Equatable, Sendable {
    case noActiveTrustGroup
    case missingMembershipEpoch
    case noSurvivingController
    case departureNotAcknowledged
    case pairingConfirmationMismatch
    case archivedReplicaNeedsReset
    case membershipQuorumUnavailable(required: Int, received: Int)
    case membershipProposalConflict(required: Int, received: Int)
}

extension MeshTrustGroupLifecycleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noActiveTrustGroup:
            "This device is not currently connected to a Mesh."
        case .missingMembershipEpoch:
            "The current Mesh membership record is incomplete. Sync with another Mesh admin device and try again."
        case .noSurvivingController:
            "Add another Mesh admin device before leaving. A replica-only device cannot confirm the membership change."
        case .departureNotAcknowledged:
            "No surviving Mesh admin device confirmed the leave request. Bring another admin device online and try again."
        case .pairingConfirmationMismatch:
            "The invitation was answered for a different device. Create a new invitation and try again."
        case .archivedReplicaNeedsReset:
            "This archived replica cannot verify the current membership chain. Reset this device's local Mesh data and identity, then scan a fresh invitation."
        case .membershipQuorumUnavailable(let required, let received):
            "This membership change needs \(required) Mesh admin approvals, but only \(received) are currently available. Bring another admin device online and try again."
        case .membershipProposalConflict(let required, let received):
            "Another Mesh admin has already approved a different membership change for this epoch. No membership change was applied. Bring another current Mesh admin online, then retry the intended change so \(required) approvals can safely choose one proposal (currently \(received))."
        }
    }
}

public struct MeshTrustGroupLeaveResult: Equatable, Sendable {
    public var archivedGroupID: MeshTrustGroupID
    public var nextMembershipEpoch: UInt64?
    public var acknowledgements: Int

    public init(
        archivedGroupID: MeshTrustGroupID,
        nextMembershipEpoch: UInt64?,
        acknowledgements: Int
    ) {
        self.archivedGroupID = archivedGroupID
        self.nextMembershipEpoch = nextMembershipEpoch
        self.acknowledgements = acknowledgements
    }
}

public struct MeshCertifiedPairingResult: Sendable {
    public var pairedDevice: MeshPairedDevice
    public var transition: MeshMembershipTransition

    public init(
        pairedDevice: MeshPairedDevice,
        transition: MeshMembershipTransition
    ) {
        self.pairedDevice = pairedDevice
        self.transition = transition
    }
}

private enum MeshMembershipVoteAttempt: Sendable {
    case approval(MeshMembershipApproval?)
    case conflict
    case unavailable
}

/// Shared create, join, archive, and signed-departure behavior used by the
/// macOS app, iOS app, and CLI-facing layers. Product UI owns confirmation;
/// this type owns the security ordering and persistent state transitions.
public enum MeshTrustGroupLifecycle {
    /// Quorum transitions are rare control-plane operations and must cover a
    /// cold relay connection. Production Mac-to-Mac paths have measured above
    /// four seconds before the first authenticated response.
    public static let membershipRequestTimeoutMilliseconds = 10_000

    /// Follow the controller-signed membership chain one epoch at a time.
    /// Normal replica sync requires equal epochs, so this recovery path is what
    /// lets an offline retained device become current again before syncing or
    /// publishing its own leave transition.
    @discardableResult
    public static func catchUpMembership(
        replica: MeshLocalReplica, runtime: IrohEndpointRuntime,
        maximumTransitions: Int = 32
    ) async throws -> Int {
        guard let group = try replica.activeTrustGroup() else {
            throw MeshTrustGroupLifecycleError.noActiveTrustGroup
        }
        return try await catchUpMembership(
            replica: replica, runtime: runtime, group: group,
            bootstrapPeers: [], maximumTransitions: maximumTransitions
        )
    }

    /// Recovers an archived replica before pairing it back into the same Mesh.
    /// The signed invitation supplies a current, authenticated bootstrap
    /// address, while every fetched transition is still verified against the
    /// replica's existing membership chain before it is applied.
    @discardableResult
    public static func catchUpArchivedMembership(
        replica: MeshLocalReplica, runtime: IrohEndpointRuntime,
        invitation: MeshTrustInvitation, maximumTransitions: Int = 32
    ) async throws -> Int {
        try await catchUpMembership(
            replica: replica, runtime: runtime,
            group: invitation.trustGroupID,
            bootstrapPeers: [MeshIrohEndpointAddress(
                endpointID: invitation.inviterEndpointID,
                ticket: invitation.inviterAddressTicket
            )],
            maximumTransitions: maximumTransitions
        )
    }

    private static func catchUpMembership(
        replica: MeshLocalReplica, runtime: IrohEndpointRuntime,
        group: MeshTrustGroupID,
        bootstrapPeers: [MeshIrohEndpointAddress],
        maximumTransitions: Int
    ) async throws -> Int {
        var applied = 0
        for _ in 0..<maximumTransitions {
            guard let epoch = try await replica.store.membershipEpoch(for: group) else {
                throw MeshTrustGroupLifecycleError.missingMembershipEpoch
            }
            let peers = try await replica.store.trustedDevices(
                in: group, membershipEpoch: epoch
            )
            var addresses = bootstrapPeers
            addresses.append(contentsOf: peers.compactMap { peer in
                guard peer.descriptor.id != replica.identity.deviceID else { return nil }
                return MeshIrohEndpointAddress(
                    endpointID: peer.descriptor.endpointID,
                    ticket: peer.addressTicket
                )
            })
            var seenEndpoints: Set<MeshEndpointID> = []
            var next: MeshMembershipTransition?
            for address in addresses where seenEndpoints.insert(address.endpointID).inserted {
                let transport = IrohMeshTransport(
                    runtime: runtime, remote: address
                )
                do {
                    if let candidate = try await MeshReplicaRPCClient(
                        transport: transport
                    ).nextMembershipTransition(for: group, after: epoch) {
                        next = candidate
                        break
                    }
                } catch { continue }
            }
            guard let next else { return applied }
            try await replica.store.applyMembershipTransition(
                next, localIdentity: replica.identity,
                localAuthorRoles: try replica.activeRoles()
            )
            applied += 1
            try replica.reconcileActiveMembership(after: next)
            if try replica.activeTrustGroup() != group {
                return applied
            }
        }
        return applied
    }

    public static func createPersonalMesh(
        replica: MeshLocalReplica
    ) async throws -> MeshTrustGroupID {
        try await replica.ensureActiveTrustGroup()
    }

    /// Creates a v2 membership proposal, durably consumes the local
    /// controller's vote, and collects enough previous-epoch controller votes
    /// to form a majority certificate. No fixed leader is involved.
    public static func certifyMembershipTransition(
        replica: MeshLocalReplica,
        runtime: IrohEndpointRuntime,
        group: MeshTrustGroupID,
        previousEpoch: UInt64,
        roster: [MeshPairedDevice],
        departingAuthor: MeshPairedDevice? = nil
    ) async throws -> MeshMembershipTransition {
        let roles = try replica.activeRoles()
        guard roles.contains(.controller) else {
            throw MeshMembershipTransitionError.authorNotController
        }
        let peers = try await replica.store.trustedDevices(
            in: group, membershipEpoch: previousEpoch
        )
        let localController = MeshMembershipControllerIdentity(
            deviceID: replica.identity.deviceID,
            endpointID: try replica.identity.endpointID(),
            signingPublicKey: try replica.identity.signingPublicKeyBytes()
        )
        var controllerByEndpoint: [MeshEndpointID: MeshMembershipControllerIdentity] = [
            localController.endpointID: localController,
        ]
        for peer in peers where peer.descriptor.roles.contains(.controller) {
            let controller = MeshMembershipControllerIdentity(peer)
            controllerByEndpoint[controller.endpointID] = controller
        }
        let controllers = controllerByEndpoint.values.sorted {
            $0.endpointID < $1.endpointID
        }
        let freshProposal = try MeshMembershipTransitionSigner.propose(
            trustGroupID: group, previousEpoch: previousEpoch,
            identity: replica.identity,
            previousControllers: controllers, roster: roster,
            departingAuthor: departingAuthor
        )
        let proposal: MeshMembershipTransition
        if let pending = try await replica.store.pendingMembershipProposal(
            for: group, previousEpoch: previousEpoch,
            authoredBy: replica.identity
        ) {
            guard sameMembershipAuthorizationIntent(
                pending, freshProposal
            ) else {
                throw MeshMembershipTransitionError.conflictingTransition
            }
            proposal = pending
        } else {
            proposal = freshProposal
        }
        _ = try await replica.store.recordMembershipVote(
            for: proposal, localIdentity: replica.identity,
            localAuthorRoles: roles
        )

        let required = MeshMembershipTransition.quorumSize(
            controllerCount: controllers.count
        )
        var approvals: [MeshMembershipApproval] = []
        var observedConflictingVote = false
        if required > 1 {
            await withTaskGroup(
                of: MeshMembershipVoteAttempt.self
            ) { tasks in
                for peer in peers
                where peer.descriptor.roles.contains(.controller) {
                    tasks.addTask {
                        let transport = IrohMeshTransport(
                            runtime: runtime,
                            remote: MeshIrohEndpointAddress(
                                endpointID: peer.descriptor.endpointID,
                                ticket: peer.addressTicket
                            )
                        )
                        do {
                            return .approval(
                                try await MeshReplicaRPCClient(
                                    transport: transport,
                                    requestTimeoutMilliseconds:
                                        membershipRequestTimeoutMilliseconds
                                ).requestMembershipVote(for: proposal)
                            )
                        } catch MeshReplicaRPCError.remoteFailure(
                            "membership-vote-conflict"
                        ) {
                            return .conflict
                        } catch {
                            return .unavailable
                        }
                    }
                }
                for await attempt in tasks {
                    switch attempt {
                    case .approval(let approval?):
                        if !approvals.contains(where: {
                            $0.endpointID == approval.endpointID
                        }) {
                            approvals.append(approval)
                        }
                    case .conflict:
                        observedConflictingVote = true
                    case .approval(nil), .unavailable:
                        break
                    }
                    if 1 + approvals.count >= required {
                        tasks.cancelAll()
                        break
                    }
                }
            }
        }
        guard 1 + approvals.count >= required else {
            if observedConflictingVote {
                throw MeshTrustGroupLifecycleError.membershipProposalConflict(
                    required: required, received: 1 + approvals.count
                )
            }
            throw MeshTrustGroupLifecycleError.membershipQuorumUnavailable(
                required: required, received: 1 + approvals.count
            )
        }
        return try MeshMembershipTransitionSigner.certify(
            proposal, approvals: approvals
        )
    }

    private static func sameMembershipAuthorizationIntent(
        _ lhs: MeshMembershipTransition,
        _ rhs: MeshMembershipTransition
    ) -> Bool {
        let departingMatches: Bool
        switch (lhs.departingAuthor, rhs.departingAuthor) {
        case (nil, nil):
            departingMatches = true
        case let (left?, right?):
            departingMatches = left.hasSameCryptographicIdentity(as: right) &&
                left.descriptor.roles == right.descriptor.roles &&
                left.descriptor.protocolVersion == right.descriptor.protocolVersion
        default:
            departingMatches = false
        }
        guard departingMatches,
              lhs.version == rhs.version,
              lhs.trustGroupID == rhs.trustGroupID,
              lhs.previousEpoch == rhs.previousEpoch,
              lhs.nextEpoch == rhs.nextEpoch,
              lhs.authorDeviceID == rhs.authorDeviceID,
              lhs.authorEndpointID == rhs.authorEndpointID,
              lhs.previousControllers == rhs.previousControllers,
              lhs.roster.count == rhs.roster.count
        else { return false }
        let rightByDevice = Dictionary(
            uniqueKeysWithValues: rhs.roster.map { ($0.descriptor.id, $0) }
        )
        return lhs.roster.allSatisfy { left in
            guard let right = rightByDevice[left.descriptor.id] else {
                return false
            }
            return left.hasSameCryptographicIdentity(as: right) &&
                left.descriptor.roles == right.descriptor.roles &&
                left.descriptor.protocolVersion == right.descriptor.protocolVersion
        }
    }

    public static func archiveCurrentMesh(
        replica: MeshLocalReplica
    ) throws -> MeshTrustGroupID {
        guard let group = try replica.activeTrustGroup() else {
            throw MeshTrustGroupLifecycleError.noActiveTrustGroup
        }
        try replica.deactivateActiveTrustGroup()
        return group
    }

    /// Redeems a one-time invitation and adds the joining device only through
    /// a majority-certified next-epoch roster. The invitation is consumed
    /// before vote collection, so a failed quorum is fail-closed and requires
    /// the admin to issue a fresh link.
    public static func certifyJoiningDevice(
        invitation: MeshTrustInvitation,
        acceptance: MeshTrustAcceptance,
        replica: MeshLocalReplica,
        runtime: IrohEndpointRuntime,
        localAddress: MeshIrohEndpointAddress,
        displayName: String
    ) async throws -> MeshCertifiedPairingResult {
        let pairingService = MeshTrustPairingService(
            identity: replica.identity, invitationStore: replica.store
        )
        try pairingService.verifyInvitation(invitation)
        try pairingService.verifyAcceptance(acceptance, for: invitation)
        let acceptingDevice = MeshPairedDevice(
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
        try acceptingDevice.validateBinding()

        guard let group = try replica.activeTrustGroup(),
              group == invitation.trustGroupID,
              let epoch = try await replica.store.membershipEpoch(for: group)
        else { throw MeshTrustPairingError.membershipEpochMismatch }

        // The inviter may have durably committed the certified transition just
        // before the response was lost or timed out. A retry from the same
        // signature-bound device must return that immutable transition instead
        // of turning a successful remote commit into an unrecoverable
        // "invitation already consumed" failure.
        let (recoveryEpoch, recoveryOverflow) =
            invitation.membershipEpoch.addingReportingOverflow(1)
        if !recoveryOverflow, epoch == recoveryEpoch,
           let transition = try await replica.store.nextMembershipTransition(
               for: group, after: invitation.membershipEpoch
           ),
           transition.authorDeviceID == invitation.inviterDeviceID,
           transition.authorEndpointID == invitation.inviterEndpointID,
           let certifiedDevice = transition.roster.first(where: {
               $0.hasSameCryptographicIdentity(as: acceptingDevice)
           }),
           certifiedDevice.descriptor.roles == acceptingDevice.descriptor.roles,
           certifiedDevice.descriptor.protocolVersion ==
               acceptingDevice.descriptor.protocolVersion {
            return MeshCertifiedPairingResult(
                pairedDevice: certifiedDevice, transition: transition
            )
        }
        guard epoch == invitation.membershipEpoch else {
            throw MeshTrustPairingError.membershipEpochMismatch
        }
        let localEndpointID = try replica.identity.endpointID()
        guard try replica.activeRoles().contains(.controller),
              invitation.inviterDeviceID == replica.identity.deviceID,
              invitation.inviterEndpointID == localEndpointID
        else { throw MeshMembershipTransitionError.authorNotController }

        let paired = try await pairingService.redeemForMembershipTransition(
            acceptance, for: invitation
        )
        let peers = try await replica.store.trustedDevices(
            in: group, membershipEpoch: epoch
        )
        let localMember = MeshPairedDevice(
            descriptor: MeshDeviceDescriptor(
                id: replica.identity.deviceID,
                endpointID: try replica.identity.endpointID(),
                displayName: displayName,
                roles: try replica.activeRoles()
            ),
            signingPublicKey: try replica.identity.signingPublicKeyBytes(),
            addressTicket: localAddress.ticket
        )
        let retainedPeers = peers.filter {
            $0.descriptor.id != paired.descriptor.id &&
                $0.descriptor.endpointID != paired.descriptor.endpointID &&
                $0.descriptor.id != localMember.descriptor.id
        }
        let transition = try await certifyMembershipTransition(
            replica: replica, runtime: runtime, group: group,
            previousEpoch: epoch,
            roster: retainedPeers + [localMember, paired]
        )
        // Commit locally before replying. Existing peers recover the signed
        // next-epoch transition through their normal membership anti-entropy.
        // Waiting here for every retained peer (including offline phones)
        // previously exhausted the joiner's request timeout after the inviter
        // had already committed, creating a half-paired device.
        try await replica.store.applyMembershipTransition(
            transition, localIdentity: replica.identity,
            localAuthorRoles: try replica.activeRoles()
        )
        return MeshCertifiedPairingResult(
            pairedDevice: paired, transition: transition
        )
    }

    public static func leaveCurrentMesh(
        replica: MeshLocalReplica,
        runtime: IrohEndpointRuntime,
        localAddress: MeshIrohEndpointAddress,
        displayName: String
    ) async throws -> MeshTrustGroupLeaveResult {
        _ = try await catchUpMembership(replica: replica, runtime: runtime)
        guard let group = try replica.activeTrustGroup() else {
            throw MeshTrustGroupLifecycleError.noActiveTrustGroup
        }
        guard let epoch = try await replica.store.membershipEpoch(for: group) else {
            throw MeshTrustGroupLifecycleError.missingMembershipEpoch
        }
        let peers = try await replica.store.trustedDevices(
            in: group, membershipEpoch: epoch
        )
        guard !peers.isEmpty else {
            try replica.deactivateActiveTrustGroup()
            return MeshTrustGroupLeaveResult(
                archivedGroupID: group,
                nextMembershipEpoch: nil,
                acknowledgements: 0
            )
        }
        let controllers = peers.filter {
            $0.descriptor.roles.contains(.controller)
        }
        guard !controllers.isEmpty else {
            throw MeshTrustGroupLifecycleError.noSurvivingController
        }
        let localMember = MeshPairedDevice(
            descriptor: MeshDeviceDescriptor(
                id: replica.identity.deviceID,
                endpointID: try replica.identity.endpointID(),
                displayName: displayName,
                roles: try replica.activeRoles()
            ),
            signingPublicKey: try replica.identity.signingPublicKeyBytes(),
            addressTicket: localAddress.ticket
        )
        let transition = try await certifyMembershipTransition(
            replica: replica, runtime: runtime, group: group,
            previousEpoch: epoch, roster: peers,
            departingAuthor: localMember
        )
        var acknowledgements = 0
        var controllerAcknowledged = false
        for peer in peers {
            let transport = IrohMeshTransport(
                runtime: runtime,
                remote: MeshIrohEndpointAddress(
                    endpointID: peer.descriptor.endpointID,
                    ticket: peer.addressTicket
                )
            )
            do {
                try await MeshReplicaRPCClient(transport: transport)
                    .applyMembershipTransition(transition)
                acknowledgements += 1
                if peer.descriptor.roles.contains(.controller) {
                    controllerAcknowledged = true
                }
            } catch {
                continue
            }
        }
        guard controllerAcknowledged else {
            throw MeshTrustGroupLifecycleError.departureNotAcknowledged
        }
        try await replica.store.applyMembershipTransition(
            transition, localIdentity: replica.identity,
            localAuthorRoles: try replica.activeRoles()
        )
        try replica.deactivateActiveTrustGroup()
        return MeshTrustGroupLeaveResult(
            archivedGroupID: group,
            nextMembershipEpoch: transition.nextEpoch,
            acknowledgements: acknowledgements
        )
    }

    public static func join(
        _ invitation: MeshTrustInvitation,
        replica: MeshLocalReplica,
        runtime: IrohEndpointRuntime,
        localAddress: MeshIrohEndpointAddress,
        displayName: String,
        inviterDisplayName: String,
        replacingExisting: Bool
    ) async throws -> MeshTrustGroupID {
        if let localEpoch = try await replica.store.membershipEpoch(
            for: invitation.trustGroupID
        ), localEpoch < invitation.membershipEpoch {
            do {
                _ = try await catchUpArchivedMembership(
                    replica: replica, runtime: runtime, invitation: invitation
                )
            } catch let transitionError as MeshMembershipTransitionError {
                if try replica.activeTrustGroup() == nil {
                    throw MeshTrustGroupLifecycleError.archivedReplicaNeedsReset
                }
                throw transitionError
            }
        }
        let service = MeshTrustPairingService(
            identity: replica.identity,
            invitationStore: replica.store
        )
        let acceptance = try await service.acceptAndTrustInviter(
            invitation,
            acceptingAddressTicket: localAddress.ticket,
            displayName: displayName,
            inviterDisplayName: inviterDisplayName
        )
        let transport = IrohMeshTransport(
            runtime: runtime,
            remote: MeshIrohEndpointAddress(
                endpointID: invitation.inviterEndpointID,
                ticket: invitation.inviterAddressTicket
            )
        )
        let response = try await transport.exchange(
            MeshTransportRequest(
                header: try MeshTrustPairingRPCRequest(
                    invitation: invitation,
                    acceptance: acceptance
                ).encoded(),
                timeoutMilliseconds: 15_000
            )
        )
        let confirmation = try MeshTrustPairingRPCResponse.decode(response.header)
        guard confirmation.acceptedDeviceID == replica.identity.deviceID else {
            throw MeshTrustGroupLifecycleError.pairingConfirmationMismatch
        }
        guard let transitionEnvelope = response.body else {
            throw MeshMembershipTransitionError.quorumRequired
        }
        let transition = try MeshMembershipTransition.decodeCanonical(
            transitionEnvelope
        )
        let inviter = MeshPairedDevice(
            descriptor: MeshDeviceDescriptor(
                id: invitation.inviterDeviceID,
                endpointID: invitation.inviterEndpointID,
                displayName: inviterDisplayName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                roles: Set(invitation.inviterRoles ?? [.controller, .replica]),
                protocolVersion: invitation.protocolVersion
            ),
            signingPublicKey: invitation.inviterSigningPublicKey,
            addressTicket: invitation.inviterAddressTicket
        )
        let joiningDevice = MeshPairedDevice(
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
        try await replica.store.applyJoiningMembershipTransition(
            transition, trustedInviter: inviter,
            joiningDevice: joiningDevice,
            localIdentity: replica.identity
        )
        try replica.adoptActiveTrustGroup(
            invitation.trustGroupID,
            replacingExisting: replacingExisting,
            roles: Set(invitation.requestedRoles)
        )
        return invitation.trustGroupID
    }
}
