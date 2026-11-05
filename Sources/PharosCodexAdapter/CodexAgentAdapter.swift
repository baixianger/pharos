import Foundation
import PharosAgentCore

/// One Agent adapter with one preferred Driver. TUI and future Pharos views are
/// surfaces of the same Codex threads, not separate adapters.
public final class CodexAgentAdapter: AgentAdapter, @unchecked Sendable {
    public let manifest = AgentAdapterManifest(
        id: "pharos.codex",
        agentKind: "codex",
        version: "1",
        preferredDriver: "app-server",
        capabilities: [
            "session-discovery-v1",
            "session-actions-v1",
            "native-tui-surface-v1",
            "codex-app-server-v1",
        ]
    )

    private let driver: CodexAppServerDriver

    public init(eventSink: any AgentEventSink) {
        driver = CodexAppServerDriver(eventSink: eventSink)
    }

    public func availability(for providerSessionID: String?) -> [AgentActionAvailability] {
        let hasSession = providerSessionID?.isEmpty == false
        let missing = "A Codex thread ID is required for this action."
        return [
            AgentActionAvailability(action: .view, state: hasSession ? .available : .unavailable,
                                    reason: hasSession ? nil : missing),
            AgentActionAvailability(action: .attach, state: hasSession ? .available : .unavailable,
                                    reason: hasSession ? nil : missing),
            AgentActionAvailability(action: .resume, state: hasSession ? .available : .unavailable,
                                    reason: hasSession ? nil : missing),
            AgentActionAvailability(action: .relaunch, state: hasSession ? .available : .unavailable,
                                    reason: hasSession ? nil : missing),
            AgentActionAvailability(action: .fork, state: hasSession ? .available : .unavailable,
                                    reason: hasSession ? nil : missing),
            AgentActionAvailability(action: .archive, state: .available,
                                    reason: "Archive is owned by the Pharos session registry."),
        ]
    }

    public func discover(params: [String: Any]) throws -> Any {
        try driver.request(method: "thread/list", params: params)
    }

    public func perform(
        action: AgentSessionAction,
        providerSessionID: String?,
        params: [String: Any]
    ) throws -> Any {
        if action == .archive {
            return ["action": action.rawValue, "state": "accepted", "owner": "pharos-registry"]
        }
        guard let providerSessionID, !providerSessionID.isEmpty else {
            throw AgentAdapterError.invalidParams("providerSessionID")
        }

        var vendorParams = params
        vendorParams["threadId"] = providerSessionID
        switch action {
        case .view:
            vendorParams["includeTurns"] = vendorParams["includeTurns"] ?? true
            return try driver.request(method: "thread/read", params: vendorParams)
        case .resume, .relaunch:
            return try driver.request(method: "thread/resume", params: vendorParams)
        case .fork:
            return try driver.request(method: "thread/fork", params: vendorParams)
        case .attach:
            _ = try driver.prepare()
            return [
                "action": action.rawValue,
                "state": "ready",
                "providerSessionID": providerSessionID,
                "surfaces": try encodedSurfaces(providerSessionID: providerSessionID),
            ]
        case .archive:
            // Unreachable: .archive is resolved by the Pharos session registry
            // before the provider-session guard above.
            throw AgentAdapterError.unsupported("archive is resolved before this switch")
        }
    }

    public func invokeVendor(method: String, params: [String: Any]) throws -> Any {
        let vendorMethod: String
        switch method {
        case "codex.status": return driver.status()
        case "codex.thread.list": vendorMethod = "thread/list"
        case "codex.thread.read": vendorMethod = "thread/read"
        case "codex.thread.start": vendorMethod = "thread/start"
        case "codex.thread.resume": vendorMethod = "thread/resume"
        case "codex.thread.fork": vendorMethod = "thread/fork"
        case "codex.turn.start": vendorMethod = "turn/start"
        case "codex.turn.interrupt": vendorMethod = "turn/interrupt"
        default: throw AgentAdapterError.unsupported(method)
        }
        return try driver.request(method: vendorMethod, params: params)
    }

    private func encodedSurfaces(providerSessionID: String) throws -> Any {
        let surfaces = [
            AgentSurfaceDescriptor(
                kind: "native-tui",
                preferred: true,
                command: "codex",
                arguments: ["resume", providerSessionID, "--remote", "unix://"],
                detail: "Attach the official Codex TUI to the managed App Server daemon."
            ),
        ]
        let data = try JSONEncoder().encode(surfaces)
        return try JSONSerialization.jsonObject(with: data)
    }
}
