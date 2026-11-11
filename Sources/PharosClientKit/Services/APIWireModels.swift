import Foundation

/// Wire DTOs mirroring `pharos-api` CONTRACTS_VERSION 0.1.0 JSON (camelCase).
/// Mapped into the richer ClientKit presentation models used by SwiftUI.

struct APIErrorBody: Decodable, Sendable {
    let error: APIPharosError
    let contractsVersion: String?
}

struct APIPharosError: Decodable, Sendable {
    let code: String?
    let backend: String?
    let reason: String?
    let id: String?
    let message: String?

    func asClientError(fallback: String) -> PharosClientError {
        switch code {
        case "backendUnreachable":
            return .backendUnreachable(backend: backend ?? "unknown", reason: reason ?? fallback)
        case "sessionNotFound":
            return .sessionNotFound(id ?? fallback)
        case "threadNotFound":
            return .threadNotFound(id ?? fallback)
        case "approvalNotFound":
            return .approvalNotFound(id ?? fallback)
        case "connectionFailed":
            return .connectionFailed(message ?? fallback)
        case "operationFailed", "invalidRequest", "conflict":
            return .operationFailed(message ?? fallback)
        default:
            return .operationFailed(message ?? fallback)
        }
    }
}

struct APIHealthResponse: Decodable, Sendable {
    let ok: Bool
    let contractsVersion: String
    let service: String
}

struct APISessionSummary: Decodable, Sendable {
    let sessionId: String
    let machineId: String
    let agentType: String
    let workspacePath: String
    let title: String
    let status: String
    let latestMessagePreview: String?
    let updatedAt: String
    let avatarSeed: String
    let inventoryStale: Bool?
    let connectionRoute: String?

    func asClient() -> ClientSessionSummary {
        ClientSessionSummary(
            sessionId: sessionId,
            machineId: machineId,
            agentType: agentType,
            workspacePath: workspacePath,
            title: title,
            status: SessionActivityStatus(apiValue: status),
            latestMessagePreview: latestMessagePreview,
            updatedAt: APIDate.parse(updatedAt),
            avatarSeed: avatarSeed, inventoryStale: inventoryStale, connectionRoute: connectionRoute
        )
    }
}

struct APIThreadSummary: Decodable, Sendable {
    let threadId: String
    let title: String
    let memberIds: [String]
    let unreadCount: UInt32
    let lastActivityAt: String

    func asClient() -> ClientThreadSummary {
        ClientThreadSummary(
            threadId: threadId,
            title: title,
            memberIds: memberIds,
            unreadCount: Int(unreadCount),
            lastActivityAt: APIDate.parse(lastActivityAt)
        )
    }
}

struct APIProjectSummary: Decodable, Sendable {
    let projectId: String?
    let projectPath: String
    let name: String
    let trackedDevices: [String]
    let activeSessionsCount: UInt32
    let relatedSessionIds: [String]?

    func asClient() -> ClientProjectSummary {
        ClientProjectSummary(
            projectPath: projectPath,
            name: name,
            trackedDevices: trackedDevices,
            activeSessionsCount: Int(activeSessionsCount), projectId: projectId, relatedSessionIds: relatedSessionIds
        )
    }
}

struct APIThreadMessage: Decodable, Sendable {
    let id: String
    let threadId: String
    let senderId: String
    let senderName: String
    let senderAvatarSeed: String?
    let text: String
    let timestamp: String
    let receipt: String
    let targetMemberIds: [String]?
    let replyTo: APIThreadReply?

    func asClient() -> ClientThreadMessage {
        ClientThreadMessage(
            id: id,
            threadId: threadId,
            senderId: senderId,
            senderName: senderName,
            senderAvatarSeed: senderAvatarSeed,
            text: text,
            timestamp: APIDate.parse(timestamp),
            receipt: DeliveryReceiptState(apiValue: receipt),
            replyTo: replyTo.map { ClientThreadReply(messageId: $0.messageId, senderName: $0.senderName, preview: $0.preview) }
        )
    }
}

struct APIThreadReply: Decodable, Sendable {
    let messageId: String
    let senderName: String
    let preview: String
}

/// Compact turn DTO from pharos-api (assistantText[], no full block tree yet).
struct APICanonicalTurn: Decodable, Sendable {
    let turnId: String
    let sessionId: String
    let turnNumber: UInt32
    let status: String
    let createdAt: String
    let completedAt: String?
    let assistantText: [String]?

    func asClient() -> CanonicalTurn {
        let texts = assistantText ?? []
        let blocks: [CanonicalBlock] = texts.enumerated().map { index, text in
            CanonicalBlock(blockId: "\(turnId)-a\(index)", kind: .assistantText(text))
        }
        let steps: [CanonicalStep]
        if blocks.isEmpty {
            steps = []
        } else {
            steps = [
                CanonicalStep(
                    stepId: "\(turnId)-step1",
                    stepNumber: 1,
                    status: .completed,
                    blocks: blocks
                ),
            ]
        }
        return CanonicalTurn(
            turnId: turnId,
            sessionId: sessionId,
            turnNumber: Int(turnNumber),
            status: TurnStatus(apiValue: status),
            createdAt: APIDate.parse(createdAt),
            completedAt: completedAt.map(APIDate.parse),
            steps: steps
        )
    }
}

struct APIApprovalRequest: Decodable, Sendable {
    let approvalId: String
    let sessionId: String
    let kind: APIApprovalKind
    let availableChoices: [String]?

    func asClient() -> CanonicalApprovalRequest {
        CanonicalApprovalRequest(
            approvalId: approvalId,
            sessionId: sessionId,
            kind: kind.asClient(),
            availableChoices: availableChoices.map { $0.compactMap { value in
                switch value {
                case "allowedOnce": return .allowedOnce
                case "allowedAlways": return .allowedAlways
                default: return ApprovalChoice(rawValue: value)
                }
            } }
        )
    }
}

struct APIApprovalKind: Decodable, Sendable {
    let type: String
    let toolName: String?
    let params: [String: JSONValue]?
    let explanation: String?
    let intent: String?
    let questions: [APIQuestionOption]?

    func asClient() -> ApprovalKind {
        switch type {
        case "toolPermission":
            return .toolPermission(
                toolName: toolName ?? "tool",
                params: params ?? [:],
                explanation: explanation
            )
        case "structuredQuestionnaire":
            return .structuredQuestionnaire(
                intent: intent ?? "questionnaire",
                questions: (questions ?? []).map { $0.asClient() }
            )
        default:
            return .toolPermission(toolName: type, params: [:], explanation: explanation)
        }
    }
}

struct APIQuestionOption: Decodable, Sendable {
    let id: String
    let question: String
    let options: [String]
    let isMultiSelect: Bool

    func asClient() -> CanonicalQuestionOption {
        CanonicalQuestionOption(
            id: id,
            question: question,
            options: options,
            isMultiSelect: isMultiSelect
        )
    }
}

enum APIDate {
    static func parse(_ raw: String) -> Date {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: raw) ?? Date()
    }
}

extension SessionActivityStatus {
    init(apiValue: String) {
        switch apiValue {
        case "idle": self = .idle
        case "working": self = .working
        case "needs_human": self = .needsHuman
        case "stopped": self = .stopped
        default: self = .unknown
        }
    }
}

extension TurnStatus {
    init(apiValue: String) {
        switch apiValue {
        case "in_progress": self = .inProgress
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "needs_human": self = .needsHuman
        default: self = .completed
        }
    }
}

extension DeliveryReceiptState {
    init(apiValue: String) {
        switch apiValue {
        case "pending": self = .pending
        case "delivered": self = .delivered
        case "consumed": self = .consumed
        case "unverified_fallback": self = .unverifiedFallback
        default: self = .pending
        }
    }
}

extension ApprovalChoice {
    /// pharos-api `ApprovalDecision` serializes as camelCase variant names.
    var apiDecisionValue: String? {
        switch self {
        case .allowedOnce: return "allowedOnce"
        case .allowedAlways: return "allowedAlways"
        case .rejected: return "rejected"
        case .cancelled: return nil
        }
    }
}
