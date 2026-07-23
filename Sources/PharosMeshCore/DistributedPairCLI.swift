import Foundation
import PharosMeshIdentity
import PharosMeshIroh
import PharosMeshLifecycle
import PharosMeshProtocol
import PharosMeshReplica

/// User-facing pairing commands shared by both `pharos mesh` and the portable
/// `pharos-mesh` helper. Keeping the dispatch here prevents either CLI from
/// silently falling back to Broker-era credentials.
public enum DistributedPairCLI {
    public static let usage = """
    pair invite [--roles controller,host,replica] [--relay production|disabled]
    pair accept INVITATION --name NAME [--inviter-name NAME]
    pair list
    pair audit
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
                guard try replica.activeRoles().contains(.controller) else {
                    throw PairCLIError.administratorRequired
                }
                guard let epoch = try await replica.store.membershipEpoch(
                    for: group
                ) else { throw PairCLIError.missingMembership }
                let runtime = try await bindRuntime(args, replica: replica)
                do {
                    let address = try await runtime.localAddress()
                    let invitation = try await MeshTrustPairingService(
                        identity: replica.identity,
                        invitationStore: replica.store
                    ).issueInvitation(
                        trustGroupID: group, membershipEpoch: epoch,
                        inviterAddressTicket: address.ticket,
                        inviterRoles: try replica.activeRoles(),
                        requestedRoles: try roles(args)
                    )
                    try await runtime.close()
                    print(try MeshTrustInvitationLink.encode(invitation).absoluteString)
                    return 0
                } catch {
                    try? await runtime.close()
                    throw error
                }

            case "accept":
                guard let value = remaining.first,
                      let name = option("--name", in: args), !name.isEmpty else {
                    return usageError("pair accept INVITATION --name NAME")
                }
                let invitation = try decodeInvitation(value)
                let runtime = try await bindRuntime(args, replica: replica)
                do {
                    let address = try await runtime.localAddress()
                    let group = try await MeshTrustGroupLifecycle.join(
                        invitation, replica: replica, runtime: runtime,
                        localAddress: address, displayName: name,
                        inviterDisplayName: option("--inviter-name", in: args)
                            ?? "Inviter",
                        replacingExisting: try replica.activeTrustGroup() != nil
                    )
                    try await runtime.close()
                    print("joined\t\(group.rawValue.uuidString)")
                    return 0
                } catch {
                    try? await runtime.close()
                    throw error
                }

            case "redeem":
                return usageError(
                    "pair redeem is retired; run pair accept on the joining device " +
                        "so the admin quorum can certify the new membership"
                )

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

            case "audit":
                guard let group = try replica.activeTrustGroup() else {
                    throw PairCLIError.missingMembership
                }
                let entries = try await replica.store.membershipAudit(
                    for: group
                )
                if entries.isEmpty {
                    print("no membership transitions")
                    return 0
                }
                for entry in entries {
                    let removed = entry.removedDevices.map {
                        "\($0.descriptor.id.rawValue.uuidString):" +
                            $0.descriptor.displayName
                    }.sorted().joined(separator: ",")
                    print(
                        "epoch\t\(entry.previousEpoch)->\(entry.nextEpoch)\t" +
                        "author\t\(entry.authorDeviceID.rawValue.uuidString)\t" +
                        "removed\t\(removed.isEmpty ? "-" : removed)\t" +
                        "sha256\t\(entry.transitionSHA256)"
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
                guard try replica.activeRoles().contains(.controller) else {
                    throw PairCLIError.administratorRequired
                }
                let peers = try await replica.store.trustedDevices(
                    in: group, membershipEpoch: epoch
                )
                guard peers.contains(where: { $0.descriptor.id == target }) else {
                    throw PairCLIError.deviceNotFound
                }
                let runtime = try await bindRuntime(args, replica: replica)
                do {
                    let address = try await runtime.localAddress()
                    let localMember = MeshPairedDevice(
                        descriptor: MeshDeviceDescriptor(
                            id: replica.identity.deviceID,
                            endpointID: try replica.identity.endpointID(),
                            displayName: option("--name", in: args)
                                ?? ProcessInfo.processInfo.hostName,
                            roles: try replica.activeRoles()
                        ),
                        signingPublicKey: try replica.identity.signingPublicKeyBytes(),
                        addressTicket: address.ticket
                    )
                    let survivors = peers.filter { $0.descriptor.id != target }
                    let transition = try await MeshTrustGroupLifecycle
                        .certifyMembershipTransition(
                            replica: replica, runtime: runtime, group: group,
                            previousEpoch: epoch, roster: survivors + [localMember]
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
                        transition, localIdentity: replica.identity,
                        localAuthorRoles: try replica.activeRoles()
                    )
                    try await runtime.close()
                    print("revoked\t\(rawID)\tepoch\t\(transition.nextEpoch)")
                    return 0
                } catch {
                    try? await runtime.close()
                    throw error
                }

            default:
                return usageError(usage)
            }
        } catch {
            FileHandle.standardError.write(
                Data(
                    (
                        "error: distributed pairing failed: " +
                            "\(error.localizedDescription)\n"
                    ).utf8
                )
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
        let values = (option("--roles", in: args) ?? "controller,host,replica")
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
        case administratorRequired
    }
}
