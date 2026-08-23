import PharosAgentCore

public final class AgentRuntimeEventSink: AgentEventSink, @unchecked Sendable {
    public init() {}

    public func publish(kind: String, payload: [String: Any]) {
        AgentRuntimeEventJournal.shared.publish(kind: kind, payload: payload)
    }
}
