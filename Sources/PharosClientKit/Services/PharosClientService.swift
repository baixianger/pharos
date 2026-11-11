import Foundation

public struct SessionFileUpload: Sendable, Equatable {
    public let name: String
    public let data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}

/// Errors surfaced by the Pharos client service to presentation consumers.
public enum PharosClientError: Error, Sendable, Codable, Equatable {
    /// Explicit error surfaced when a vendor backend daemon is unreachable or restarted.
    /// In compliance with GOAL.md 16:18, messages are never silently dropped.
    case backendUnreachable(backend: String, reason: String)
    case sessionNotFound(String)
    case threadNotFound(String)
    case approvalNotFound(String)
    case connectionFailed(String)
    case operationFailed(String)

    private enum CodingKeys: String, CodingKey {
        case code, backend, reason, id, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(String.self, forKey: .code)
        switch code {
        case "backendUnreachable":
            let b = try container.decode(String.self, forKey: .backend)
            let r = try container.decode(String.self, forKey: .reason)
            self = .backendUnreachable(backend: b, reason: r)
        case "sessionNotFound":
            let id = try container.decode(String.self, forKey: .id)
            self = .sessionNotFound(id)
        case "threadNotFound":
            let id = try container.decode(String.self, forKey: .id)
            self = .threadNotFound(id)
        case "approvalNotFound":
            let id = try container.decode(String.self, forKey: .id)
            self = .approvalNotFound(id)
        case "connectionFailed":
            let msg = try container.decode(String.self, forKey: .message)
            self = .connectionFailed(msg)
        case "operationFailed":
            let msg = try container.decode(String.self, forKey: .message)
            self = .operationFailed(msg)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .code,
                in: container,
                debugDescription: "Unknown error code: \(code)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .backendUnreachable(let backend, let reason):
            try container.encode("backendUnreachable", forKey: .code)
            try container.encode(backend, forKey: .backend)
            try container.encode(reason, forKey: .reason)
        case .sessionNotFound(let id):
            try container.encode("sessionNotFound", forKey: .code)
            try container.encode(id, forKey: .id)
        case .threadNotFound(let id):
            try container.encode("threadNotFound", forKey: .code)
            try container.encode(id, forKey: .id)
        case .approvalNotFound(let id):
            try container.encode("approvalNotFound", forKey: .code)
            try container.encode(id, forKey: .id)
        case .connectionFailed(let message):
            try container.encode("connectionFailed", forKey: .code)
            try container.encode(message, forKey: .message)
        case .operationFailed(let message):
            try container.encode("operationFailed", forKey: .code)
            try container.encode(message, forKey: .message)
        }
    }
}

public struct SessionCommandResult: Sendable, Equatable {
    public let text: String
    public init(text: String) { self.text = text }
}

/// Optional capability of a Host-backed client, separate from thread/project APIs.
public protocol HostSessionInventoryReporting: Sendable {
    func hostAgentInventory() async throws -> HostSessionInventoryStatus
}

public protocol HostSessionInventorySnapshotReporting: Sendable {
    func fetchHostSessionInventorySnapshot() async throws -> HostSessionInventorySnapshot
}

/// Host-local project UUID to checkout path; identity is supplied by the
/// authenticated peer transport, not by paths or machine display names.
public protocol HostProjectCheckoutReporting: Sendable {
    func fetchHostProjectCheckouts() async throws -> [UUID: String]
}

/// The unified versioned client service contract powering the Pharos desktop UI.
/// Pure presentation components communicate exclusively through this protocol.
public protocol PharosClientService: Sendable {
    func fetchSessions() async throws -> [ClientSessionSummary]
    func fetchSessionInventoryIssues() async -> [ClientSessionInventoryIssue]
    func fetchThreads() async throws -> [ClientThreadSummary]
    func supportsThreadSessionBinding() async -> Bool
    func threadSessionBindingCandidates() async -> [ClientSessionSummary]
    func bindThreadSession(threadId: String, sessionId: String, nickname: String) async throws
    func fetchProjects() async throws -> [ClientProjectSummary]
    func fetchSessionHistory(sessionId: String) async throws -> [CanonicalTurn]
    func fetchSessionConfiguration(sessionId: String) async throws -> [JSONValue]?
    func supportsSessionTextAttachments(sessionId: String) async -> Bool
    func setSessionConfiguration(sessionId: String, configId: String, value: String) async throws -> [JSONValue]
    func fetchSessionProgress(sessionId: String) async throws -> CanonicalSessionProgress?
    func fetchSessionApproval(sessionId: String) async throws -> CanonicalApprovalRequest?
    func fetchThreadMessages(threadId: String) async throws -> [ClientThreadMessage]
    func fetchMemberDetail(name: String) async throws -> ClientMemberDetail

    // 1:1 Session actions (live streaming, steering, approvals)
    func executeSessionCommand(sessionId: String, line: String) async throws -> SessionCommandResult?
    func sendSessionMessage(sessionId: String, text: String) async throws -> CanonicalTurn
    func sendSessionMessage(sessionId: String, text: String, files: [SessionFileUpload], requestId: String) async throws -> CanonicalTurn
    func steerSession(sessionId: String, text: String) async throws
    func resolveSessionApproval(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws

    // Thread Roster actions (reliable delivery, fanout, receipts)
    func sendThreadMessage(threadId: String, text: String) async throws -> ClientThreadMessage

    // Member administration
    func setMemberMode(name: String, mode: String) async throws
    func setMemberModel(name: String, model: String) async throws
    func setMemberAvatar(name: String, avatar: ClientAvatarInfo) async throws
    func stopMember(name: String) async throws
    func reviveMember(name: String) async throws

    /// Async stream of real-time client events.
    func events() -> AsyncStream<PharosClientEvent>
}

public extension PharosClientService {
    func supportsThreadSessionBinding() async -> Bool { false }
    func threadSessionBindingCandidates() async -> [ClientSessionSummary] { [] }
    func bindThreadSession(threadId: String, sessionId: String, nickname: String) async throws {
        throw PharosClientError.operationFailed("Adding a Session to this Thread is unavailable")
    }
    func supportsSessionTextAttachments(sessionId: String) async -> Bool { false }
    func sendSessionMessage(sessionId: String, text: String, files: [SessionFileUpload], requestId: String) async throws -> CanonicalTurn {
        guard files.isEmpty else { throw PharosClientError.operationFailed("Attachments are unavailable for this agent") }
        return try await sendSessionMessage(sessionId: sessionId, text: text)
    }
    func fetchSessionConfiguration(sessionId: String) async throws -> [JSONValue]? { nil }
    func setSessionConfiguration(sessionId: String, configId: String, value: String) async throws -> [JSONValue] {
        throw PharosClientError.operationFailed("Session configuration is unavailable")
    }
    func fetchSessionInventoryIssues() async -> [ClientSessionInventoryIssue] { [] }
    func executeSessionCommand(sessionId: String, line: String) async throws -> SessionCommandResult? {
        throw PharosClientError.operationFailed("Session commands are unavailable in the Rust API")
    }
    func fetchSessionProgress(sessionId: String) async throws -> CanonicalSessionProgress? { nil }
    func fetchSessionApproval(sessionId: String) async throws -> CanonicalApprovalRequest? { nil }
}
