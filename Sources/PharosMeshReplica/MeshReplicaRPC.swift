import Crypto
import Foundation
import PharosMeshIdentity
import PharosMeshProtocol

public enum MeshReplicaRPCError: Error, Equatable, Sendable {
    case invalidHeader
    case invalidBody
    case responseMismatch
    case remoteFailure(String)
    case peerNotTrusted
    case membershipEpochMismatch
    case hostUnavailable
    case synchronizationLimitExceeded
}

/// Stable, user-facing summary for a bounded sync pass. Transport errors stay
/// available to diagnostics, while product UI explains the recoverable state
/// without exposing QUIC implementation details.
public enum MeshSyncFailurePresentation {
    public static func message(peerNames: [String]) -> String? {
        let names = Array(Set(peerNames)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        guard !names.isEmpty else { return nil }
        let target = names.count == 1
            ? names[0]
            : "\(names.count) devices (\(names.joined(separator: ", ")))"
        return "Couldn't sync with \(target). Changes remain saved locally " +
            "and will retry automatically."
    }
}

/// Runs durable replica convergence and ephemeral Host presence as two
/// independent operations. Presence is deliberately attempted even when the
/// heavier data pull fails: a reachable Host must not make all of its live
/// agents appear Unknown merely because one anti-entropy round timed out.
public struct MeshPeerSyncPresenceOutcome<Presence: Sendable>: Sendable {
    public let received: Int
    public let synchronizationError: String?
    public let presence: Presence?
    public let presenceError: String?

    public var isReachable: Bool {
        synchronizationError == nil || presence != nil
    }
}

public enum MeshPeerSyncPresenceCoordinator {
    public static func run<Presence: Sendable>(
        synchronize: @Sendable () async throws -> Int,
        fetchPresence: (@Sendable () async throws -> Presence)?
    ) async -> MeshPeerSyncPresenceOutcome<Presence> {
        async let synchronization: (Int, String?) = {
            do { return (try await synchronize(), nil) }
            catch { return (0, error.localizedDescription) }
        }()
        async let livePresence: (Presence?, String?) = {
            guard let fetchPresence else { return (nil, nil) }
            do { return (try await fetchPresence(), nil) }
            catch { return (nil, error.localizedDescription) }
        }()
        let ((received, synchronizationError), (presence, presenceError)) =
            await (synchronization, livePresence)
        return MeshPeerSyncPresenceOutcome(
            received: received,
            synchronizationError: synchronizationError,
            presence: presence,
            presenceError: presenceError
        )
    }
}

public enum MeshPresenceVerificationError: LocalizedError, Equatable, Sendable {
    case hostIdentityMismatch
    case staleSnapshot
    case resourceRejected(String)

    public var errorDescription: String? {
        switch self {
        case .hostIdentityMismatch:
            "The Host presence identity did not match its trusted device."
        case .staleSnapshot:
            "The Host presence lease expired before it was received."
        case .resourceRejected(let id):
            "The Host could not prove ownership of agent \(id)."
        }
    }
}

public struct MeshMembershipVoteResponse: Codable, Equatable, Sendable {
    public var approval: MeshMembershipApproval?

    public init(approval: MeshMembershipApproval?) {
        self.approval = approval
    }
}

/// Fetches and verifies one Host-authoritative presence snapshot without
/// allowing callers to silently collapse transport and ownership failures into
/// an indistinguishable `unknown` state.
public enum MeshVerifiedHostPresence {
    public static func fetch(
        client: MeshReplicaRPCClient, peer: MeshPairedDevice,
        group: MeshTrustGroupID, membershipEpoch: UInt64,
        nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) async throws -> MeshAgentPresenceSnapshot {
        let snapshot = try await client.hostPresence(
            group: group, membershipEpoch: membershipEpoch
        )
        guard snapshot.hostDeviceID == peer.descriptor.id,
              snapshot.hostEndpointID == peer.descriptor.endpointID else {
            throw MeshPresenceVerificationError.hostIdentityMismatch
        }
        guard snapshot.isFresh(at: nowMilliseconds) else {
            throw MeshPresenceVerificationError.staleSnapshot
        }
        for record in snapshot.records {
            let resource: MeshHostResource
            do {
                resource = try await client.hostResource(
                    record.resourceID, group: group,
                    membershipEpoch: membershipEpoch
                )
            } catch {
                throw MeshPresenceVerificationError.resourceRejected(
                    record.resourceID.rawValue
                )
            }
            guard resource.state == .active,
                  resource.hostDeviceID == peer.descriptor.id,
                  resource.hostEndpointID == peer.descriptor.endpointID else {
                throw MeshPresenceVerificationError.resourceRejected(
                    record.resourceID.rawValue
                )
            }
        }
        return snapshot
    }
}

public enum MeshHostCommandExecutionOutcome: Equatable, Sendable {
    case executed(Data?)
    case failed(code: String)
}

/// Authenticated application router for one already-identified Iroh peer. The
/// transport supplies `remoteEndpointID` from the QUIC connection; no request
/// field is ever accepted as proof of peer identity.
public struct MeshReplicaRPCServer: Sendable {
    public let store: DistributedMeshStore
    public let hostIdentity: MeshDeviceIdentity?
    public let localAuthorRoles: Set<MeshDeviceRole>
    public let allowedTrustGroupID: MeshTrustGroupID?
    public let restrictToAllowedTrustGroup: Bool
    private let timestamp: @Sendable () -> MeshHybridTimestamp
    private let hostCommandHandler: (@Sendable (MeshHostCommand) async -> MeshHostCommandExecutionOutcome)?
    private let hostPresenceProvider: (@Sendable () async -> MeshAgentPresenceSnapshot)?
    private let membershipTransitionObserver:
        (@Sendable (MeshMembershipTransition) async -> Void)?

    public init(
        store: DistributedMeshStore, hostIdentity: MeshDeviceIdentity? = nil,
        localAuthorRoles: Set<MeshDeviceRole> = [],
        allowedTrustGroupID: MeshTrustGroupID? = nil,
        restrictToAllowedTrustGroup: Bool = false,
        membershipTransitionObserver:
            (@Sendable (MeshMembershipTransition) async -> Void)? = nil,
        hostPresenceProvider: (@Sendable () async -> MeshAgentPresenceSnapshot)? = nil,
        timestamp: @escaping @Sendable () -> MeshHybridTimestamp = {
            MeshHybridTimestamp(
                wallTimeMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
        }
    ) {
        self.store = store
        self.hostIdentity = hostIdentity
        self.localAuthorRoles = localAuthorRoles
        self.allowedTrustGroupID = allowedTrustGroupID
        self.restrictToAllowedTrustGroup = restrictToAllowedTrustGroup
        self.hostCommandHandler = nil
        self.hostPresenceProvider = hostPresenceProvider
        self.membershipTransitionObserver = membershipTransitionObserver
        self.timestamp = timestamp
    }

    public init(
        store: DistributedMeshStore, hostIdentity: MeshDeviceIdentity?,
        localAuthorRoles: Set<MeshDeviceRole> = [],
        allowedTrustGroupID: MeshTrustGroupID? = nil,
        restrictToAllowedTrustGroup: Bool = false,
        membershipTransitionObserver:
            (@Sendable (MeshMembershipTransition) async -> Void)? = nil,
        hostPresenceProvider: (@Sendable () async -> MeshAgentPresenceSnapshot)? = nil,
        hostCommandHandler: @escaping @Sendable (MeshHostCommand) async
            -> MeshHostCommandExecutionOutcome,
        timestamp: @escaping @Sendable () -> MeshHybridTimestamp = {
            MeshHybridTimestamp(
                wallTimeMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
        }
    ) {
        self.store = store
        self.hostIdentity = hostIdentity
        self.localAuthorRoles = localAuthorRoles
        self.allowedTrustGroupID = allowedTrustGroupID
        self.restrictToAllowedTrustGroup = restrictToAllowedTrustGroup
        self.hostCommandHandler = hostCommandHandler
        self.hostPresenceProvider = hostPresenceProvider
        self.membershipTransitionObserver = membershipTransitionObserver
        self.timestamp = timestamp
    }

    public func handle(
        _ request: MeshTransportRequest,
        remoteEndpointID: MeshEndpointID
    ) async throws -> MeshTransportResponse {
        try request.validate()
        let header: MeshReplicaRPCHeader
        do { header = try MeshReplicaRPCHeader.decode(request.header) }
        catch { throw MeshReplicaRPCError.invalidHeader }
        guard header.disposition == .request else {
            throw MeshReplicaRPCError.invalidHeader
        }
        if restrictToAllowedTrustGroup,
           header.trustGroupID != allowedTrustGroupID {
            return try failure(for: header, code: "trust-group-inactive")
        }
        guard header.metadata == nil else {
            return try failure(for: header, code: "invalid-request")
        }

        // A stale authenticated member may fetch exactly the next signed
        // transition. This must precede current-epoch authorization, otherwise
        // a device that missed one offline change can never rejoin anti-entropy.
        if header.operation == .membershipTransitionNext {
            let transition = try await store.nextMembershipTransition(
                for: header.trustGroupID, after: header.membershipEpoch
            )
            // Retained members have already moved to the next-epoch row, while
            // revoked members remain as old-epoch audit rows. Accept either
            // cryptographically authenticated case, but never an arbitrary
            // endpoint asking for the trust history.
            let retained = transition?.roster.contains(where: {
                $0.descriptor.endpointID == remoteEndpointID
            }) == true
            let departed = transition?.departingAuthor?.descriptor.endpointID
                == remoteEndpointID
            let oldEpochPeer = try await store.trustedDevice(
                in: header.trustGroupID, endpointID: remoteEndpointID,
                membershipEpoch: header.membershipEpoch
            ) != nil
            guard retained || departed || oldEpochPeer else {
                return try failure(for: header, code: "peer-not-trusted")
            }
            return try success(
                for: header,
                body: try transition.map(MeshReplicaRPCJSON.encode)
            )
        }

        // Membership changes are authenticated by their controller signature
        // and the previous-epoch roster inside the store transaction. Handle
        // them before current-epoch RPC authorization so an offline survivor
        // can catch up after another device has already advanced the epoch.
        if header.operation == .membershipTransition {
            guard let hostIdentity else {
                return try failure(for: header, code: "identity-unavailable")
            }
            do {
                let transition: MeshMembershipTransition = try decodeBody(request.body)
                guard transition.trustGroupID == header.trustGroupID,
                      transition.previousEpoch == header.membershipEpoch else {
                    throw MeshReplicaRPCError.invalidBody
                }
                try await store.applyMembershipTransition(
                    transition, localIdentity: hostIdentity,
                    localAuthorRoles: localAuthorRoles
                )
                await membershipTransitionObserver?(transition)
                return try success(for: header)
            } catch let error as MeshMembershipTransitionError {
                let code = error == .conflictingTransition
                    ? "membership-transition-conflict" : "membership-transition-invalid"
                return try failure(for: header, code: code)
            } catch {
                return try failure(for: header, code: "membership-transition-failed")
            }
        }

        let authorizedPeer: MeshPairedDevice
        do {
            authorizedPeer = try await store.authorizeReplicaRPCPeer(
                in: header.trustGroupID, endpointID: remoteEndpointID,
                membershipEpoch: header.membershipEpoch
            )
        } catch let error as DistributedMeshStoreError {
            if ProcessInfo.processInfo.environment["PHAROS_MESH_RPC_DIAGNOSTICS"] == "1" {
                let currentEpoch = try? await store.membershipEpoch(
                    for: header.trustGroupID
                )
                let epochText = currentEpoch.map(String.init) ?? "none"
                let message = "mesh-rpc authorization rejected " +
                    "peer=\(remoteEndpointID.rawValue) " +
                    "group=\(header.trustGroupID.rawValue.uuidString) " +
                    "requestEpoch=\(header.membershipEpoch) " +
                    "currentEpoch=\(epochText) " +
                    "error=\(error)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
            switch error {
            case .membershipEpochMismatch:
                return try failure(for: header, code: "membership-epoch-mismatch")
            case .rpcPeerNotTrusted:
                return try failure(for: header, code: "peer-not-trusted")
            default:
                return try failure(for: header, code: "request-failed")
            }
        }
        if let ticket = header.senderAddressTicket {
            do {
                try await store.refreshTrustedDeviceAddress(
                    in: header.trustGroupID, endpointID: remoteEndpointID,
                    membershipEpoch: header.membershipEpoch,
                    addressTicket: ticket
                )
            } catch {
                return try failure(for: header, code: "address-refresh-failed")
            }
        }

        do {
            switch header.operation {
            case .syncVector:
                guard request.body == nil, header.metadata == nil else {
                    throw MeshReplicaRPCError.invalidBody
                }
                var vector = try await store.syncVector(
                    for: header.trustGroupID, requestedBy: remoteEndpointID,
                    membershipEpoch: header.membershipEpoch
                )
                let peers = try await store.retainedTrustedDevices(
                    in: header.trustGroupID
                )
                vector.trustRoster = peers
                    .filter {
                        $0.device.descriptor.endpointID != remoteEndpointID
                    }
                    .map {
                        MeshTrustRosterEntry(
                            descriptor: $0.device.descriptor,
                            signingPublicKey: $0.device.signingPublicKey,
                            addressTicket: $0.device.addressTicket,
                            membershipEpoch: $0.membershipEpoch
                        )
                    }
                    .sorted { $0.descriptor.endpointID < $1.descriptor.endpointID }
                try vector.validate()
                return try success(for: header, body: try MeshReplicaRPCJSON.encode(vector))

            case .syncRange:
                let range: MeshEventRangeRequest = try decodeBody(request.body)
                guard range.trustGroupID == header.trustGroupID,
                      range.membershipEpoch == header.membershipEpoch else {
                    throw MeshReplicaRPCError.invalidBody
                }
                let response = try await store.syncResponse(
                    for: range, requestedBy: remoteEndpointID
                )
                return try success(for: header, body: try MeshReplicaRPCJSON.encode(response))

            case .syncAcknowledge:
                let vector: MeshSyncVector = try decodeBody(request.body)
                guard vector.trustGroupID == header.trustGroupID,
                      vector.membershipEpoch == header.membershipEpoch else {
                    throw MeshReplicaRPCError.invalidBody
                }
                try await store.acknowledge(
                    vector, requestedBy: remoteEndpointID
                )
                return try success(for: header)

            case .syncOffer:
                let vector: MeshSyncVector = try decodeBody(request.body)
                guard vector.trustGroupID == header.trustGroupID,
                      vector.membershipEpoch == header.membershipEpoch else {
                    throw MeshReplicaRPCError.invalidBody
                }
                let missing = try await store.missingRangeRequests(
                    advertisedBy: vector
                )
                guard missing.count <= MeshSyncVector.maximumAuthors else {
                    throw MeshReplicaRPCError.invalidBody
                }
                if missing.isEmpty {
                    try await store.acknowledge(
                        vector, requestedBy: remoteEndpointID
                    )
                }
                return try success(
                    for: header,
                    body: try MeshReplicaRPCJSON.encode(missing)
                )

            case .syncIngest:
                let response: MeshEventRangeResponse = try decodeBody(request.body)
                try await installPushedRange(
                    response, from: remoteEndpointID,
                    group: header.trustGroupID,
                    membershipEpoch: header.membershipEpoch
                )
                return try success(for: header)

            case .blobManifest:
                let blob: MeshBlobDigestRequest = try decodeBody(request.body)
                guard let manifest = try await store.blobManifest(
                    for: blob.digest, in: header.trustGroupID,
                    requestedBy: remoteEndpointID,
                    membershipEpoch: header.membershipEpoch
                ) else {
                    return try failure(for: header, code: "blob-not-found")
                }
                return try success(for: header, body: try MeshReplicaRPCJSON.encode(manifest))

            case .blobChunk:
                let blob: MeshBlobChunkRequest = try decodeBody(request.body)
                let chunk = try await store.blobChunk(
                    for: blob.digest, index: blob.index,
                    in: header.trustGroupID, requestedBy: remoteEndpointID,
                    membershipEpoch: header.membershipEpoch
                )
                let metadata = MeshBlobChunkMetadata(
                    digest: chunk.blobDigest, index: chunk.index,
                    byteCount: chunk.data.count, chunkDigest: chunk.chunkDigest
                )
                return try success(
                    for: header, metadata: try metadata.canonicalBytes(), body: chunk.data
                )

            case .hostResource:
                guard let hostIdentity else {
                    return try failure(for: header, code: "host-unavailable")
                }
                let query: MeshHostResourceRequest = try decodeBody(request.body)
                guard let resource = try await store.hostResource(
                    in: header.trustGroupID,
                    hostDeviceID: hostIdentity.deviceID,
                    resourceID: query.resourceID
                ), resource.state == .active else {
                    return try failure(for: header, code: "resource-not-found")
                }
                return try success(
                    for: header, body: try MeshReplicaRPCJSON.encode(resource)
                )

            case .hostPresence:
                guard request.body == nil,
                      let hostIdentity, let hostPresenceProvider else {
                    return try failure(for: header, code: "host-unavailable")
                }
                let snapshot = await hostPresenceProvider()
                try snapshot.validate()
                guard snapshot.hostDeviceID == hostIdentity.deviceID,
                      snapshot.hostEndpointID == (try hostIdentity.endpointID()) else {
                    return try failure(for: header, code: "presence-identity-mismatch")
                }
                return try success(
                    for: header, body: try MeshReplicaRPCJSON.encode(snapshot)
                )

            case .hostCommand:
                guard let hostIdentity else {
                    return try failure(for: header, code: "host-unavailable")
                }
                let command: MeshSignedHostCommand = try decodeBody(request.body)
                guard command.command.trustGroupID == header.trustGroupID,
                      command.membershipEpoch == header.membershipEpoch,
                      command.senderEndpointID == remoteEndpointID else {
                    return try failure(for: header, code: "command-identity-mismatch")
                }
                var receipt = try await store.accept(
                    command, on: hostIdentity, receivedAt: timestamp()
                )
                if receipt.receipt.state == .accepted,
                   let hostCommandHandler {
                    let claim = try await store.claimExecution(
                        commandID: command.command.id,
                        on: hostIdentity, at: timestamp()
                    )
                    receipt = claim.receipt
                    if claim.shouldExecute {
                        let outcome = await hostCommandHandler(command.command)
                        switch outcome {
                        case .executed(let result):
                            receipt = try await store.finishExecution(
                                commandID: command.command.id,
                                on: hostIdentity, outcome: .executed,
                                at: timestamp(), result: result
                            )
                        case .failed(let code):
                            receipt = try await store.finishExecution(
                                commandID: command.command.id,
                                on: hostIdentity, outcome: .failed,
                                at: timestamp(), failureCode: code
                            )
                        }
                    }
                }
                return try success(for: header, body: try MeshReplicaRPCJSON.encode(receipt))
            case .membershipVote:
                guard let hostIdentity,
                      authorizedPeer.descriptor.roles.contains(.controller) else {
                    return try failure(for: header, code: "membership-voter-unavailable")
                }
                let proposal: MeshMembershipTransition = try decodeBody(request.body)
                guard proposal.version == MeshMembershipTransition.quorumVersion,
                      proposal.trustGroupID == header.trustGroupID,
                      proposal.previousEpoch == header.membershipEpoch,
                      proposal.authorDeviceID == authorizedPeer.descriptor.id,
                      proposal.authorEndpointID == remoteEndpointID else {
                    return try failure(for: header, code: "membership-proposal-invalid")
                }
                let approval = try await store.recordMembershipVote(
                    for: proposal, localIdentity: hostIdentity,
                    localAuthorRoles: localAuthorRoles
                )
                return try success(
                    for: header,
                    body: try MeshReplicaRPCJSON.encode(
                        MeshMembershipVoteResponse(approval: approval)
                    )
                )
            case .membershipTransition, .membershipTransitionNext:
                preconditionFailure("membership transition handled before current-epoch authorization")
            }
        } catch let error as MeshReplicaRPCError {
            switch error {
            case .invalidBody:
                return try failure(for: header, code: "invalid-request")
            default:
                return try failure(for: header, code: "request-failed")
            }
        } catch let error as MeshMembershipTransitionError {
            let code = error == .conflictingTransition
                ? "membership-vote-conflict" : "membership-vote-invalid"
            return try failure(for: header, code: code)
        } catch let error as DistributedMeshStoreError {
            switch error {
            case .membershipEpochMismatch:
                return try failure(for: header, code: "membership-epoch-mismatch")
            case .rpcPeerNotTrusted:
                return try failure(for: header, code: "peer-not-trusted")
            default:
                return try failure(for: header, code: "request-failed")
            }
        } catch {
            return try failure(for: header, code: "request-failed")
        }
    }

    private func success(
        for request: MeshReplicaRPCHeader, metadata: Data? = nil, body: Data? = nil
    ) throws -> MeshTransportResponse {
        let header = MeshReplicaRPCHeader(
            requestID: request.requestID, operation: request.operation,
            trustGroupID: request.trustGroupID,
            membershipEpoch: request.membershipEpoch,
            disposition: .success, metadata: metadata
        )
        let response = MeshTransportResponse(header: try header.canonicalBytes(), body: body)
        try response.validate()
        return response
    }

    private func failure(
        for request: MeshReplicaRPCHeader, code: String
    ) throws -> MeshTransportResponse {
        let header = MeshReplicaRPCHeader(
            requestID: request.requestID, operation: request.operation,
            trustGroupID: request.trustGroupID,
            membershipEpoch: request.membershipEpoch,
            disposition: .failure, errorCode: code
        )
        return MeshTransportResponse(header: try header.canonicalBytes())
    }

    private func decodeBody<T: Decodable>(_ body: Data?) throws -> T {
        guard let body else { throw MeshReplicaRPCError.invalidBody }
        do { return try MeshReplicaRPCJSON.decode(T.self, from: body) }
        catch { throw MeshReplicaRPCError.invalidBody }
    }

    private func installPushedRange(
        _ response: MeshEventRangeResponse,
        from remoteEndpointID: MeshEndpointID,
        group: MeshTrustGroupID,
        membershipEpoch: UInt64
    ) async throws {
        try response.validate()
        guard response.request.trustGroupID == group,
              response.request.membershipEpoch == membershipEpoch else {
            throw MeshReplicaRPCError.invalidBody
        }
        switch response.kind {
        case .events:
            for event in response.events {
                let author = if event.membershipEpoch == membershipEpoch {
                    try await store.trustedDevice(
                        in: group, endpointID: event.authorEndpointID,
                        membershipEpoch: membershipEpoch
                    )
                } else {
                    try await store.retainedTrustedDevice(
                        in: group, endpointID: event.authorEndpointID
                    )
                }
                guard let author else { throw MeshReplicaRPCError.peerNotTrusted }
                if event.membershipEpoch == membershipEpoch {
                    _ = try await store.insert(
                        event, authorPublicKey: author.signingPublicKey
                    )
                } else {
                    _ = try await store.insertHistoricalEvent(
                        event, authorPublicKey: author.signingPublicKey,
                        vouchedBy: remoteEndpointID,
                        currentMembershipEpoch: membershipEpoch
                    )
                }
            }
        case .snapshot:
            guard let bundle = response.snapshot else {
                throw MeshReplicaRPCError.peerNotTrusted
            }
            let creator = if bundle.snapshot.membershipEpoch == membershipEpoch {
                try await store.trustedDevice(
                    in: group, endpointID: bundle.snapshot.creatorEndpointID,
                    membershipEpoch: membershipEpoch
                )
            } else {
                try await store.retainedTrustedDevice(
                    in: group, endpointID: bundle.snapshot.creatorEndpointID
                )
            }
            guard let creator else { throw MeshReplicaRPCError.peerNotTrusted }
            if bundle.snapshot.membershipEpoch == membershipEpoch {
                try await store.installSnapshot(
                    bundle, creatorPublicKey: creator.signingPublicKey
                )
            } else {
                try await store.installHistoricalSnapshot(
                    bundle, creatorPublicKey: creator.signingPublicKey,
                    vouchedBy: remoteEndpointID,
                    currentMembershipEpoch: membershipEpoch
                )
            }
        case .upToDate:
            break
        }
    }
}

public struct MeshReplicaRPCClient: Sendable {
    /// A first request may need to establish a QUIC path through the public
    /// relay before any bytes can flow. Real cross-network cold connects take
    /// roughly 3–5 seconds; a 1.5-second UI budget caused every attempt to be
    /// cancelled before the path became usable, leaving reachable agents as
    /// Unknown forever. Peers are contacted concurrently, so this bound does
    /// not put an offline device in front of an online peer's result.
    /// Covers a cold relay connection plus one bounded duplicate-connection
    /// recovery. A simultaneous dial can consume roughly one cold handshake
    /// before Iroh asks one side to reconnect; cancelling at 5–6 seconds made
    /// a reachable Host repeatedly disappear as Unknown on its peers.
    public static let defaultRequestTimeoutMilliseconds = 10_000
    public static let backgroundRequestTimeoutMilliseconds = 10_000

    private let transport: any MeshTransport
    private let requestTimeoutMilliseconds: Int

    public init(transport: any MeshTransport) {
        self.init(
            transport: transport,
            requestTimeoutMilliseconds: Self.defaultRequestTimeoutMilliseconds
        )
    }

    public init(
        transport: any MeshTransport, requestTimeoutMilliseconds: Int
    ) {
        self.transport = transport
        self.requestTimeoutMilliseconds = max(1, requestTimeoutMilliseconds)
    }

    public func syncVector(
        for group: MeshTrustGroupID, membershipEpoch: UInt64
    ) async throws -> MeshSyncVector {
        let response = try await exchange(
            operation: .syncVector, group: group, membershipEpoch: membershipEpoch
        )
        let vector: MeshSyncVector = try decodeBody(response.body)
        try vector.validate()
        guard vector.trustGroupID == group,
              vector.membershipEpoch == membershipEpoch else {
            throw MeshReplicaRPCError.responseMismatch
        }
        return vector
    }

    public func eventRange(
        _ request: MeshEventRangeRequest
    ) async throws -> MeshEventRangeResponse {
        let response = try await exchange(
            operation: .syncRange, group: request.trustGroupID,
            membershipEpoch: request.membershipEpoch,
            body: try MeshReplicaRPCJSON.encode(request)
        )
        let range: MeshEventRangeResponse = try decodeBody(response.body)
        try range.validate()
        guard range.request == request else { throw MeshReplicaRPCError.responseMismatch }
        return range
    }

    public func acknowledge(_ vector: MeshSyncVector) async throws {
        _ = try await exchange(
            operation: .syncAcknowledge, group: vector.trustGroupID,
            membershipEpoch: vector.membershipEpoch,
            body: try MeshReplicaRPCJSON.encode(vector)
        )
    }

    public func offer(
        _ vector: MeshSyncVector
    ) async throws -> [MeshEventRangeRequest] {
        let response = try await exchange(
            operation: .syncOffer, group: vector.trustGroupID,
            membershipEpoch: vector.membershipEpoch,
            body: try MeshReplicaRPCJSON.encode(vector)
        )
        let requests: [MeshEventRangeRequest] = try decodeBody(response.body)
        guard requests.count <= MeshSyncVector.maximumAuthors else {
            throw MeshReplicaRPCError.invalidBody
        }
        for request in requests {
            try request.validate()
            guard request.trustGroupID == vector.trustGroupID,
                  request.membershipEpoch == vector.membershipEpoch else {
                throw MeshReplicaRPCError.responseMismatch
            }
        }
        return requests
    }

    public func ingest(_ response: MeshEventRangeResponse) async throws {
        try response.validate()
        _ = try await exchange(
            operation: .syncIngest,
            group: response.request.trustGroupID,
            membershipEpoch: response.request.membershipEpoch,
            body: try MeshReplicaRPCJSON.encode(response)
        )
    }

    public func blobManifest(
        _ digest: MeshBlobDigest, group: MeshTrustGroupID,
        membershipEpoch: UInt64
    ) async throws -> MeshBlobManifest {
        let response = try await exchange(
            operation: .blobManifest, group: group,
            membershipEpoch: membershipEpoch,
            body: try MeshReplicaRPCJSON.encode(MeshBlobDigestRequest(digest: digest))
        )
        let manifest: MeshBlobManifest = try decodeBody(response.body)
        try manifest.validate()
        guard manifest.digest == digest else { throw MeshReplicaRPCError.responseMismatch }
        return manifest
    }

    public func blobChunk(
        _ digest: MeshBlobDigest, index: Int, group: MeshTrustGroupID,
        membershipEpoch: UInt64
    ) async throws -> MeshBlobChunk {
        let response = try await exchange(
            operation: .blobChunk, group: group,
            membershipEpoch: membershipEpoch,
            body: try MeshReplicaRPCJSON.encode(
                MeshBlobChunkRequest(digest: digest, index: index)
            )
        )
        guard let metadataBytes = response.header.metadata, let data = response.body else {
            throw MeshReplicaRPCError.invalidBody
        }
        let metadata = try MeshBlobChunkMetadata.decode(metadataBytes)
        guard metadata.digest == digest, metadata.index == index,
              metadata.byteCount == data.count,
              Data(SHA256.hash(data: data)) == metadata.chunkDigest.rawValue else {
            throw MeshReplicaRPCError.responseMismatch
        }
        return MeshBlobChunk(
            blobDigest: digest, index: index, data: data,
            chunkDigest: metadata.chunkDigest
        )
    }

    public func sendHostCommand(
        _ command: MeshSignedHostCommand
    ) async throws -> MeshSignedCommandReceipt {
        let response = try await exchange(
            operation: .hostCommand, group: command.command.trustGroupID,
            membershipEpoch: command.membershipEpoch,
            body: try MeshReplicaRPCJSON.encode(command)
        )
        let receipt: MeshSignedCommandReceipt = try decodeBody(response.body)
        do { try receipt.validateStructure() }
        catch { throw MeshReplicaRPCError.responseMismatch }
        let expectedFingerprint = Data(
            SHA256.hash(data: try command.command.canonicalIdempotencyBytes())
        )
        guard receipt.trustGroupID == command.command.trustGroupID,
              receipt.receipt.commandID == command.command.id,
              receipt.receipt.idempotencyKey == command.command.idempotencyKey,
              receipt.receipt.hostDeviceID == command.command.targetHostDeviceID,
              receipt.hostEndpointID == command.command.targetHostEndpointID,
              receipt.receipt.resourceID == command.command.resourceID,
              receipt.commandFingerprint == expectedFingerprint,
              receipt.deadlineMilliseconds == command.command.deadlineMilliseconds,
              let hostPublicKey = Self.publicKeyData(
                from: command.command.targetHostEndpointID
              ) else {
            throw MeshReplicaRPCError.responseMismatch
        }
        do {
            try MeshHostCommandCrypto.verify(
                receipt, hostPublicKey: hostPublicKey
            )
        } catch {
            throw MeshReplicaRPCError.responseMismatch
        }
        return receipt
    }

    public func hostResource(
        _ resourceID: MeshResourceID, group: MeshTrustGroupID,
        membershipEpoch: UInt64
    ) async throws -> MeshHostResource {
        let response = try await exchange(
            operation: .hostResource, group: group,
            membershipEpoch: membershipEpoch,
            body: try MeshReplicaRPCJSON.encode(
                MeshHostResourceRequest(resourceID: resourceID)
            )
        )
        let resource: MeshHostResource = try decodeBody(response.body)
        try resource.validate()
        guard resource.trustGroupID == group,
              resource.resourceID == resourceID,
              resource.generation > 0 else {
            throw MeshReplicaRPCError.responseMismatch
        }
        return resource
    }

    public func hostPresence(
        group: MeshTrustGroupID, membershipEpoch: UInt64
    ) async throws -> MeshAgentPresenceSnapshot {
        let response = try await exchange(
            operation: .hostPresence, group: group,
            membershipEpoch: membershipEpoch
        )
        let snapshot: MeshAgentPresenceSnapshot = try decodeBody(response.body)
        do { try snapshot.validate() }
        catch { throw MeshReplicaRPCError.responseMismatch }
        return snapshot
    }

    public func applyMembershipTransition(
        _ transition: MeshMembershipTransition
    ) async throws {
        try transition.verifySignature()
        _ = try await exchange(
            operation: .membershipTransition,
            group: transition.trustGroupID,
            membershipEpoch: transition.previousEpoch,
            body: try MeshReplicaRPCJSON.encode(transition)
        )
    }

    public func requestMembershipVote(
        for proposal: MeshMembershipTransition
    ) async throws -> MeshMembershipApproval? {
        try proposal.verifyAuthorSignature()
        let response = try await exchange(
            operation: .membershipVote,
            group: proposal.trustGroupID,
            membershipEpoch: proposal.previousEpoch,
            body: try MeshReplicaRPCJSON.encode(proposal)
        )
        let vote: MeshMembershipVoteResponse = try decodeBody(response.body)
        if let approval = vote.approval {
            guard approval.deviceID != proposal.authorDeviceID,
                  proposal.previousControllers?.contains(where: {
                      $0.deviceID == approval.deviceID &&
                          $0.endpointID == approval.endpointID
                  }) == true else {
                throw MeshReplicaRPCError.responseMismatch
            }
        }
        return vote.approval
    }

    public func nextMembershipTransition(
        for group: MeshTrustGroupID, after membershipEpoch: UInt64
    ) async throws -> MeshMembershipTransition? {
        let response = try await exchange(
            operation: .membershipTransitionNext, group: group,
            membershipEpoch: membershipEpoch
        )
        guard let body = response.body else { return nil }
        let transition: MeshMembershipTransition = try decodeBody(body)
        try transition.verifySignature()
        guard transition.trustGroupID == group,
              transition.previousEpoch == membershipEpoch,
              transition.nextEpoch == membershipEpoch + 1 else {
            throw MeshReplicaRPCError.responseMismatch
        }
        return transition
    }

    private func exchange(
        operation: MeshReplicaRPCOperation, group: MeshTrustGroupID,
        membershipEpoch: UInt64, metadata: Data? = nil, body: Data? = nil
    ) async throws -> (header: MeshReplicaRPCHeader, body: Data?) {
        let requestHeader = MeshReplicaRPCHeader(
            operation: operation, trustGroupID: group,
            membershipEpoch: membershipEpoch, disposition: .request,
            senderAddressTicket: try await transport.localAddressTicket(),
            metadata: metadata
        )
        let request = MeshTransportRequest(
            header: try requestHeader.canonicalBytes(), body: body,
            timeoutMilliseconds: requestTimeoutMilliseconds
        )
        let response = try await transport.exchange(request)
        try response.validate()
        let responseHeader: MeshReplicaRPCHeader
        do { responseHeader = try MeshReplicaRPCHeader.decode(response.header) }
        catch { throw MeshReplicaRPCError.invalidHeader }
        guard responseHeader.requestID == requestHeader.requestID,
              responseHeader.operation == operation,
              responseHeader.trustGroupID == group,
              responseHeader.membershipEpoch == membershipEpoch,
              responseHeader.disposition != .request else {
            throw MeshReplicaRPCError.responseMismatch
        }
        if responseHeader.disposition == .failure {
            guard response.body == nil else {
                throw MeshReplicaRPCError.responseMismatch
            }
            throw MeshReplicaRPCError.remoteFailure(responseHeader.errorCode ?? "unknown")
        }
        return (responseHeader, response.body)
    }

    private func decodeBody<T: Decodable>(_ body: Data?) throws -> T {
        guard let body else { throw MeshReplicaRPCError.invalidBody }
        do { return try MeshReplicaRPCJSON.decode(T.self, from: body) }
        catch { throw MeshReplicaRPCError.invalidBody }
    }

    private static func publicKeyData(from endpoint: MeshEndpointID) -> Data? {
        let text = endpoint.rawValue
        guard text.utf8.count == 64 else { return nil }
        var bytes = Data(capacity: 32)
        var index = text.startIndex
        for _ in 0..<32 {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

public struct MeshReplicaSyncReport: Equatable, Sendable {
    public var eventCount: Int
    public var snapshotCount: Int
    public var rangeCount: Int

    public init(eventCount: Int = 0, snapshotCount: Int = 0,
                rangeCount: Int = 0) {
        self.eventCount = eventCount
        self.snapshotCount = snapshotCount
        self.rangeCount = rangeCount
    }
}

/// One bounded bidirectional anti-entropy session. The caller first pulls what
/// it lacks, then offers its resulting vector so the peer can request missing
/// ranges over the same authenticated connection. All writes still pass
/// through signature, membership, sequence, hash-chain, and snapshot checks.
public struct MeshReplicaSyncSession: Sendable {
    public static let maximumRangeRounds = 4_096

    private let store: DistributedMeshStore
    private let client: MeshReplicaRPCClient
    private let remoteEndpointID: MeshEndpointID?

    public init(store: DistributedMeshStore, client: MeshReplicaRPCClient) {
        self.init(
            store: store, client: client, remoteEndpointID: nil
        )
    }

    public init(
        store: DistributedMeshStore, client: MeshReplicaRPCClient,
        remoteEndpointID: MeshEndpointID?
    ) {
        self.store = store
        self.client = client
        self.remoteEndpointID = remoteEndpointID
    }

    public func synchronize(
        group: MeshTrustGroupID, membershipEpoch: UInt64,
        rangeLimit: Int = 256
    ) async throws -> MeshReplicaSyncReport {
        var report = MeshReplicaSyncReport()
        let remote = try await client.syncVector(
            for: group, membershipEpoch: membershipEpoch
        )
        guard remote.trustGroupID == group,
              remote.membershipEpoch == membershipEpoch else {
            throw MeshReplicaRPCError.responseMismatch
        }
        try await installControllerRoster(
            remote.trustRoster,
            group: group, membershipEpoch: membershipEpoch
        )

        for _ in 0..<Self.maximumRangeRounds {
            let requests = try await store.missingRangeRequests(
                advertisedBy: remote, limit: rangeLimit
            )
            if requests.isEmpty {
                // ACK only the vector this peer advertised. Our local vector
                // can contain offline authors the remote has never received;
                // claiming those here would correctly fail its monotonic
                // acknowledgement validation.
                try await pushLocalChanges(
                    group: group, membershipEpoch: membershipEpoch
                )
                try await client.acknowledge(remote)
                return report
            }
            for request in requests {
                let response = try await client.eventRange(request)
                report.rangeCount += 1
                switch response.kind {
                case .events:
                    for event in response.events {
                        let author = if event.membershipEpoch == membershipEpoch {
                            try await store.trustedDevice(
                                in: group, endpointID: event.authorEndpointID,
                                membershipEpoch: membershipEpoch
                            )
                        } else {
                            try await store.retainedTrustedDevice(
                                in: group, endpointID: event.authorEndpointID
                            )
                        }
                        guard let author else {
                            throw MeshReplicaRPCError.peerNotTrusted
                        }
                        if event.membershipEpoch == membershipEpoch {
                            _ = try await store.insert(
                                event, authorPublicKey: author.signingPublicKey
                            )
                        } else {
                            guard let remoteEndpointID else {
                                throw MeshReplicaRPCError.peerNotTrusted
                            }
                            _ = try await store.insertHistoricalEvent(
                                event, authorPublicKey: author.signingPublicKey,
                                vouchedBy: remoteEndpointID,
                                currentMembershipEpoch: membershipEpoch
                            )
                        }
                        report.eventCount += 1
                    }
                case .snapshot:
                    guard let bundle = response.snapshot else {
                        throw MeshReplicaRPCError.peerNotTrusted
                    }
                    let creator =
                        if bundle.snapshot.membershipEpoch == membershipEpoch {
                            try await store.trustedDevice(
                                in: group,
                                endpointID: bundle.snapshot.creatorEndpointID,
                                membershipEpoch: membershipEpoch
                            )
                        } else {
                            try await store.retainedTrustedDevice(
                                in: group,
                                endpointID: bundle.snapshot.creatorEndpointID
                            )
                        }
                    guard let creator else {
                        throw MeshReplicaRPCError.peerNotTrusted
                    }
                    if bundle.snapshot.membershipEpoch == membershipEpoch {
                        try await store.installSnapshot(
                            bundle, creatorPublicKey: creator.signingPublicKey
                        )
                    } else {
                        guard let remoteEndpointID else {
                            throw MeshReplicaRPCError.peerNotTrusted
                        }
                        try await store.installHistoricalSnapshot(
                            bundle, creatorPublicKey: creator.signingPublicKey,
                            vouchedBy: remoteEndpointID,
                            currentMembershipEpoch: membershipEpoch
                        )
                    }
                    report.snapshotCount += 1
                case .upToDate:
                    throw MeshReplicaRPCError.responseMismatch
                }
            }
        }
        throw MeshReplicaRPCError.synchronizationLimitExceeded
    }

    private func pushLocalChanges(
        group: MeshTrustGroupID, membershipEpoch: UInt64
    ) async throws {
        for _ in 0..<Self.maximumRangeRounds {
            let local = try await store.syncVector(for: group)
            guard local.membershipEpoch == membershipEpoch else {
                throw MeshReplicaRPCError.membershipEpochMismatch
            }
            let requests = try await client.offer(local)
            if requests.isEmpty { return }
            for request in requests {
                let response = try await store.syncResponse(for: request)
                try await client.ingest(response)
            }
        }
        throw MeshReplicaRPCError.synchronizationLimitExceeded
    }

    private func installControllerRoster(
        _ roster: [MeshTrustRosterEntry]?, group: MeshTrustGroupID,
        membershipEpoch: UInt64
    ) async throws {
        guard let roster, !roster.isEmpty, let remoteEndpointID else { return }
        guard let controller = try await store.trustedDevice(
            in: group, endpointID: remoteEndpointID,
            membershipEpoch: membershipEpoch
        ), controller.descriptor.roles.contains(.controller) else { return }
        for entry in roster {
            let entryEpoch = entry.membershipEpoch ?? membershipEpoch
            let peer = MeshPairedDevice(
                descriptor: entry.descriptor,
                signingPublicKey: entry.signingPublicKey,
                addressTicket: entry.addressTicket
            )
            do { try peer.validateBinding() }
            catch { throw MeshReplicaRPCError.peerNotTrusted }
            if let existing = try await store.trustedDevice(
                in: group, id: peer.descriptor.id
            ) {
                guard existing.hasSameCryptographicIdentity(as: peer) else {
                    throw MeshReplicaRPCError.peerNotTrusted
                }
                // Historical rows are signature-verification material only.
                // Never let an older roster overwrite the roles, protocol, or
                // current routing hint of a surviving active member.
                if entryEpoch < membershipEpoch {
                    try await store.installRetainedVerifiedPeer(
                        peer, in: group, membershipEpoch: entryEpoch
                    )
                    continue
                }
                // Display names are local aliases chosen independently by
                // each inviter (for example "Pharos Mac" versus "Mac mini").
                // They are not part of the cryptographic device identity and
                // must not turn a valid transitive roster into a trust error.
                // Endpoint, key, roles, and protocol version remain strict so
                // a relayed roster cannot rebind or elevate an existing peer.
                guard existing.descriptor.roles == peer.descriptor.roles,
                      existing.descriptor.protocolVersion ==
                          peer.descriptor.protocolVersion,
                      entryEpoch == membershipEpoch else {
                    throw MeshReplicaRPCError.peerNotTrusted
                }
                if existing.addressTicket != peer.addressTicket {
                    try await store.refreshTrustedDeviceAddress(
                        in: group, endpointID: peer.descriptor.endpointID,
                        membershipEpoch: membershipEpoch,
                        addressTicket: peer.addressTicket
                    )
                }
            } else {
                if entryEpoch < membershipEpoch {
                    try await store.installRetainedVerifiedPeer(
                        peer, in: group, membershipEpoch: entryEpoch
                    )
                } else {
                    try await store.installVerifiedPeer(
                        peer, in: group, membershipEpoch: entryEpoch
                    )
                }
            }
        }
    }
}

/// Lazily reconstructs one content-addressed blob from a trusted peer. Every
/// chunk and the final digest are verified by the store before bytes become
/// visible to the product.
public struct MeshBlobFetchSession: Sendable {
    private let store: DistributedMeshStore
    private let client: MeshReplicaRPCClient

    public init(store: DistributedMeshStore, client: MeshReplicaRPCClient) {
        self.store = store
        self.client = client
    }

    public func fetch(
        _ digest: MeshBlobDigest, group: MeshTrustGroupID,
        membershipEpoch: UInt64
    ) async throws -> Data {
        if let existing = try await store.blobData(for: digest) {
            return existing
        }
        let manifest = try await client.blobManifest(
            digest, group: group, membershipEpoch: membershipEpoch
        )
        try await store.registerBlobManifest(manifest)
        for index in try await store.missingBlobChunkIndices(for: digest) {
            let chunk = try await client.blobChunk(
                digest, index: index, group: group,
                membershipEpoch: membershipEpoch
            )
            _ = try await store.receiveBlobChunk(chunk)
        }
        try await store.finalizeBlob(digest)
        guard let data = try await store.blobData(for: digest) else {
            throw MeshReplicaRPCError.invalidBody
        }
        return data
    }
}

private enum MeshReplicaRPCJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dataEncodingStrategy = .base64
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        return try decoder.decode(type, from: data)
    }
}
