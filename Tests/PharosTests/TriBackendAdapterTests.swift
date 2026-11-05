import XCTest
import Foundation
import PharosClientKit
@testable import PharosRuntime

final class TriBackendAdapterTests: XCTestCase {

    // MARK: - Capability Registry Tests

    func testCapabilityRegistryRetrievalAndDegradation() {
        let registry = BackendCapabilityRegistry.shared
        
        let codexCaps = registry.capabilities(for: "codex")
        XCTAssertFalse(codexCaps.supportsRuntimeModelSwitch)
        XCTAssertEqual(codexCaps.deliveryGuarantee, .socketConfirmed)
        XCTAssertTrue(codexCaps.supportsStreamingReplies)

        let agyCaps = registry.capabilities(for: "agy")
        XCTAssertTrue(agyCaps.supportsRuntimeModelSwitch)
        XCTAssertEqual(agyCaps.deliveryGuarantee, .acpConfirmed)
        XCTAssertTrue(agyCaps.supportsStreamingReplies)

        let dshCaps = registry.capabilities(for: "dsh")
        XCTAssertTrue(dshCaps.supportsRuntimeModelSwitch)
        XCTAssertEqual(dshCaps.deliveryGuarantee, .inProcessAck)
        XCTAssertTrue(dshCaps.supportsStreamingReplies)

        // Version verification & degradation check
        let codexCheck = registry.verifyVersion(backend: "codex", detectedVersion: "0.166.0")
        XCTAssertEqual(codexCheck.status, .pinned)

        let oldCodexCheck = registry.verifyVersion(backend: "codex", detectedVersion: "0.150.0")
        if case .compatibleWithDegradation(let warning) = oldCodexCheck.status {
            XCTAssertTrue(warning.contains("WARNING") || warning.contains("mismatch"))
        } else {
            XCTFail("Expected .compatibleWithDegradation")
        }

        let dshCheck = registry.verifyVersion(backend: "dsh", detectedVersion: "0.2.1-rc.5")
        XCTAssertEqual(dshCheck.status, .pinned)
    }

    // MARK: - Codex Backend Adapter Tests

    func testCodexBackendAdapterLifecycleAndStreaming() async throws {
        let simTransport = SimulatedCodexTransport(isConnected: true)
        let adapter = CodexBackendAdapter(transport: simTransport)
        let sessionId = "ses_cx_test_1"

        let events = adapter.observeSessionEvents(sessionId: sessionId)

        let startTurn = try await adapter.startSession(
            sessionId: sessionId,
            workspacePath: "/tmp/cx_ws",
            model: "gpt-4o",
            mode: "yolo"
        )
        XCTAssertEqual(startTurn.turnNumber, 1)
        XCTAssertEqual(startTurn.sessionId, sessionId)

        let promptTurn = try await adapter.sendSessionPrompt(
            sessionId: sessionId,
            prompt: "Refactor database client",
            mode: .queue
        )
        XCTAssertEqual(promptTurn.turnNumber, 2)

        try await adapter.interruptSession(sessionId: sessionId)
        try await adapter.selectSessionModel(sessionId: sessionId, model: "gpt-4.5")

        let receipt = try await adapter.deliverThreadMessage(
            threadId: "th_cx_1",
            message: ClientThreadMessage(
                id: "msg_cx_1",
                threadId: "th_cx_1",
                senderId: "human_1",
                senderName: "User",
                senderAvatarSeed: "user_seed",
                text: "Hello Codex"
            )
        )
        XCTAssertEqual(receipt, .delivered)

        // Simulate incoming streaming delta notification from daemon
        simTransport.emitNotification([
            "method": "item/agentMessage/delta",
            "params": [
                "threadId": "th_sim_placeholder",
                "turnId": promptTurn.turnId,
                "delta": "Refactoring completed."
            ]
        ])

        // Verify observed events
        var receivedCount = 0
        for await event in events {
            receivedCount += 1
            if case .turnStarted(let t) = event {
                XCTAssertEqual(t.sessionId, sessionId)
            }
            if receivedCount >= 2 { // startTurn + promptTurn
                break
            }
        }
        XCTAssertGreaterThanOrEqual(receivedCount, 2)
    }

    func testCodexBackendAdapterDaemonUnreachableError() async {
        let simTransport = SimulatedCodexTransport(isConnected: false)
        let adapter = CodexBackendAdapter(transport: simTransport)
        let sessionId = "ses_cx_offline"

        do {
            _ = try await adapter.startSession(sessionId: sessionId, workspacePath: "/tmp", model: nil, mode: nil)
            XCTFail("Expected backendUnreachable error")
        } catch PharosClientError.backendUnreachable(let backend, let reason) {
            XCTAssertEqual(backend, "codex")
            XCTAssertTrue(reason.contains("unreachable"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Agy Backend Adapter Tests

    func testAgyBackendAdapterLifecycleAndApprovals() async throws {
        let simTransport = SimulatedAgyTransport(isConnected: true)
        let adapter = AgyBackendAdapter(transport: simTransport)
        let sessionId = "ses_agy_test_1"

        let events = adapter.observeSessionEvents(sessionId: sessionId)

        let startTurn = try await adapter.startSession(
            sessionId: sessionId,
            workspacePath: "/tmp/agy_ws",
            model: "gemini-2.5-pro",
            mode: "normal"
        )
        XCTAssertEqual(startTurn.turnNumber, 1)

        let promptTurn = try await adapter.sendSessionPrompt(
            sessionId: sessionId,
            prompt: "Analyze architecture boundaries",
            mode: .steer
        )
        XCTAssertEqual(promptTurn.turnNumber, 2)

        try await adapter.selectSessionModel(sessionId: sessionId, model: "gemini-2.5-flash")
        try await adapter.resolveApproval(
            sessionId: sessionId,
            approvalId: "appr_agy_1",
            decision: ApprovalDecision(choice: .allowedOnce)
        )

        var receivedCount = 0
        for await event in events {
            receivedCount += 1
            if case .approvalResolved(let id, let decision) = event {
                XCTAssertEqual(id, "appr_agy_1")
                XCTAssertEqual(decision.choice, .allowedOnce)
            }
            if receivedCount >= 3 { // startTurn + promptTurn + approvalResolved
                break
            }
        }
        XCTAssertGreaterThanOrEqual(receivedCount, 3)
    }

    // MARK: - Dsh Backend Adapter Tests

    func testDshBackendAdapterStartupParsingAndLifecycle() async throws {
        let simTransport = SimulatedDshTransport(isConnected: true)
        let adapter = DshBackendAdapter(transport: simTransport)
        
        let stdoutLine = "dsh web: http://127.0.0.1:49281/?token=vtok_8f93a74b"
        let parsed = await adapter.parseStartupLine(stdoutLine)
        XCTAssertTrue(parsed)

        let discoveredPort = await adapter.getDiscoveredPort()
        XCTAssertEqual(discoveredPort, 49281)

        let sessionId = "ses_dsh_test_1"
        let events = adapter.observeSessionEvents(sessionId: sessionId)

        let startTurn = try await adapter.startSession(
            sessionId: sessionId,
            workspacePath: "/tmp/dsh_ws",
            model: "deepseek-coder",
            mode: "yolo"
        )
        XCTAssertEqual(startTurn.turnNumber, 1)

        let promptTurn = try await adapter.sendSessionPrompt(
            sessionId: sessionId,
            prompt: "Run performance benchmark",
            mode: .queue
        )
        XCTAssertEqual(promptTurn.turnNumber, 2)

        try await adapter.selectSessionModel(sessionId: sessionId, model: "deepseek-v3")
        try await adapter.resolveApproval(
            sessionId: sessionId,
            approvalId: "appr_dsh_1",
            decision: ApprovalDecision(choice: .allowedOnce, answers: ["q_confirm": ["Yes, apply"]])
        )

        var receivedCount = 0
        for await event in events {
            receivedCount += 1
            if case .approvalResolved(let id, let decision) = event {
                XCTAssertEqual(id, "appr_dsh_1")
                XCTAssertEqual(decision.choice, .allowedOnce)
                XCTAssertEqual(decision.answers?["q_confirm"], ["Yes, apply"])
            }
            if receivedCount >= 3 { // startTurn + promptTurn + approvalResolved
                break
            }
        }
        XCTAssertGreaterThanOrEqual(receivedCount, 3)
    }
}
