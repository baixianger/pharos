import Foundation
import PharosMeshIdentity
import PharosMeshIroh
import PharosMeshProtocol
import PharosMeshReplica

/// User-facing pairing commands shared by both `pharos mesh` and the portable
/// `pharos-mesh` helper. Keeping the dispatch here prevents either CLI from
/// silently falling back to Broker-era credentials.
public enum DistributedPairCLI {
    public static let usage = """
    pair invite [--roles controller,replica] [--relay production|disabled]
    pair accept INVITATION --name NAME [--inviter-name NAME]
    pair redeem INVITATION ACCEPTANCE
    pair list
    pair revoke DEVICE-ID [--name THIS-DEVICE-NAME]
    """

    public static func run(_ args: [String]) async -> Int32 {
        let command = args.first ?? "invite"
        let remaining = args.isEmpty ? [] : Array(args.dropFirst())
        if ["help", "--help", "-h"].contains(command) {
            print(usage)
            return 0
        }
        do {
            let replica = try openReplica(args)
            switch command {
            case "invite", "create":
                let group = try await replica.ensureActiveTrustGroup()
                guard let epoch = try await replica.store.membershipEpoch(
                    for: group
                ) else { throw PairCLIError.missingMembership }
                let runtime = try await bindRuntime(args, replica: replica)
                defer { Task { try? await runtime.close() } }
                let address = try await runtime.localAddress()
                let invitation = try await MeshTrustPairingService(
                    identity: replica.identity,
                    invitationStore: replica.store
                ).issueInvitation(
                    trustGroupID: group, membershipEpoch: epoch,
                    inviterAddressTicket: address.ticket,
                    requestedRoles: try roles(args)
                )
                print(try MeshTrustInvitationLink.encode(invitation).absoluteString)
                return 0

            case "accept":
                guard let value = remaining.first,
                      let name = option("--name", in: args), !name.isEmpty else {
                    return usageError("pair accept INVITATION --name NAME")
                }
                let invitation = try decodeInvitation(value)
                let runtime = try await bindRuntime(args, replica: replica)
                defer { Task { try? await runtime.close() } }
                let address = try await runtime.localAddress()
                let acceptance = try await MeshTrustPairingService(
                    identity: replica.identity,
                    invitationStore: replica.store
                ).acceptAndTrustInviter(
                    invitation, acceptingAddressTicket: address.ticket,
                    displayName: name,
                    inviterDisplayName: option("--inviter-name", in: args)
                        ?? "Inviter"
                )
                try replica.adoptActiveTrustGroup(
                    invitation.trustGroupID, replacingExisting: true
                )
                print(try MeshTrustAcceptanceTicket.encode(acceptance))
                return 0

            case "redeem":
                guard remaining.count >= 2 else {
                    return usageError("pair redeem INVITATION ACCEPTANCE")
                }
                let invitation = try decodeInvitation(remaining[0])
                let acceptance = try MeshTrustAcceptanceTicket.decode(
                    remaining[1]
                )
                let paired = try await MeshTrustPairingService(
                    identity: replica.identity,
                    invitationStore: replica.store
                ).redeem(acceptance, for: invitation)
                print("trusted\t\(paired.descriptor.id.rawValue.uuidString)")
                return 0

            case "list":
                guard let group = try replica.activeTrustGroup(),
                      let epoch = try await replica.store.membershipEpoch(
                        for: group
                      ) else { throw PairCLIError.missingMembership }
                let devices = try await replica.store.trustedDevices(
                    in: group, membershipEpoch: epoch
                )
                for device in devices {
                    let roleList = device.descriptor.roles.map(\.rawValue)
                        .sorted().joined(separator: ",")
                    print(
                        "\(device.descriptor.id.rawValue.uuidString)\t" +
                        "\(device.descriptor.displayName)\t\(roleList)\t" +
                        device.descriptor.endpointID.rawValue
                    )
                }
                return 0

            case "revoke", "remove":
                guard let rawID = remaining.first,
                      let uuid = UUID(uuidString: rawID) else {
                    return usageError("pair revoke DEVICE-ID [--name THIS-DEVICE-NAME]")
                }
                guard let group = try replica.activeTrustGroup(),
                      let epoch = try await replica.store.membershipEpoch(for: group)
                else { throw PairCLIError.missingMembership }
                let target = MeshDeviceID(rawValue: uuid)
                let peers = try await replica.store.trustedDevices(
                    in: group, membershipEpoch: epoch
                )
                guard peers.contains(where: { $0.descriptor.id == target }) else {
                    throw PairCLIError.deviceNotFound
                }
                let runtime = try await bindRuntime(args, replica: replica)
                defer { Task { try? await runtime.close() } }
                let address = try await runtime.localAddress()
                let localMember = MeshPairedDevice(
                    descriptor: MeshDeviceDescriptor(
                        id: replica.identity.deviceID,
                        endpointID: try replica.identity.endpointID(),
                        displayName: option("--name", in: args)
                            ?? ProcessInfo.processInfo.hostName,
                        roles: [.controller, .host, .replica]
                    ),
                    signingPublicKey: try replica.identity.signingPublicKeyBytes(),
                    addressTicket: address.ticket
                )
                let survivors = peers.filter { $0.descriptor.id != target }
                let transition = try MeshMembershipTransitionSigner.sign(
                    trustGroupID: group, previousEpoch: epoch,
                    identity: replica.identity, roster: survivors + [localMember]
                )
                for peer in survivors {
                    let transport = IrohMeshTransport(
                        runtime: runtime,
                        remote: MeshIrohEndpointAddress(
                            endpointID: peer.descriptor.endpointID,
                            ticket: peer.addressTicket
                        )
                    )
                    try? await MeshReplicaRPCClient(transport: transport)
                        .applyMembershipTransition(transition)
                }
                try await replica.store.applyMembershipTransition(
                    transition, localIdentity: replica.identity
                )
                print("revoked\t\(rawID)\tepoch\t\(transition.nextEpoch)")
                return 0

            default:
                return usageError(usage)
            }
        } catch {
            FileHandle.standardError.write(
                Data("error: distributed pairing failed: \(error)\n".utf8)
            )
            return 1
        }
    }

    private static func openReplica(_ args: [String]) throws -> MeshLocalReplica {
        if let path = option("--data-dir", in: args) {
            guard path.hasPrefix("/"), !path.hasPrefix("--") else {
                throw PairCLIError.invalidDataDirectory
            }
            return try MeshLocalReplica.openHeadless(
                dataDirectory: URL(fileURLWithPath: path, isDirectory: true)
            )
        }
        return try MeshLocalReplica.openHeadless()
    }

    private static func bindRuntime(
        _ args: [String], replica: MeshLocalReplica
    ) async throws -> IrohEndpointRuntime {
        let policy: MeshIrohRelayPolicy
        switch option("--relay", in: args) ?? "production" {
        case "production": policy = .production
        case "disabled": policy = .disabled
        default: throw PairCLIError.invalidRelayPolicy
        }
        let runtime = try await IrohEndpointRuntime.bind(
            secretKey: replica.identity.irohSecretKeyBytes(),
            expectedEndpointID: try replica.identity.endpointID(),
            relayPolicy: policy
        )
        await runtime.waitUntilOnline()
        return runtime
    }

    private static func roles(_ args: [String]) throws -> Set<MeshDeviceRole> {
        let values = (option("--roles", in: args) ?? "controller,replica")
            .split(separator: ",")
        let parsed = values.compactMap { MeshDeviceRole(rawValue: String($0)) }
        guard !parsed.isEmpty, parsed.count == values.count else {
            throw PairCLIError.invalidRoles
        }
        return Set(parsed)
    }

    private static func decodeInvitation(_ value: String) throws -> MeshTrustInvitation {
        if let url = URL(string: value), url.scheme == "pharos" {
            return try MeshTrustInvitationLink.decode(url)
        }
        return try MeshTrustInvitationTicket.decode(value)
    }

    private static func option(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    private static func usageError(_ detail: String) -> Int32 {
        FileHandle.standardError.write(Data("usage: \(detail)\n".utf8))
        return 2
    }

    private enum PairCLIError: Error {
        case missingMembership
        case invalidDataDirectory
        case invalidRelayPolicy
        case invalidRoles
        case deviceNotFound
    }
}
