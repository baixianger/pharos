import Foundation
import PharosAgentCore
import PharosCodexAdapter
import PharosRuntime
import XCTest

final class AgentAdapterTests: XCTestCase {
    func testCodexAdapterDeclaresOneAgentWithAppServerDriverAndNativeSurface() throws {
        let adapter = CodexAgentAdapter(eventSink: RecordingEventSink())

        XCTAssertEqual(adapter.manifest.id, "pharos.codex")
        XCTAssertEqual(adapter.manifest.agentKind, "codex")
        XCTAssertEqual(adapter.manifest.preferredDriver, "app-server")
        XCTAssertTrue(adapter.manifest.capabilities.contains("native-tui-surface-v1"))

        let missingSession = adapter.availability(for: nil)
        XCTAssertEqual(availability(.resume, in: missingSession)?.state, .unavailable)
        XCTAssertNotNil(availability(.resume, in: missingSession)?.reason)

        let existingSession = adapter.availability(for: "thread-id")
        XCTAssertEqual(availability(.view, in: existingSession)?.state, .available)
        XCTAssertEqual(availability(.attach, in: existingSession)?.state, .available)
        XCTAssertEqual(availability(.resume, in: existingSession)?.state, .available)
        XCTAssertEqual(availability(.fork, in: existingSession)?.state, .available)
    }

    func testCodexSharedAppServerIntegration() throws {
        guard ProcessInfo.processInfo.environment["PHAROS_CODEX_INTEGRATION_TEST"] == "1" else {
            throw XCTSkip("Set PHAROS_CODEX_INTEGRATION_TEST=1 to exercise the installed Codex daemon.")
        }

        let sink = RecordingEventSink()
        let adapter = CodexAgentAdapter(eventSink: sink)
        let result = try adapter.discover(params: ["limit": 1])

        XCTAssertTrue(JSONSerialization.isValidJSONObject(result))
        XCTAssertTrue(sink.events.contains { $0 == "codex.started" })
    }

    func testHostRuntimeRoutesGenericAdapterMethodsOverPrivateSocket() throws {
        let socket = URL(fileURLWithPath: "/tmp/pharos-ar-\(UUID().uuidString.prefix(8)).sock")
        setenv("PHAROS_AGENT_RUNTIME_SOCKET", socket.path, 1)
        defer { unsetenv("PHAROS_AGENT_RUNTIME_SOCKET") }

        let server = AgentRuntimeServer(adapters: [
            CodexAgentAdapter(eventSink: RecordingEventSink()),
        ])
        try server.start()
        defer { server.stop() }

        let adapters = try rpc(method: "adapter.list", params: [:])
        let manifests = try XCTUnwrap(adapters["result"] as? [[String: Any]])
        XCTAssertEqual(manifests.first?["id"] as? String, "pharos.codex")

        let capabilities = try rpc(method: "session.capabilities", params: [
            "adapterID": "pharos.codex",
            "providerSessionID": "thread-id",
        ])
        let actions = try XCTUnwrap(capabilities["result"] as? [[String: Any]])
        XCTAssertTrue(actions.contains {
            $0["action"] as? String == "resume" && $0["state"] as? String == "available"
        })
    }

    private func rpc(method: String, params: [String: Any]) throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let response = try AgentRuntimeClient.send(String(decoding: data, as: UTF8.self))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
    }

    private func availability(
        _ action: AgentSessionAction,
        in values: [AgentActionAvailability]
    ) -> AgentActionAvailability? {
        values.first { $0.action == action }
    }
}

private final class RecordingEventSink: AgentEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func publish(kind: String, payload: [String: Any]) {
        lock.lock()
        storage.append(kind)
        lock.unlock()
    }
}
