import Foundation

/// Interactive approval request triggered when an agent enters `needs_human`.
public struct CanonicalApprovalRequest: Sendable, Codable, Equatable, Identifiable {
    public var id: String { approvalId }
    public let approvalId: String
    public let sessionId: String
    public let kind: ApprovalKind
    /// Choices the backend can accept; nil means an older producer did not specify them.
    public let availableChoices: [ApprovalChoice]?
    public let rawVendorPayload: [String: JSONValue]?

    public init(
        approvalId: String,
        sessionId: String,
        kind: ApprovalKind,
        availableChoices: [ApprovalChoice]? = nil,
        rawVendorPayload: [String: JSONValue]? = nil
    ) {
        self.approvalId = approvalId
        self.sessionId = sessionId
        self.kind = kind
        self.availableChoices = availableChoices
        self.rawVendorPayload = rawVendorPayload
    }
}

/// The kind of human approval required.
public enum ApprovalKind: Sendable, Codable, Equatable {
    case toolPermission(toolName: String, params: [String: JSONValue], explanation: String?)
    case structuredQuestionnaire(intent: String, questions: [CanonicalQuestionOption])

    private enum CodingKeys: String, CodingKey {
        case type, toolName, params, explanation, intent, questions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "toolPermission":
            let tool = try container.decode(String.self, forKey: .toolName)
            let params = try container.decode([String: JSONValue].self, forKey: .params)
            let exp = try container.decodeIfPresent(String.self, forKey: .explanation)
            self = .toolPermission(toolName: tool, params: params, explanation: exp)
        case "structuredQuestionnaire":
            let intent = try container.decode(String.self, forKey: .intent)
            let questions = try container.decode([CanonicalQuestionOption].self, forKey: .questions)
            self = .structuredQuestionnaire(intent: intent, questions: questions)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown approval kind: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .toolPermission(let tool, let params, let explanation):
            try container.encode("toolPermission", forKey: .type)
            try container.encode(tool, forKey: .toolName)
            try container.encode(params, forKey: .params)
            try container.encodeIfPresent(explanation, forKey: .explanation)
        case .structuredQuestionnaire(let intent, let questions):
            try container.encode("structuredQuestionnaire", forKey: .type)
            try container.encode(intent, forKey: .intent)
            try container.encode(questions, forKey: .questions)
        }
    }
}

/// A structured question within a questionnaire approval request.
public struct CanonicalQuestionOption: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let question: String
    public let options: [String]
    public let isMultiSelect: Bool
    public let allowsFreeText: Bool?
    public let isSecret: Bool?

    public init(id: String, question: String, options: [String], isMultiSelect: Bool = false,
                allowsFreeText: Bool? = nil, isSecret: Bool? = nil) {
        self.id = id
        self.question = question
        self.options = options
        self.isMultiSelect = isMultiSelect
        self.allowsFreeText = allowsFreeText
        self.isSecret = isSecret
    }
}

/// User's resolution choice for an approval request.
public enum ApprovalChoice: String, Sendable, Codable, Equatable {
    case allowedOnce = "allowed_once"
    case allowedAlways = "allowed_always"
    case rejected = "rejected"
    /// Deny the action and interrupt the current turn when the provider offers it.
    case cancelled = "cancelled"
}

/// Full decision payload delivered to resolve an approval request.
public struct ApprovalDecision: Sendable, Codable, Equatable {
    public let choice: ApprovalChoice
    public let answers: [String: [String]]?

    public init(choice: ApprovalChoice, answers: [String: [String]]? = nil) {
        self.choice = choice
        self.answers = answers
    }
}
