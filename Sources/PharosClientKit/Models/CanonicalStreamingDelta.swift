import Foundation

/// Real-time incremental delta streamed during a live 1:1 session turn.
public struct CanonicalStreamingDelta: Sendable, Codable, Equatable {
    public let sessionId: String
    public let turnId: String
    public let stepId: String?
    public let blockId: String?
    public let deltaType: DeltaType

    public init(
        sessionId: String,
        turnId: String,
        stepId: String? = nil,
        blockId: String? = nil,
        deltaType: DeltaType
    ) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.stepId = stepId
        self.blockId = blockId
        self.deltaType = deltaType
    }
}

/// The specific variety of streaming delta.
public enum DeltaType: Sendable, Codable, Equatable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallDelta(callId: String, chunk: String)
    case terminalOutputDelta(String)

    private enum CodingKeys: String, CodingKey {
        case kind, text, callId, chunk
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "textDelta":
            let text = try container.decode(String.self, forKey: .text)
            self = .textDelta(text)
        case "reasoningDelta":
            let text = try container.decode(String.self, forKey: .text)
            self = .reasoningDelta(text)
        case "toolCallDelta":
            let callId = try container.decode(String.self, forKey: .callId)
            let chunk = try container.decode(String.self, forKey: .chunk)
            self = .toolCallDelta(callId: callId, chunk: chunk)
        case "terminalOutputDelta":
            let text = try container.decode(String.self, forKey: .text)
            self = .terminalOutputDelta(text)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown delta kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .textDelta(let text):
            try container.encode("textDelta", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .reasoningDelta(let text):
            try container.encode("reasoningDelta", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .toolCallDelta(let callId, let chunk):
            try container.encode("toolCallDelta", forKey: .kind)
            try container.encode(callId, forKey: .callId)
            try container.encode(chunk, forKey: .chunk)
        case .terminalOutputDelta(let text):
            try container.encode("terminalOutputDelta", forKey: .kind)
            try container.encode(text, forKey: .text)
        }
    }
}
