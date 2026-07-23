import Foundation
import PharosMeshProtocol
import PharosMeshReplica

public enum DistributedAgentControlReadiness: String, Codable, Equatable, Sendable {
    case managed
    case unmanaged
    case conflicted
}

public struct DistributedAgentReconcileResult: Equatable, Sendable {
    public var resource: MeshHostResource
    public var readiness: DistributedAgentControlReadiness

    public init(
        resource: MeshHostResource,
        readiness: DistributedAgentControlReadiness
    ) {
        self.resource = resource
        self.readiness = readiness
    }
}

/// Rebuilds Host-private control authority only from an exact structured hook
/// identity and a live tmux seat. Room names, nicks, cwd, host names, and stale
/// binding files are never sufficient to grant poke/stop.
public struct DistributedAgentResourceReconciler: Sendable {
    public let bindings: DistributedHostResourceBindings
    public let seatInspector: any DistributedTmuxSeatInspecting

    public init(
        dataDirectory: URL,
        seatInspector: any DistributedTmuxSeatInspecting =
            DistributedTmuxSeatInspector()
    ) {
        bindings = DistributedHostResourceBindings(dataDirectory: dataDirectory)
        self.seatInspector = seatInspector
    }

    public func reconcile(
        memberID: String,
        presence: DistributedHookCLI.LocalAgentPresence,
        seatIsConflicted: Bool,
        replica: MeshLocalReplica,
        group: MeshTrustGroupID,
        now: MeshHybridTimestamp
    ) async throws -> DistributedAgentReconcileResult {
        guard let resourceID = MeshResourceID(rawValue: memberID) else {
            throw DistributedAgentChatError.invalidMemberID(memberID)
        }
        if presence.state == MeshSessionState.gone.rawValue || seatIsConflicted {
            try? bindings.remove(resourceID)
            let resource = try await setActions(
                [.presence], resourceID: resourceID,
                replica: replica, group: group, now: now
            )
            return DistributedAgentReconcileResult(
                resource: resource,
                readiness: seatIsConflicted ? .conflicted : .unmanaged
            )
        }

        if let pane = presence.tmuxPane, !pane.isEmpty,
           let socket = presence.tmuxSocket, !socket.isEmpty {
            do {
                let seat = try seatInspector.resolve(socket: socket, pane: pane)
                if let old = try? bindings.load(resourceID),
                   old.tmuxSession != seat.sessionName {
                    try? bindings.remove(resourceID)
                    let resource = try await setActions(
                        [.presence], resourceID: resourceID,
                        replica: replica, group: group, now: now
                    )
                    return DistributedAgentReconcileResult(
                        resource: resource, readiness: .conflicted
                    )
                }
                let binding = try DistributedHostResourceBinding(
                    resourceID: resourceID,
                    tmuxSession: seat.sessionName,
                    tmuxSocket: seat.socket,
                    tmuxPane: seat.paneID,
                    tmuxSessionID: seat.sessionID,
                    tmuxSessionCreatedAt: seat.sessionCreatedAt,
                    panePID: seat.panePID
                )
                try bindings.save(binding, for: resourceID)
                let resource = try await setActions(
                    [.presence, .poke, .stop],
                    resourceID: resourceID,
                    replica: replica, group: group, now: now
                )
                return DistributedAgentReconcileResult(
                    resource: resource, readiness: .managed
                )
            } catch {
                try? bindings.remove(resourceID)
                let resource = try await setActions(
                    [.presence], resourceID: resourceID,
                    replica: replica, group: group, now: now
                )
                return DistributedAgentReconcileResult(
                    resource: resource, readiness: .unmanaged
                )
            }
        }

        if let binding = try? bindings.load(resourceID),
           binding.hasVerifiedRuntimeSeat,
           (try? seatInspector.verify(binding)) != nil {
            let resource = try await setActions(
                [.presence, .poke, .stop],
                resourceID: resourceID,
                replica: replica, group: group, now: now
            )
            return DistributedAgentReconcileResult(
                resource: resource, readiness: .managed
            )
        }

        try? bindings.remove(resourceID)
        let resource = try await setActions(
            [.presence], resourceID: resourceID,
            replica: replica, group: group, now: now
        )
        return DistributedAgentReconcileResult(
            resource: resource, readiness: .unmanaged
        )
    }

    private func setActions(
        _ actions: Set<MeshHostAction>,
        resourceID: MeshResourceID,
        replica: MeshLocalReplica,
        group: MeshTrustGroupID,
        now: MeshHybridTimestamp
    ) async throws -> MeshHostResource {
        if let existing = try await replica.store.hostResource(
            in: group, hostDeviceID: replica.identity.deviceID,
            resourceID: resourceID
        ) {
            guard existing.state == .active else {
                throw DistributedMeshStoreError.hostResourceRetired
            }
            guard Set(existing.allowedActions) != actions else { return existing }
            return try await replica.store.replaceHostResource(
                in: group, on: replica.identity,
                resourceID: resourceID, allowedActions: actions,
                at: max(existing.updatedAt, now)
            )
        }
        return try await replica.store.registerHostResource(
            in: group, on: replica.identity,
            resourceID: resourceID, allowedActions: actions, at: now
        )
    }
}

public enum DistributedAgentTerminationFinalizer {
    /// Makes process termination converge even when the requesting controller
    /// disconnects immediately after receiving (or before receiving) a receipt.
    public static func finalize(
        resourceID: MeshResourceID,
        replica: MeshLocalReplica,
        group: MeshTrustGroupID,
        bindings: DistributedHostResourceBindings
    ) async throws {
        let chat = DistributedAgentChat(replica: replica, group: group)
        for membership in try await chat.memberships(
            memberID: resourceID.rawValue
        ) {
            try await chat.leave(
                room: membership.room.name,
                memberID: resourceID.rawValue
            )
        }
        if let resource = try await replica.store.hostResource(
            in: group, hostDeviceID: replica.identity.deviceID,
            resourceID: resourceID
        ), resource.state == .active {
            _ = try await replica.store.retireHostResource(
                in: group, on: replica.identity,
                resourceID: resourceID,
                at: max(
                    resource.updatedAt,
                    MeshHybridTimestamp(
                        wallTimeMilliseconds: Int64(
                            Date().timeIntervalSince1970 * 1_000
                        )
                    )
                )
            )
        }
        try? bindings.remove(resourceID)
        try? DistributedHookCLI.removeLocalObservation(
            memberID: resourceID.rawValue,
            root: replica.rootURL
        )
    }
}

public enum DistributedHostCommandRecovery {
    /// Completes accepted/executing stop commands whose Host process crashed
    /// between journaling, killing tmux, roster cleanup, and signing the final
    /// receipt.
    public static func recover(
        replica: MeshLocalReplica,
        group: MeshTrustGroupID,
        executor: DistributedHostCommandExecutor
    ) async {
        guard let receipts = try? await replica.store.unfinishedCommandReceipts(
            on: replica.identity
        ) else { return }
        for signed in receipts where signed.receipt.action == .stop {
            var receipt = signed
            if receipt.receipt.state == .accepted {
                guard let claim = try? await replica.store.claimExecution(
                    commandID: receipt.receipt.commandID,
                    on: replica.identity,
                    at: recoveryTimestamp(after: receipt.receipt.updatedAt)
                ) else { continue }
                receipt = claim.receipt
                guard claim.shouldExecute else { continue }
            }
            guard receipt.receipt.state == .executing else { continue }
            let outcome = await executor.recoverStop(
                resourceID: receipt.receipt.resourceID
            )
            switch outcome {
            case .executed(let result):
                do {
                    try await DistributedAgentTerminationFinalizer.finalize(
                        resourceID: receipt.receipt.resourceID,
                        replica: replica, group: group,
                        bindings: executor.bindings
                    )
                    _ = try await replica.store.finishExecution(
                        commandID: receipt.receipt.commandID,
                        on: replica.identity, outcome: .executed,
                        at: recoveryTimestamp(after: receipt.receipt.updatedAt),
                        result: result
                    )
                } catch {
                    // Keep the executing receipt durable; the next Host launch
                    // retries the idempotent stop/finalization sequence.
                }
            case .failed(let code):
                _ = try? await replica.store.finishExecution(
                    commandID: receipt.receipt.commandID,
                    on: replica.identity, outcome: .failed,
                    at: recoveryTimestamp(after: receipt.receipt.updatedAt),
                    failureCode: code
                )
            }
        }
    }

    private static func now() -> MeshHybridTimestamp {
        MeshHybridTimestamp(
            wallTimeMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
    }

    /// Receipt timestamps may be ahead of the recovered process's wall clock
    /// after clock correction or in deterministic fault tests. Recovery must
    /// remain monotonic instead of silently leaving the journal executing.
    private static func recoveryTimestamp(
        after previous: MeshHybridTimestamp
    ) -> MeshHybridTimestamp {
        max(previous, now())
    }
}
