import Foundation

/// Asynchronous event emitted over the client event stream (`PharosClientService.events()`).
public enum PharosClientEvent: Sendable, Codable, Equatable {
    case sessionUpdated(ClientSessionSummary)
    /// The owning connection was replaced; observers should reload this Session.
    case sessionConnectionRestored(sessionId: String)
    case sessionConfigurationUpdated(sessionId: String)
    case turnStarted(CanonicalTurn)
    case turnCompleted(CanonicalTurn)
    case streamingDelta(CanonicalStreamingDelta)
    case sessionGoalUpdated(sessionId: String, goal: CanonicalSessionGoal?)
    case sessionTodosUpdated(sessionId: String, todos: [CanonicalSessionTodo])
    case approvalRequired(CanonicalApprovalRequest)
    /// Updates details of an existing request; it must not create a new one.
    case approvalUpdated(CanonicalApprovalRequest)
    case approvalResolved(approvalId: String, decision: ApprovalDecision)
    case approvalWithdrawn(approvalId: String)
    case threadMessageReceived(ClientThreadMessage)
    case threadReceiptUpdated(threadId: String, messageId: String, receipt: DeliveryReceiptState)
    case memberStatusChanged(name: String, status: String)
    case backendError(PharosClientError)

    private enum CodingKeys: String, CodingKey {
        case eventType, session, turn, delta, approval, approvalId, decision
        case sessionId, goal, todos
        case threadMessage, threadId, messageId, receipt, memberName, status, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .eventType)
        switch type {
        case "sessionUpdated":
            let s = try container.decode(ClientSessionSummary.self, forKey: .session)
            self = .sessionUpdated(s)
        case "sessionConnectionRestored":
            self = .sessionConnectionRestored(sessionId: try container.decode(String.self, forKey: .sessionId))
        case "sessionConfigurationUpdated":
            self = .sessionConfigurationUpdated(sessionId: try container.decode(String.self, forKey: .sessionId))
        case "turnStarted":
            let t = try container.decode(CanonicalTurn.self, forKey: .turn)
            self = .turnStarted(t)
        case "turnCompleted":
            let t = try container.decode(CanonicalTurn.self, forKey: .turn)
            self = .turnCompleted(t)
        case "streamingDelta":
            let d = try container.decode(CanonicalStreamingDelta.self, forKey: .delta)
            self = .streamingDelta(d)
        case "sessionGoalUpdated":
            let id = try container.decode(String.self, forKey: .sessionId)
            self = .sessionGoalUpdated(sessionId: id, goal: try container.decodeIfPresent(CanonicalSessionGoal.self, forKey: .goal))
        case "sessionTodosUpdated":
            let id = try container.decode(String.self, forKey: .sessionId)
            self = .sessionTodosUpdated(sessionId: id, todos: try container.decode([CanonicalSessionTodo].self, forKey: .todos))
        case "approvalRequired":
            let a = try container.decode(CanonicalApprovalRequest.self, forKey: .approval)
            self = .approvalRequired(a)
        case "approvalUpdated":
            self = .approvalUpdated(try container.decode(CanonicalApprovalRequest.self, forKey: .approval))
        case "approvalResolved":
            let id = try container.decode(String.self, forKey: .approvalId)
            let dec = try container.decode(ApprovalDecision.self, forKey: .decision)
            self = .approvalResolved(approvalId: id, decision: dec)
        case "approvalWithdrawn":
            self = .approvalWithdrawn(approvalId: try container.decode(String.self, forKey: .approvalId))
        case "threadMessageReceived":
            let m = try container.decode(ClientThreadMessage.self, forKey: .threadMessage)
            self = .threadMessageReceived(m)
        case "threadReceiptUpdated":
            let tid = try container.decode(String.self, forKey: .threadId)
            let mid = try container.decode(String.self, forKey: .messageId)
            let r = try container.decode(DeliveryReceiptState.self, forKey: .receipt)
            self = .threadReceiptUpdated(threadId: tid, messageId: mid, receipt: r)
        case "memberStatusChanged":
            let name = try container.decode(String.self, forKey: .memberName)
            let st = try container.decode(String.self, forKey: .status)
            self = .memberStatusChanged(name: name, status: st)
        case "backendError":
            let err = try container.decode(PharosClientError.self, forKey: .error)
            self = .backendError(err)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .eventType,
                in: container,
                debugDescription: "Unknown client event: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionUpdated(let s):
            try container.encode("sessionUpdated", forKey: .eventType)
            try container.encode(s, forKey: .session)
        case .sessionConnectionRestored(let id):
            try container.encode("sessionConnectionRestored", forKey: .eventType)
            try container.encode(id, forKey: .sessionId)
        case .sessionConfigurationUpdated(let id):
            try container.encode("sessionConfigurationUpdated", forKey: .eventType)
            try container.encode(id, forKey: .sessionId)
        case .turnStarted(let t):
            try container.encode("turnStarted", forKey: .eventType)
            try container.encode(t, forKey: .turn)
        case .turnCompleted(let t):
            try container.encode("turnCompleted", forKey: .eventType)
            try container.encode(t, forKey: .turn)
        case .streamingDelta(let d):
            try container.encode("streamingDelta", forKey: .eventType)
            try container.encode(d, forKey: .delta)
        case .sessionGoalUpdated(let id, let goal):
            try container.encode("sessionGoalUpdated", forKey: .eventType)
            try container.encode(id, forKey: .sessionId)
            try container.encodeIfPresent(goal, forKey: .goal)
        case .sessionTodosUpdated(let id, let todos):
            try container.encode("sessionTodosUpdated", forKey: .eventType)
            try container.encode(id, forKey: .sessionId)
            try container.encode(todos, forKey: .todos)
        case .approvalRequired(let a):
            try container.encode("approvalRequired", forKey: .eventType)
            try container.encode(a, forKey: .approval)
        case .approvalUpdated(let a):
            try container.encode("approvalUpdated", forKey: .eventType)
            try container.encode(a, forKey: .approval)
        case .approvalResolved(let id, let dec):
            try container.encode("approvalResolved", forKey: .eventType)
            try container.encode(id, forKey: .approvalId)
            try container.encode(dec, forKey: .decision)
        case .approvalWithdrawn(let id):
            try container.encode("approvalWithdrawn", forKey: .eventType)
            try container.encode(id, forKey: .approvalId)
        case .threadMessageReceived(let m):
            try container.encode("threadMessageReceived", forKey: .eventType)
            try container.encode(m, forKey: .threadMessage)
        case .threadReceiptUpdated(let tid, let mid, let r):
            try container.encode("threadReceiptUpdated", forKey: .eventType)
            try container.encode(tid, forKey: .threadId)
            try container.encode(mid, forKey: .messageId)
            try container.encode(r, forKey: .receipt)
        case .memberStatusChanged(let name, let st):
            try container.encode("memberStatusChanged", forKey: .eventType)
            try container.encode(name, forKey: .memberName)
            try container.encode(st, forKey: .status)
        case .backendError(let err):
            try container.encode("backendError", forKey: .eventType)
            try container.encode(err, forKey: .error)
        }
    }
}
