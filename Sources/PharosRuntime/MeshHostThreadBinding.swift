import Foundation
import PharosClientKit
import PharosMeshCore

/// Host-visible delivery phases for a directed Thread message.
/// These are distinct from Broker mailbox wakeup and do not claim Agent
/// model completion unless `.replied` was produced by `replyOnce`.
public enum MeshHostThreadDeliveryPhase: String, Codable, Sendable, Equatable {
    case queued
    case delivered
    case consumed
    case replied
    case unknown
}

/// Explicit Host-owned binding between a room member and a local Session /
/// Runtime conversation. Produced only after inventory ownership and Runtime
/// uniqueness checks succeed.
public struct MeshHostThreadBindingRecord: Codable, Equatable, Sendable {
    public var memberID: String
    public var vendorSessionID: String
    public var conversationID: String
    public var agentKind: String
    public var hostSessionID: String

    public init(
        memberID: String, vendorSessionID: String, conversationID: String,
        agentKind: String, hostSessionID: String
    ) {
        self.memberID = memberID
        self.vendorSessionID = vendorSessionID
        self.conversationID = conversationID
        self.agentKind = agentKind
        self.hostSessionID = hostSessionID
    }
}

public struct MeshHostThreadBindPayload: Codable, Equatable, Sendable {
    public var agentKind: String
    public var memberID: String?

    public init(agentKind: String, memberID: String? = nil) {
        self.agentKind = agentKind
        self.memberID = memberID
    }
}

public struct MeshHostThreadInspectPayload: Codable, Equatable, Sendable {
    public var memberID: String?
    public var vendorSessionID: String?

    public init(memberID: String? = nil, vendorSessionID: String? = nil) {
        self.memberID = memberID
        self.vendorSessionID = vendorSessionID
    }
}

/// Binds a Host-owned Session to one Runtime conversation and maps directed
/// message boundaries onto queued / consumed / replied / unknown without
/// touching legacy Broker mailboxes.
public actor MeshHostThreadBinder {
    public typealias Inventory = @Sendable () async throws -> [ClientSessionSummary]
    public typealias RuntimeCall = @Sendable (String, [String: Any]) throws -> Any

    private let inventory: Inventory
    private let runtime: RuntimeCall
    private let driverID: String

    public init(
        inventory: @escaping Inventory,
        runtime: @escaping RuntimeCall,
        driverID: String = "host-thread:" + UUID().uuidString
    ) {
        self.inventory = inventory
        self.runtime = runtime
        self.driverID = driverID
    }

    /// Verify Host inventory ownership, register a Runtime conversation, and
    /// reject ambiguous member or vendor Session claims.
    public func bind(
        hostSessionID: String, agentKind: String, memberID: String? = nil
    ) async throws -> MeshHostThreadBindingRecord {
        let kind = try Self.normalizedAgentKind(agentKind)
        let vendorSessionID = try Self.vendorSessionID(from: hostSessionID, agentKind: kind)
        let sessions = try await inventory()
        guard let match = sessions.first(where: {
            $0.sessionId == hostSessionID || $0.sessionId == "\(kind):\(vendorSessionID)"
                || ($0.agentType == kind && $0.sessionId == vendorSessionID)
        }), match.agentType == kind else {
            throw PharosClientError.operationFailed("Host inventory does not own this Session")
        }
        guard match.inventoryStale != true else {
            throw PharosClientError.operationFailed("Host Session inventory is stale")
        }
        let canonicalHostID = match.sessionId
        let preferredMember = try Self.preferredMemberID(
            kind: kind, vendorSessionID: vendorSessionID, requested: memberID
        )

        // Codex deliveries are owned by the builtin app-server driver. Never
        // register a host-thread driver that would steal or wipe its capabilities.
        let effectiveDriverID = kind == "codex" ? "codex:app-server" : driverID
        if kind != "codex" {
            _ = try runtime("driver.register", [
                "driverID": effectiveDriverID, "kind": kind, "capabilities": ["delivery.poll"],
            ])
        }
        let registered = try runtime("conversation.register", [
            "driverID": effectiveDriverID, "kind": kind,
            "vendorSessionID": vendorSessionID, "memberID": preferredMember,
        ]) as? [String: Any]
        guard let conversationID = registered?["id"] as? String, !conversationID.isEmpty else {
            throw PharosClientError.operationFailed("Runtime did not register the Thread Session")
        }

        let snapshot = try runtime("runtime.snapshot", [:]) as? [String: Any] ?? [:]
        let conversations = snapshot["conversations"] as? [[String: Any]] ?? []
        try Self.validateUniqueConversation(
            conversations, conversationID: conversationID,
            vendorSessionID: vendorSessionID, memberID: preferredMember, kind: kind
        )
        return MeshHostThreadBindingRecord(
            memberID: preferredMember, vendorSessionID: vendorSessionID,
            conversationID: conversationID, agentKind: kind, hostSessionID: canonicalHostID
        )
    }

    /// Read the current Runtime conversation claim for a member or vendor Session.
    public func inspect(
        memberID: String? = nil, vendorSessionID: String? = nil, agentKind: String? = nil
    ) throws -> MeshHostThreadBindingRecord? {
        guard memberID != nil || vendorSessionID != nil else {
            throw PharosClientError.operationFailed("threadBindingInspect requires memberID or vendorSessionID")
        }
        let snapshot = try runtime("runtime.snapshot", [:]) as? [String: Any] ?? [:]
        let conversations = snapshot["conversations"] as? [[String: Any]] ?? []
        let kind = try agentKind.map(Self.normalizedAgentKind)
        let matches = conversations.filter { row in
            if let memberID, row["memberID"] as? String != memberID { return false }
            if let vendorSessionID, row["vendorSessionID"] as? String != vendorSessionID { return false }
            if let kind, row["kind"] as? String != kind { return false }
            return true
        }
        guard matches.count <= 1 else {
            throw PharosClientError.operationFailed("Multiple Runtime conversations match this Thread binding")
        }
        guard let row = matches.first,
              let conversationID = row["id"] as? String, !conversationID.isEmpty,
              let vendor = row["vendorSessionID"] as? String, !vendor.isEmpty,
              let member = row["memberID"] as? String, !member.isEmpty,
              let rowKind = row["kind"] as? String, !rowKind.isEmpty else {
            return nil
        }
        let hostSessionID = rowKind == "codex" ? vendor : "\(rowKind):\(vendor)"
        return MeshHostThreadBindingRecord(
            memberID: member, vendorSessionID: vendor, conversationID: conversationID,
            agentKind: rowKind, hostSessionID: hostSessionID
        )
    }

    /// Map a Runtime delivery ack boundary onto Host Thread phases and, when
    /// the injected/consumed boundary is established, advance the device-local
    /// directed-message receipt. Does not start Agent turns or legacy wakeup.
    public func advanceConsumption(
        chat: DistributedAgentChat, memberID: String, messageID: String,
        runtimeDeliveryState: String
    ) async throws -> MeshHostThreadDeliveryPhase {
        switch runtimeDeliveryState {
        case "queued", "accepted":
            return .queued
        case "injected", "consumed":
            // First ack returns true; duplicate ack returns false. Both mean the
            // Host has an established consume boundary for this directed message.
            _ = try await chat.acknowledge(memberID: memberID, messageID: messageID)
            return .consumed
        case "completed":
            // Runtime completed without a room reply is still only consumption
            // evidence for the Host bridge; callers must check replyOnce separately.
            _ = try? await chat.acknowledge(memberID: memberID, messageID: messageID)
            return .consumed
        default:
            return .unknown
        }
    }

    /// Persist a retry-safe room reply for an explicitly bound member and mark
    /// the Host Thread phase as replied. Room write only — not Agent proof.
    public func commitReply(
        chat: DistributedAgentChat, room: String, memberID: String,
        originalMessageID: String, text: String
    ) async throws -> (MeshHostThreadDeliveryPhase, MeshMsg) {
        let reply = try await chat.replyOnce(
            room: room, memberID: memberID,
            originalMessageID: originalMessageID, text: text
        )
        return (.replied, reply)
    }

    public static func phase(
        runtimeDeliveryState: String?, hasLocalReceipt: Bool, hasRoomReply: Bool
    ) -> MeshHostThreadDeliveryPhase {
        if hasRoomReply { return .replied }
        if hasLocalReceipt { return .consumed }
        guard let runtimeDeliveryState else { return .unknown }
        switch runtimeDeliveryState {
        case "queued", "accepted": return .queued
        case "injected", "consumed", "completed": return .consumed
        case "delivered": return .delivered
        default: return .unknown
        }
    }

    private static func normalizedAgentKind(_ raw: String) throws -> String {
        switch raw.lowercased() {
        case "codex": return "codex"
        case "dsh", "deepseek", "deepseek-harness": return "dsh"
        case "agy", "ag", "antigravity": return "agy"
        default:
            throw PharosClientError.operationFailed("Unsupported Thread agent kind: \(raw)")
        }
    }

    private static func vendorSessionID(from hostSessionID: String, agentKind: String) throws -> String {
        if agentKind == "codex" {
            guard !hostSessionID.isEmpty, !hostSessionID.contains(":") else {
                throw PharosClientError.operationFailed("Codex Host Session ID is invalid")
            }
            return hostSessionID
        }
        let prefix = agentKind + ":"
        if hostSessionID.hasPrefix(prefix) {
            let raw = String(hostSessionID.dropFirst(prefix.count))
            guard !raw.isEmpty else {
                throw PharosClientError.operationFailed("Host Session ID is empty")
            }
            return raw
        }
        guard !hostSessionID.isEmpty else {
            throw PharosClientError.operationFailed("Host Session ID is empty")
        }
        return hostSessionID
    }

    private static func preferredMemberID(
        kind: String, vendorSessionID: String, requested: String?
    ) throws -> String {
        if let requested {
            let value = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 512 else {
                throw PharosClientError.operationFailed("Thread member ID is invalid")
            }
            return value
        }
        switch kind {
        case "codex", "dsh":
            return vendorSessionID
        default:
            return UUID().uuidString.lowercased()
        }
    }

    private static func validateUniqueConversation(
        _ conversations: [[String: Any]], conversationID: String,
        vendorSessionID: String, memberID: String, kind: String
    ) throws {
        let vendorMatches = conversations.filter {
            $0["vendorSessionID"] as? String == vendorSessionID && $0["kind"] as? String == kind
        }
        guard vendorMatches.count == 1, vendorMatches[0]["id"] as? String == conversationID else {
            throw PharosClientError.operationFailed("Runtime vendor Session claim is ambiguous")
        }
        let memberMatches = conversations.filter { $0["memberID"] as? String == memberID }
        guard memberMatches.count == 1, memberMatches[0]["id"] as? String == conversationID else {
            throw PharosClientError.operationFailed("Another Runtime conversation already claims this member")
        }
    }
}
