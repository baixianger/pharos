import XCTest
import Foundation
@testable import PharosClientKit

final class PharosClientKitTests: XCTestCase {
    
    // MARK: - 1. JSONValue Roundtrip Tests
    
    func testJSONValueRoundtrip() throws {
        let original: [String: JSONValue] = [
            "str": .string("hello world"),
            "int": .number(42),
            "double": .number(3.14159),
            "boolTrue": .bool(true),
            "boolFalse": .bool(false),
            "nullVal": .null,
            "arr": .array([.string("a"), .number(1), .bool(true)]),
            "nested": .object([
                "key": .string("value"),
                "subArr": .array([.number(99)])
            ])
        ]
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([String: JSONValue].self, from: data)
        
        XCTAssertEqual(decoded["str"], .string("hello world"))
        XCTAssertEqual(decoded["int"]?.intValue, 42)
        XCTAssertEqual(decoded["boolTrue"], .bool(true))
        XCTAssertEqual(decoded["nullVal"], .null)
        XCTAssertEqual(decoded["arr"]?.arrayValue?.count, 3)
        XCTAssertEqual(decoded["nested"]?.objectValue?["key"], .string("value"))
    }
    
    // MARK: - 2. Canonical Turn, Step & Block Roundtrip Tests
    
    func testCanonicalTurnStepBlockRoundtrip() throws {
        let block1 = CanonicalBlock(
            blockId: "blk_1",
            kind: .userText("Can you refactor the parser?"),
            rawVendorPayload: ["vendorSource": .string("dsh-web-0.2.1-rc.5")]
        )
        let block2 = CanonicalBlock(
            blockId: "blk_2",
            kind: .reasoning(CanonicalReasoningBlock(
                thinking: "I should analyze the grammar first.",
                summary: "Grammar analysis",
                durationMs: 1250
            ))
        )
        let block3 = CanonicalBlock(
            blockId: "blk_3",
            kind: .toolCall(CanonicalToolCall(
                callId: "call_abc123",
                toolName: "read_file",
                arguments: ["path": .string("/tmp/parser.swift")],
                rawArguments: "{\"path\": \"/tmp/parser.swift\"}"
            ))
        )
        let block4 = CanonicalBlock(
            blockId: "blk_4",
            kind: .toolResult(CanonicalToolResult(
                callId: "call_abc123",
                toolName: "read_file",
                result: .string("// file content here"),
                isError: false
            ))
        )
        let block5 = CanonicalBlock(
            blockId: "blk_5",
            kind: .terminalCommand(CanonicalTerminalCommand(
                command: "swift test",
                cwd: "/Users/pai/project",
                exitCode: 0,
                stdout: "All tests passed\n",
                stderr: ""
            ))
        )
        let block6 = CanonicalBlock(
            blockId: "blk_6",
            kind: .filePatch(CanonicalFilePatch(
                path: "Sources/Parser.swift",
                kind: .modify,
                diff: "--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n"
            ))
        )
        
        let step = CanonicalStep(
            stepId: "step_turn1_1",
            stepNumber: 1,
            status: .completed,
            blocks: [block1, block2, block3, block4, block5, block6],
            rawVendorPayload: ["stepMuxId": .number(7)]
        )
        
        let turn = CanonicalTurn(
            turnId: "turn_001",
            sessionId: "ses_mini_codex_1",
            turnNumber: 1,
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 1700000000),
            completedAt: Date(timeIntervalSince1970: 1700000010),
            steps: [step],
            rawVendorPayload: ["codexRolloutId": .string("roll_xyz999")]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(turn)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CanonicalTurn.self, from: data)
        
        XCTAssertEqual(decoded.turnId, "turn_001")
        XCTAssertEqual(decoded.sessionId, "ses_mini_codex_1")
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertEqual(decoded.steps.count, 1)
        XCTAssertEqual(decoded.rawVendorPayload?["codexRolloutId"], .string("roll_xyz999"))
        
        let decodedStep = decoded.steps[0]
        XCTAssertEqual(decodedStep.stepId, "step_turn1_1")
        XCTAssertEqual(decodedStep.blocks.count, 6)
        XCTAssertEqual(decodedStep.rawVendorPayload?["stepMuxId"], .number(7))
        
        // Assert specific block reconstructions
        if case .userText(let txt) = decodedStep.blocks[0].kind {
            XCTAssertEqual(txt, "Can you refactor the parser?")
        } else {
            XCTFail("Block 0 kind mismatch")
        }
        
        if case .reasoning(let reasoning) = decodedStep.blocks[1].kind {
            XCTAssertEqual(reasoning.thinking, "I should analyze the grammar first.")
            XCTAssertEqual(reasoning.summary, "Grammar analysis")
            XCTAssertEqual(reasoning.durationMs, 1250)
        } else {
            XCTFail("Block 1 kind mismatch")
        }
        
        if case .toolCall(let call) = decodedStep.blocks[2].kind {
            XCTAssertEqual(call.callId, "call_abc123")
            XCTAssertEqual(call.toolName, "read_file")
            XCTAssertEqual(call.arguments["path"], .string("/tmp/parser.swift"))
        } else {
            XCTFail("Block 2 kind mismatch")
        }
        
        if case .terminalCommand(let cmd) = decodedStep.blocks[4].kind {
            XCTAssertEqual(cmd.command, "swift test")
            XCTAssertEqual(cmd.exitCode, 0)
        } else {
            XCTFail("Block 4 kind mismatch")
        }
        
        if case .filePatch(let patch) = decodedStep.blocks[5].kind {
            XCTAssertEqual(patch.path, "Sources/Parser.swift")
            XCTAssertEqual(patch.kind, .modify)
        } else {
            XCTFail("Block 5 kind mismatch")
        }
    }
    
    // MARK: - 3. Streaming Delta Tests
    
    func testStreamingDeltaRoundtrip() throws {
        let delta1 = CanonicalStreamingDelta(
            sessionId: "ses_1",
            turnId: "turn_1",
            stepId: "step_1",
            blockId: "blk_1",
            deltaType: .textDelta("Hello")
        )
        let delta2 = CanonicalStreamingDelta(
            sessionId: "ses_1",
            turnId: "turn_1",
            deltaType: .reasoningDelta("Thinking deeply...")
        )
        let delta3 = CanonicalStreamingDelta(
            sessionId: "ses_1",
            turnId: "turn_1",
            deltaType: .toolCallDelta(callId: "call_1", chunk: "{\"arg\": 1}")
        )
        let delta4 = CanonicalStreamingDelta(
            sessionId: "ses_1",
            turnId: "turn_1",
            deltaType: .terminalOutputDelta("Scanning build targets...\n")
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        for delta in [delta1, delta2, delta3, delta4] {
            let data = try encoder.encode(delta)
            let decoded = try decoder.decode(CanonicalStreamingDelta.self, from: data)
            XCTAssertEqual(decoded, delta)
        }
    }
    
    // MARK: - 4. Approval Models Roundtrip
    
    func testApprovalRequestAndDecisionRoundtrip() throws {
        let req = CanonicalApprovalRequest(
            approvalId: "appr_101",
            sessionId: "ses_agy_1",
            kind: .structuredQuestionnaire(
                intent: "plan-review",
                questions: [
                    CanonicalQuestionOption(
                        id: "q1",
                        question: "Which model to use?",
                        options: ["sonnet-3.7", "opus-3"],
                        isMultiSelect: false
                    )
                ]
            ),
            rawVendorPayload: ["waterfallId": .string("wf_888")]
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let reqData = try encoder.encode(req)
        let decodedReq = try decoder.decode(CanonicalApprovalRequest.self, from: reqData)
        XCTAssertEqual(decodedReq.approvalId, "appr_101")
        XCTAssertEqual(decodedReq.rawVendorPayload?["waterfallId"], .string("wf_888"))
        
        let decision = ApprovalDecision(
            choice: .allowedOnce,
            answers: ["q1": ["sonnet-3.7"]]
        )
        let decData = try encoder.encode(decision)
        let decodedDec = try decoder.decode(ApprovalDecision.self, from: decData)
        XCTAssertEqual(decodedDec.choice, .allowedOnce)
        XCTAssertEqual(decodedDec.answers?["q1"], ["sonnet-3.7"])
    }
    
    // MARK: - 5. Thread Message DTO Roundtrip
    
    func testClientThreadMessageRoundtrip() throws {
        let threadMsg = ClientThreadMessage(
            id: "msg_t1",
            threadId: "room_core",
            senderId: "member_codex",
            senderName: "Codex Worker",
            senderAvatarSeed: "codex_seed_123",
            text: "Fixed the compiler warnings.",
            timestamp: Date(timeIntervalSince1970: 1700001000),
            receipt: .consumed,
            attachments: [
                CanonicalAttachment(
                    id: "att_1",
                    filename: "diff.patch",
                    mimeType: "text/x-diff",
                    sizeBytes: 1024,
                    uri: "file:///tmp/diff.patch"
                )
            ]
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(threadMsg)
        let decoded = try decoder.decode(ClientThreadMessage.self, from: data)
        
        XCTAssertEqual(decoded.id, "msg_t1")
        XCTAssertEqual(decoded.threadId, "room_core")
        XCTAssertEqual(decoded.receipt, .consumed)
        XCTAssertEqual(decoded.attachments.count, 1)
        XCTAssertEqual(decoded.attachments[0].filename, "diff.patch")
    }
    
    // MARK: - 6. Client Event & Error Roundtrip
    
    func testClientEventAndExplicitErrorRoundtrip() throws {
        let err = PharosClientError.backendUnreachable(
            backend: "codex",
            reason: "Daemon socket closed unexpectedly (SIGTERM)"
        )
        let event = PharosClientEvent.backendError(err)
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(event)
        let decoded = try decoder.decode(PharosClientEvent.self, from: data)
        
        XCTAssertEqual(decoded, event)
    }
    
    // MARK: - 7. MockPharosClientService Functional Tests
    
    func testMockPharosClientServiceOperations() async throws {
        let service = MockPharosClientService(
            sessions: [
                ClientSessionSummary(
                    sessionId: "ses_1",
                    machineId: "mini",
                    agentType: "codex",
                    workspacePath: "/Users/pai/pharos",
                    title: "Architecture Refactor",
                    status: .working,
                    avatarSeed: "avatar_1"
                )
            ],
            threads: [
                ClientThreadSummary(
                    threadId: "room_dev",
                    title: "Dev Group",
                    memberIds: ["codex", "agy"]
                )
            ],
            projects: [
                ClientProjectSummary(
                    projectPath: "/Users/pai/pharos",
                    name: "Pharos",
                    trackedDevices: ["mini", "air"],
                    activeSessionsCount: 1
                )
            ],
            sessionHistories: [
                "ses_1": []
            ],
            threadMessages: [
                "room_dev": []
            ],
            members: [
                "codex_agent": ClientMemberDetail(
                    name: "codex_agent",
                    agent: "codex",
                    machine: "mini",
                    model: "o3-mini",
                    mode: "yolo",
                    status: "active",
                    avatarSeed: "seed_cx"
                )
            ]
        )
        
        // 1. Fetching inventory
        let sessions = try await service.fetchSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].title, "Architecture Refactor")
        
        let threads = try await service.fetchThreads()
        XCTAssertEqual(threads.count, 1)
        
        let projects = try await service.fetchProjects()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].trackedDevices, ["mini", "air"])
        
        // 2. Sending Session Message
        let turn = try await service.sendSessionMessage(sessionId: "ses_1", text: "Proceed with Goal 1")
        XCTAssertEqual(turn.sessionId, "ses_1")
        XCTAssertEqual(turn.status, .inProgress)
        XCTAssertEqual(turn.steps.count, 1)
        
        // Verify history backfill
        let history = try await service.fetchSessionHistory(sessionId: "ses_1")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].turnId, turn.turnId)
        
        // 3. Sending Thread Message
        let threadMsg = try await service.sendThreadMessage(threadId: "room_dev", text: "Hello team")
        XCTAssertEqual(threadMsg.threadId, "room_dev")
        XCTAssertEqual(threadMsg.text, "Hello team")
        XCTAssertEqual(threadMsg.receipt, .delivered)
        
        let threadMsgs = try await service.fetchThreadMessages(threadId: "room_dev")
        XCTAssertEqual(threadMsgs.count, 1)
        XCTAssertEqual(threadMsgs[0].id, threadMsg.id)
        
        // 4. Member administration
        try await service.setMemberMode(name: "codex_agent", mode: "safe")
        let updatedMember = try await service.fetchMemberDetail(name: "codex_agent")
        XCTAssertEqual(updatedMember.mode, "safe")
        
        try await service.stopMember(name: "codex_agent")
        let stoppedMember = try await service.fetchMemberDetail(name: "codex_agent")
        XCTAssertEqual(stoppedMember.status, "stopped")
        
        try await service.reviveMember(name: "codex_agent")
        let revivedMember = try await service.fetchMemberDetail(name: "codex_agent")
        XCTAssertEqual(revivedMember.status, "active")
    }
    
    // MARK: - 8. Codex Daemon Unreachable / Restart Error Gate (GOAL.md 16:18)
    
    func testDaemonUnreachableSurfacesExplicitErrorAndNeverSilentlyDrops() async throws {
        let service = MockPharosClientService(
            sessions: [
                ClientSessionSummary(
                    sessionId: "ses_cx",
                    machineId: "mini",
                    agentType: "codex",
                    workspacePath: "/Users/pai/pharos",
                    title: "Codex Testing",
                    status: .working,
                    avatarSeed: "cx_seed"
                )
            ],
            sessionHistories: ["ses_cx": []]
        )
        
        // Simulate Codex daemon crashing / becoming unreachable
        await service.setBackendFailure(backend: "codex", reason: "app-server-control.sock connection refused")
        
        // Attempting to send a session message MUST throw backendUnreachable and NEVER drop silently
        do {
            _ = try await service.sendSessionMessage(sessionId: "ses_cx", text: "Are you alive?")
            XCTFail("Expected backendUnreachable error, but call succeeded")
        } catch let err as PharosClientError {
            if case .backendUnreachable(let backend, let reason) = err {
                XCTAssertEqual(backend, "codex")
                XCTAssertTrue(reason.contains("connection refused"))
            } else {
                XCTFail("Unexpected error variant: \(err)")
            }
        }
        
        // Attempting to fetch session history also surfaces explicit backendUnreachable
        do {
            _ = try await service.fetchSessionHistory(sessionId: "ses_cx")
            XCTFail("Expected backendUnreachable error, but call succeeded")
        } catch let err as PharosClientError {
            if case .backendUnreachable(let backend, _) = err {
                XCTAssertEqual(backend, "codex")
            } else {
                XCTFail("Unexpected error variant: \(err)")
            }
        }
        
        // Simulate daemon recovering / restarting
        await service.setBackendFailure(backend: nil, reason: nil)
        
        // Resuming communication now succeeds
        let turn = try await service.sendSessionMessage(sessionId: "ses_cx", text: "Daemon back online")
        XCTAssertEqual(turn.status, .inProgress)
    }
}
