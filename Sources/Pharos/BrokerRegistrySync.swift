import Foundation
import PharosMeshCore

enum BrokerRegistryEvent: Sendable {
    case synced(revision: String)
    case remote(MeshRegistrySnapshot)
    case offline(message: String)
    case conflict(remote: MeshRegistrySnapshot, localPayload: String)
}

/// Serial, optimistic-concurrency bridge between the UI's local cache and the
/// Broker-owned registry. Only one write is in flight; rapid UI saves coalesce
/// to the newest snapshot. Failed network writes remain pending for retry, and
/// a CAS conflict preserves the local payload instead of overwriting either
/// side silently.
final class BrokerRegistrySync: @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.pai.pharos.registry-sync", qos: .utility)
    private let onEvent: @Sendable (BrokerRegistryEvent) -> Void
    private var revision: String?
    private var pendingPayload: String?
    private var draining = false
    private var blockedByConflict = false

    init(revision: String?, onEvent: @escaping @Sendable (BrokerRegistryEvent) -> Void) {
        self.revision = revision
        self.onEvent = onEvent
    }

    func bootstrap() -> MeshRegistrySnapshot? {
        queue.sync {
            guard let snapshot = try? MeshClient.fetchRegistry() else { return nil }
            revision = snapshot.revision
            return snapshot
        }
    }

    func submit(_ payload: String) {
        queue.async {
            guard !self.blockedByConflict else { return }
            self.pendingPayload = payload
            self.drain()
        }
    }

    func acceptRemoteAfterConflict() {
        queue.async { self.blockedByConflict = false }
    }

    func retryAndRefresh() {
        queue.async {
            guard !self.blockedByConflict else { return }
            if self.pendingPayload != nil {
                self.drain()
                return
            }
            do {
                let snapshot = try MeshClient.fetchRegistry()
                guard snapshot.revision != self.revision else { return }
                self.revision = snapshot.revision
                self.onEvent(.remote(snapshot))
            } catch {
                self.onEvent(.offline(message: error.localizedDescription))
            }
        }
    }

    private func drain() {
        guard !draining, let payload = pendingPayload else { return }
        draining = true
        pendingPayload = nil
        do {
            if revision == nil { revision = try MeshClient.fetchRegistry().revision }
            let next = try MeshClient.replaceRegistry(payload: payload, expectedRevision: revision!)
            revision = next
            draining = false
            onEvent(.synced(revision: next))
            if pendingPayload != nil { drain() }
        } catch MeshRegistryError.conflict {
            let remote = try? MeshClient.fetchRegistry()
            if let remote {
                revision = remote.revision
                pendingPayload = nil
                blockedByConflict = true
                onEvent(.conflict(remote: remote, localPayload: payload))
            } else {
                pendingPayload = pendingPayload ?? payload
                onEvent(.offline(message: "Registry conflict detected, but the Broker could not be reloaded."))
            }
            draining = false
        } catch {
            pendingPayload = pendingPayload ?? payload
            draining = false
            onEvent(.offline(message: error.localizedDescription))
        }
    }
}
