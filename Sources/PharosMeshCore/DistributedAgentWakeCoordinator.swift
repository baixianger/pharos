import Foundation
import PharosMeshProtocol
import PharosMeshReplica

/// Delivers one fixed trusted wake prompt for the newest unread message seen by
/// each exact local agent resource. Durable unread receipts remain owned by the
/// agent; this coordinator only suppresses repeated terminal pokes while the
/// same message remains newest.
public actor DistributedAgentWakeCoordinator {
    public struct PendingMessage: Equatable, Sendable {
        public let stableID: String
        public let room: String

        public init(stableID: String, room: String) {
            self.stableID = stableID
            self.room = room
        }
    }

    public typealias PresenceProvider = @Sendable (
        URL
    ) -> [String: DistributedHookCLI.LocalAgentPresence]
    public typealias PendingMessageProvider = @Sendable (
        String, MeshLocalReplica, MeshTrustGroupID
    ) async -> [PendingMessage]?
    public typealias PokeProvider = @Sendable (
        MeshResourceID, String, URL
    ) async -> Bool

    private var lastMessageIDsByMember: [String: String] = [:]
    private let presenceProvider: PresenceProvider
    private let pendingMessageProvider: PendingMessageProvider
    private let pokeProvider: PokeProvider

    public init(
        presenceProvider: @escaping PresenceProvider = {
            DistributedHookCLI.verifiedLocalAgentPresence(rootURL: $0)
        },
        pendingMessageProvider: @escaping PendingMessageProvider = {
            memberID, replica, group in
            guard let messages = try? await DistributedAgentChat(
                replica: replica, group: group
            ).peek(memberID: memberID) else {
                return nil
            }
            return messages.map {
                PendingMessage(stableID: $0.stableID, room: $0.room)
            }
        },
        pokeProvider: @escaping PokeProvider = {
            resourceID, prompt, rootURL in
            let outcome = await DistributedHostCommandExecutor(
                bindings: DistributedHostResourceBindings(
                    dataDirectory: rootURL
                )
            ).pokeLocal(resourceID: resourceID, text: prompt)
            if case .executed = outcome { return true }
            return false
        }
    ) {
        self.presenceProvider = presenceProvider
        self.pendingMessageProvider = pendingMessageProvider
        self.pokeProvider = pokeProvider
    }

    @discardableResult
    public func wakeEligibleAgents(
        replica: MeshLocalReplica, group: MeshTrustGroupID
    ) async -> Int {
        let presence = presenceProvider(replica.rootURL)
        var delivered = 0
        for (memberID, observation) in presence {
            guard observation.state == "idle" || observation.state == "stopped",
                  let resourceID = MeshResourceID(rawValue: memberID),
                  let messages = await pendingMessageProvider(
                    memberID, replica, group
                  ),
                  let newest = messages.last, !messages.isEmpty,
                  lastMessageIDsByMember[memberID] != newest.stableID
            else { continue }
            let rooms = Array(Set(messages.map(\.room)))
                .sorted().joined(separator: ", ")
            let prompt = "You have new Pharos mesh messages in \(rooms). " +
                "Run `pharos mesh recv --member \(memberID)` now, reply where needed, " +
                "then return to the idle composer."
            let succeeded = await pokeProvider(
                resourceID, prompt, replica.rootURL
            )
            if succeeded {
                lastMessageIDsByMember[memberID] = newest.stableID
                delivered += 1
            }
        }
        return delivered
    }
}
