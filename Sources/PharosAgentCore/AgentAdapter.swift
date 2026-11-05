import Foundation

public enum AgentAdapterError: LocalizedError {
    case invalidParams(String)
    case unavailable(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidParams(let value): "Invalid adapter params: \(value)"
        case .unavailable(let value): value
        case .unsupported(let value): "Unsupported adapter operation: \(value)"
        }
    }
}

public protocol AgentEventSink: Sendable {
    func publish(kind: String, payload: [String: Any])
}

public protocol AgentAdapter: Sendable {
    var manifest: AgentAdapterManifest { get }
    func availability(for providerSessionID: String?) -> [AgentActionAvailability]
    func discover(params: [String: Any]) throws -> Any
    func perform(action: AgentSessionAction, providerSessionID: String?, params: [String: Any]) throws -> Any
    func invokeVendor(method: String, params: [String: Any]) throws -> Any
}
