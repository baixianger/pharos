import Foundation

/// Status of an interactive 1:1 agent session turn.
public enum TurnStatus: String, Sendable, Codable, Equatable {
    case inProgress = "in_progress"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
    case needsHuman = "needs_human"
}

/// A complete conversational turn in an agent session.
public struct CanonicalTurn: Sendable, Codable, Equatable, Identifiable {
    public var id: String { turnId }
    public let turnId: String
    public let sessionId: String
    public let turnNumber: Int
    public let status: TurnStatus
    public let createdAt: Date
    public let completedAt: Date?
    public let steps: [CanonicalStep]
    public let rawVendorPayload: [String: JSONValue]?

    public init(
        turnId: String,
        sessionId: String,
        turnNumber: Int,
        status: TurnStatus,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        steps: [CanonicalStep] = [],
        rawVendorPayload: [String: JSONValue]? = nil
    ) {
        self.turnId = turnId
        self.sessionId = sessionId
        self.turnNumber = turnNumber
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.steps = steps
        self.rawVendorPayload = rawVendorPayload
    }
}

/// Status of an execution step within a turn.
public enum StepStatus: String, Sendable, Codable, Equatable {
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

/// An execution step within a turn, grouping related blocks.
public struct CanonicalStep: Sendable, Codable, Equatable, Identifiable {
    public var id: String { stepId }
    public let stepId: String
    public let stepNumber: Int
    public let status: StepStatus
    public let blocks: [CanonicalBlock]
    public let rawVendorPayload: [String: JSONValue]?

    public init(
        stepId: String,
        stepNumber: Int,
        status: StepStatus,
        blocks: [CanonicalBlock] = [],
        rawVendorPayload: [String: JSONValue]? = nil
    ) {
        self.stepId = stepId
        self.stepNumber = stepNumber
        self.status = status
        self.blocks = blocks
        self.rawVendorPayload = rawVendorPayload
    }
}

/// The kind of content contained inside a canonical block.
public enum CanonicalBlockKind: Sendable, Codable, Equatable {
    case userText(String)
    case assistantText(String)
    case reasoning(CanonicalReasoningBlock)
    case toolCall(CanonicalToolCall)
    case toolResult(CanonicalToolResult)
    case terminalCommand(CanonicalTerminalCommand)
    case filePatch(CanonicalFilePatch)
    case attachment(CanonicalAttachment)

    private enum CodingKeys: String, CodingKey {
        case type, text, reasoning, toolCall, toolResult, terminalCommand, filePatch, attachment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "userText":
            let text = try container.decode(String.self, forKey: .text)
            self = .userText(text)
        case "assistantText":
            let text = try container.decode(String.self, forKey: .text)
            self = .assistantText(text)
        case "reasoning":
            let reasoning = try container.decode(CanonicalReasoningBlock.self, forKey: .reasoning)
            self = .reasoning(reasoning)
        case "toolCall":
            let call = try container.decode(CanonicalToolCall.self, forKey: .toolCall)
            self = .toolCall(call)
        case "toolResult":
            let res = try container.decode(CanonicalToolResult.self, forKey: .toolResult)
            self = .toolResult(res)
        case "terminalCommand":
            let cmd = try container.decode(CanonicalTerminalCommand.self, forKey: .terminalCommand)
            self = .terminalCommand(cmd)
        case "filePatch":
            let patch = try container.decode(CanonicalFilePatch.self, forKey: .filePatch)
            self = .filePatch(patch)
        case "attachment":
            let att = try container.decode(CanonicalAttachment.self, forKey: .attachment)
            self = .attachment(att)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown block kind: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .userText(let text):
            try container.encode("userText", forKey: .type)
            try container.encode(text, forKey: .text)
        case .assistantText(let text):
            try container.encode("assistantText", forKey: .type)
            try container.encode(text, forKey: .text)
        case .reasoning(let reasoning):
            try container.encode("reasoning", forKey: .type)
            try container.encode(reasoning, forKey: .reasoning)
        case .toolCall(let call):
            try container.encode("toolCall", forKey: .type)
            try container.encode(call, forKey: .toolCall)
        case .toolResult(let res):
            try container.encode("toolResult", forKey: .type)
            try container.encode(res, forKey: .toolResult)
        case .terminalCommand(let cmd):
            try container.encode("terminalCommand", forKey: .type)
            try container.encode(cmd, forKey: .terminalCommand)
        case .filePatch(let patch):
            try container.encode("filePatch", forKey: .type)
            try container.encode(patch, forKey: .filePatch)
        case .attachment(let att):
            try container.encode("attachment", forKey: .type)
            try container.encode(att, forKey: .attachment)
        }
    }
}

/// An individual content block within an execution step.
public struct CanonicalBlock: Sendable, Codable, Equatable, Identifiable {
    public var id: String { blockId }
    public let blockId: String
    public let kind: CanonicalBlockKind
    public let rawVendorPayload: [String: JSONValue]?

    public init(
        blockId: String,
        kind: CanonicalBlockKind,
        rawVendorPayload: [String: JSONValue]? = nil
    ) {
        self.blockId = blockId
        self.kind = kind
        self.rawVendorPayload = rawVendorPayload
    }
}

/// Reasoning or thinking block emitted by an LLM.
public struct CanonicalReasoningBlock: Sendable, Codable, Equatable {
    public let thinking: String
    public let summary: String?
    public let durationMs: Int?

    public init(thinking: String, summary: String? = nil, durationMs: Int? = nil) {
        self.thinking = thinking
        self.summary = summary
        self.durationMs = durationMs
    }
}

/// Invocation of a tool or function by the agent.
public struct CanonicalToolCall: Sendable, Codable, Equatable, Identifiable {
    public var id: String { callId }
    public let callId: String
    public let toolName: String
    public let arguments: [String: JSONValue]
    public let rawArguments: String?

    public init(
        callId: String,
        toolName: String,
        arguments: [String: JSONValue],
        rawArguments: String? = nil
    ) {
        self.callId = callId
        self.toolName = toolName
        self.arguments = arguments
        self.rawArguments = rawArguments
    }
}

/// Result of an executed tool call.
public struct CanonicalToolResult: Sendable, Codable, Equatable, Identifiable {
    public var id: String { callId }
    public let callId: String
    public let toolName: String
    public let result: JSONValue
    public let isError: Bool

    public init(
        callId: String,
        toolName: String,
        result: JSONValue,
        isError: Bool = false
    ) {
        self.callId = callId
        self.toolName = toolName
        self.result = result
        self.isError = isError
    }
}

/// Execution of a shell or terminal command.
public struct CanonicalTerminalCommand: Sendable, Codable, Equatable {
    public let command: String
    public let cwd: String?
    public let exitCode: Int?
    public let stdout: String?
    public let stderr: String?

    public init(
        command: String,
        cwd: String? = nil,
        exitCode: Int? = nil,
        stdout: String? = nil,
        stderr: String? = nil
    ) {
        self.command = command
        self.cwd = cwd
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Kind of file modification patch.
public enum PatchKind: String, Sendable, Codable, Equatable {
    case create = "create"
    case modify = "modify"
    case delete = "delete"
}

/// File patch or diff produced by the agent.
public struct CanonicalFilePatch: Sendable, Codable, Equatable {
    public let path: String
    public let kind: PatchKind
    public let diff: String

    public init(path: String, kind: PatchKind, diff: String) {
        self.path = path
        self.kind = kind
        self.diff = diff
    }
}

/// Attachment or artifact associated with a message.
public struct CanonicalAttachment: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let uri: String

    public init(
        id: String,
        filename: String,
        mimeType: String,
        sizeBytes: Int64,
        uri: String
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.uri = uri
    }
}
