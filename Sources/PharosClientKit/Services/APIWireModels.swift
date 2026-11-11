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

// MARK: - Wave-2 web endpoints (docs/2026-11-11_web-endpoints-api.md)

/// `GET/PATCH /api/v1/sessions/{id}/config` response.
struct APISessionConfig: Decodable, Sendable {
    struct Mode: Decodable, Sendable {
        let value: String
        let name: String
    }

    struct Capabilities: Decodable, Sendable {
        let attachments: Bool
        let commands: Bool
        let stop: Bool
        let revive: Bool
    }

    let sessionId: String
    let supported: Bool
    let supportedFields: [String]
    let model: String?
    let mode: String?
    let models: [String]
    let modes: [Mode]
    let capabilities: Capabilities
    let readonly: Bool

    private enum CodingKeys: String, CodingKey {
        case sessionId, supported, supportedFields, model, mode, models, modes, capabilities, readonly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        supported = try container.decodeIfPresent(Bool.self, forKey: .supported) ?? false
        supportedFields = try container.decodeIfPresent([String].self, forKey: .supportedFields) ?? []
        model = try container.decodeIfPresent(String.self, forKey: .model)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
        modes = try container.decodeIfPresent([Mode].self, forKey: .modes) ?? []
        capabilities = try container.decodeIfPresent(Capabilities.self, forKey: .capabilities)
            ?? Capabilities(attachments: false, commands: false, stop: false, revive: false)
        readonly = try container.decodeIfPresent(Bool.self, forKey: .readonly) ?? true
    }

    func asClient() -> ClientSessionConfiguration {
        ClientSessionConfiguration(
            sessionId: sessionId,
            supported: supported,
            supportedFields: supportedFields,
            model: model,
            mode: mode,
            models: models,
            modes: modes.map { ClientSessionConfiguration.Mode(value: $0.value, name: $0.name) },
            capabilities: ClientSessionConfiguration.Capabilities(
                attachments: capabilities.attachments,
                commands: capabilities.commands,
                stop: capabilities.stop,
                revive: capabilities.revive
            ),
            readonly: readonly
        )
    }
}

/// `POST /api/v1/sessions/{id}/stop|revive` response (decoded but not required).
struct APISessionLifecycleResponse: Decodable, Sendable {
    let ok: Bool?
    let sessionId: String?
    let status: String?
}

/// `GET/PATCH /api/v1/members/{id}` and `PUT /members/{id}/avatar` response.
struct APIMemberSettingsView: Decodable, Sendable {
    struct Avatar: Decodable, Sendable {
        let avatarId: String?
        let contentType: String?
        let sizeBytes: Int?
        let sha256: String?
    }

    let memberId: String?
    let displayName: String?
    let model: String?
    let mode: String?
    let avatarShape: String?
    let avatarColor: String?
    let avatar: Avatar?
}

/// `GET /api/v1/threads/{id}/members` one member.
struct APIThreadMember: Decodable, Sendable {
    let memberId: String
    let nick: String?
    let agentType: String?
    let machineId: String?
    let status: String?
    let sessionId: String?
    let settings: APIMemberSettingsView?

    func asClient() -> ClientMemberDetail {
        let name = nick ?? memberId
        let displayName = settings?.displayName
        return ClientMemberDetail(
            name: name,
            agent: agentType ?? "",
            machine: machineId ?? "",
            model: settings?.model ?? "",
            mode: settings?.mode ?? "",
            status: status ?? "",
            tmuxSession: nil,
            avatarSeed: displayName ?? nick ?? memberId,
            displayName: displayName,
            avatarShape: settings?.avatarShape,
            avatarColor: settings?.avatarColor,
            sessionId: sessionId
        )
    }
}

/// One attachment metadata item (`POST` upload / `GET` attachment/list).
struct APIAttachment: Decodable, Sendable {
    let attachmentId: String
    let sessionId: String
    let filename: String
    let contentType: String
    let sizeBytes: Int
    let sha256: String
    let createdAt: String

    func asClient() -> ClientAttachment {
        ClientAttachment(
            attachmentId: attachmentId,
            sessionId: sessionId,
            filename: filename,
            contentType: contentType,
            sizeBytes: sizeBytes,
            sha256: sha256,
            createdAt: APIDate.parse(createdAt)
        )
    }
}

/// `GET /api/v1/sessions/{id}/attachments` response.
struct APIAttachmentListResponse: Decodable, Sendable {
    let attachments: [APIAttachment]
}

/// `POST /api/v1/sessions/{id}/attachments` request body.
struct APIUploadAttachmentRequest: Encodable, Sendable {
    let filename: String
    let contentType: String
    let dataBase64: String
}

/// `POST /api/v1/sessions/{id}/messages` body superset with `attachmentIds`.
struct APISendSessionMessageWithAttachmentsRequest: Encodable, Sendable {
    let text: String
    let requestId: String?
    let attachmentIds: [String]
}

/// `PUT /api/v1/threads/{id}/bindings/{member}` body.
struct APIBindThreadSessionRequest: Encodable, Sendable {
    let sessionId: String
}

/// `GET /api/v1/approvals?state=pending` snapshot response.
struct APIApprovalListResponse: Decodable, Sendable {
    /// Flat pending-approval items carry more fields (`state`, `createdAt`,
    /// `expiresAt`); they are ignored by this DTO.
    let approvals: [APIApprovalRequest]
}

/// `POST /api/v1/sessions/{id}/approval` questionnaire answer item.
struct APIQuestionnaireAnswer: Encodable, Sendable, Equatable {
    let questionId: String
    let selected: [String]
    let text: String?
}

/// `PUT /api/v1/members/{id}/avatar` body.
struct APIUploadAvatarRequest: Encodable, Sendable {
    let contentType: String
    let dataBase64: String
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
        case .cancelled: return "cancelled"
        }
    }
}
