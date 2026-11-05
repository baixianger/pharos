import XCTest
import Foundation
import PharosClientKit
@testable import PharosRuntime

final class CanonicalMessageMappingTests: XCTestCase {

    // MARK: - 1. DSH Message Translator Tests (incl. PIT-DS-16)

    func testDshMessageTranslatorTurnLifecycleAndStreaming() {
        let translator = DshMessageTranslator()
        let rawStart: [String: Any] = ["seq": 101, "vendorToken": "dsh_t_abc"]
        let turn = translator.translateTurnStart(turnNumber: 3, sessionId: "ses_dsh_1", rawPayload: rawStart)

        XCTAssertEqual(turn.turnNumber, 3)
        XCTAssertEqual(turn.sessionId, "ses_dsh_1")
        XCTAssertEqual(turn.status, .inProgress)
        XCTAssertEqual(turn.rawVendorPayload?["vendorToken"], .string("dsh_t_abc"))

        // Streaming deltas
        let textDelta = translator.translateStreamingDelta(
            sessionId: "ses_dsh_1",
            turnId: turn.turnId,
            deltaType: "text-delta",
            chunk: "Building "
        )
        XCTAssertEqual(textDelta?.deltaType, .textDelta("Building "))

        let reasoningDelta = translator.translateStreamingDelta(
            sessionId: "ses_dsh_1",
            turnId: turn.turnId,
            deltaType: "reasoning-delta",
            chunk: "Analyzing "
        )
        XCTAssertEqual(reasoningDelta?.deltaType, .reasoningDelta("Analyzing "))

        // Turn end
        let completedTurn = translator.translateTurnEnd(currentTurn: turn, reasonKind: "stop", rawPayload: ["cost": 0.05])
        XCTAssertEqual(completedTurn.status, .completed)
        XCTAssertEqual(completedTurn.rawVendorPayload?["reasonKind"], .string("stop"))
        XCTAssertNotNil(completedTurn.completedAt)
    }

    func testDshToolCallHandlesStringifiedJsonArguments_PIT_DS_16() {
        let translator = DshMessageTranslator()
        let stringifiedArgs = "{\"filePath\": \"/src/main.swift\", \"flags\": [\"-O\"], \"count\": 42}"
        
        let block = translator.translateToolCall(
            callId: "call_dsh_99",
            toolName: "compile_file",
            rawArguments: stringifiedArgs,
            rawPayload: ["streamMuxId": 4]
        )

        XCTAssertEqual(block.blockId, "tool_call_call_dsh_99")
        if case .toolCall(let toolCall) = block.kind {
            XCTAssertEqual(toolCall.callId, "call_dsh_99")
            XCTAssertEqual(toolCall.toolName, "compile_file")
            XCTAssertEqual(toolCall.arguments["filePath"], .string("/src/main.swift"))
            XCTAssertEqual(toolCall.arguments["count"], .number(42))
            XCTAssertEqual(toolCall.rawArguments, stringifiedArgs)
        } else {
            XCTFail("Expected .toolCall block kind")
        }
    }

    func testDshApprovalRequestQuestionnaireAndPermission() {
        let translator = DshMessageTranslator()
        let qParams: [String: Any] = [
            "intent": "plan-review",
            "questions": [
                [
                    "id": "q_confirm",
                    "prompt": "Apply this refactoring plan?",
                    "options": ["Yes, apply", "No, cancel"],
                    "isMultiSelect": false
                ]
            ]
        ]

        let approval = translator.translateApprovalRequest(
            approvalId: "wf_appr_1",
            sessionId: "ses_dsh_1",
            eventType: "user-questions/request",
            params: qParams
        )

        XCTAssertEqual(approval.approvalId, "wf_appr_1")
        if case .structuredQuestionnaire(let intent, let questions) = approval.kind {
            XCTAssertEqual(intent, "plan-review")
            XCTAssertEqual(questions.count, 1)
            XCTAssertEqual(questions[0].question, "Apply this refactoring plan?")
            XCTAssertEqual(questions[0].options, ["Yes, apply", "No, cancel"])
        } else {
            XCTFail("Expected .structuredQuestionnaire")
        }
    }

    // MARK: - 2. Codex Message Translator Tests (incl. PIT-CX-14)

    func testCodexMessageTranslatorItemCompleted_PIT_CX_14() {
        let translator = CodexMessageTranslator()

        // Test commentary phase flag preservation (PIT-CX-14)
        let agentMessageDict: [String: Any] = [
            "text": "I'm inspecting the compiler errors now.",
            "phase": "commentary"
        ]
        let block = translator.translateItemCompleted(
            itemId: "item_msg_1",
            itemType: "agentMessage",
            itemDict: agentMessageDict
        )

        XCTAssertNotNil(block)
        XCTAssertEqual(block?.blockId, "item_msg_1")
        if case .assistantText(let text) = block?.kind {
            XCTAssertEqual(text, "I'm inspecting the compiler errors now.")
            XCTAssertEqual(block?.rawVendorPayload?["phase"], .string("commentary"))
        } else {
            XCTFail("Expected .assistantText")
        }

        // Test command execution item
        let cmdDict: [String: Any] = [
            "command": "git status --porcelain",
            "cwd": "/Users/pai/pharos",
            "exitCode": 0,
            "stdout": "M Sources/App.swift\n",
            "stderr": ""
        ]
        let cmdBlock = translator.translateItemCompleted(
            itemId: "item_cmd_1",
            itemType: "commandExecution",
            itemDict: cmdDict
        )
        if case .terminalCommand(let cmd) = cmdBlock?.kind {
            XCTAssertEqual(cmd.command, "git status --porcelain")
            XCTAssertEqual(cmd.exitCode, 0)
            XCTAssertEqual(cmd.stdout, "M Sources/App.swift\n")
        } else {
            XCTFail("Expected .terminalCommand")
        }

        // Test file change item
        let patchDict: [String: Any] = [
            "path": "Package.swift",
            "kind": "modify",
            "diff": "+ .target(name: \"NewTarget\")"
        ]
        let patchBlock = translator.translateItemCompleted(
            itemId: "item_patch_1",
            itemType: "fileChange",
            itemDict: patchDict
        )
        if case .filePatch(let patch) = patchBlock?.kind {
            XCTAssertEqual(patch.path, "Package.swift")
            XCTAssertEqual(patch.kind, .modify)
            XCTAssertEqual(patch.diff, "+ .target(name: \"NewTarget\")")
        } else {
            XCTFail("Expected .filePatch")
        }
    }

    func testCodexApprovalRequestFromThreadStatus() {
        let translator = CodexMessageTranslator()
        let approval = translator.translateApprovalRequest(
            approvalId: "cx_appr_1",
            sessionId: "ses_cx_1",
            command: "rm -rf .build",
            explanation: "Codex requires approval to execute disk cleanup"
        )

        XCTAssertEqual(approval.approvalId, "cx_appr_1")
        if case .toolPermission(let tool, let params, let exp) = approval.kind {
            XCTAssertEqual(tool, "commandExecution")
            XCTAssertEqual(params["command"], .string("rm -rf .build"))
            XCTAssertEqual(exp, "Codex requires approval to execute disk cleanup")
        } else {
            XCTFail("Expected .toolPermission")
        }
    }

    // MARK: - 3. Antigravity Message Translator Tests (incl. PIT-AG-07)

    func testAgyTranscriptLineDecoupledToolResultCorrelation_PIT_AG_07() {
        let translator = AgyMessageTranslator()

        // Line 1: PLANNER_RESPONSE containing tool call
        let plannerResponseLine: [String: Any] = [
            "type": "PLANNER_RESPONSE",
            "thinking": "Need to check directory contents.",
            "content": "Listing files...",
            "tool_calls": [
                [
                    "id": "tc_list_dir_1",
                    "name": "list_directory",
                    "arguments": ["path": "/tmp"]
                ]
            ]
        ]

        let blocks1 = translator.translateTranscriptLine(lineDict: plannerResponseLine, stepIndex: 1)
        XCTAssertEqual(blocks1.count, 3) // reasoning, assistantText, toolCall

        if case .reasoning(let reasoning) = blocks1[0].kind {
            XCTAssertEqual(reasoning.thinking, "Need to check directory contents.")
        } else {
            XCTFail("Expected reasoning block")
        }

        if case .assistantText(let txt) = blocks1[1].kind {
            XCTAssertEqual(txt, "Listing files...")
        } else {
            XCTFail("Expected assistantText block")
        }

        if case .toolCall(let tc) = blocks1[2].kind {
            XCTAssertEqual(tc.callId, "tc_list_dir_1")
            XCTAssertEqual(tc.toolName, "list_directory")
        } else {
            XCTFail("Expected toolCall block")
        }

        // Line 2: Subsequent step delivering decoupled TOOL_RESULT (PIT-AG-07)
        let toolResultLine: [String: Any] = [
            "type": "TOOL_RESULT",
            "tool_call_id": "tc_list_dir_1",
            "content": "file1.txt\nfile2.txt",
            "is_error": false
        ]

        let blocks2 = translator.translateTranscriptLine(lineDict: toolResultLine, stepIndex: 2)
        XCTAssertEqual(blocks2.count, 1)

        if case .toolResult(let res) = blocks2[0].kind {
            XCTAssertEqual(res.callId, "tc_list_dir_1")
            XCTAssertEqual(res.toolName, "list_directory") // Successfully correlated with prior call!
            XCTAssertEqual(res.result, .string("file1.txt\nfile2.txt"))
            XCTAssertFalse(res.isError)
        } else {
            XCTFail("Expected correlated toolResult block")
        }
    }

    // MARK: - 4. Backend Capability Registry Tests

    func testBackendCapabilityRegistryNegotiationsAndVersionDrift() {
        let registry = BackendCapabilityRegistry.shared

        // 1. Pinned versions
        let codexPinned = registry.verifyVersion(backend: "codex", detectedVersion: "0.166.0")
        XCTAssertEqual(codexPinned.status, .pinned)
        XCTAssertTrue(codexPinned.capabilities.supportsStreamingReplies)
        XCTAssertEqual(codexPinned.capabilities.deliveryGuarantee, .socketConfirmed)

        let agyPinned = registry.verifyVersion(backend: "agy", detectedVersion: "1.5.1")
        XCTAssertEqual(agyPinned.status, .pinned)
        XCTAssertTrue(agyPinned.capabilities.supportsRuntimeModelSwitch)
        XCTAssertEqual(agyPinned.capabilities.deliveryGuarantee, .acpConfirmed)

        let dshPinned = registry.verifyVersion(backend: "dsh", detectedVersion: "0.2.1-rc.5")
        XCTAssertEqual(dshPinned.status, .pinned)
        XCTAssertEqual(dshPinned.capabilities.deliveryGuarantee, .inProcessAck)

        // 2. Safe version drift with degradation warning
        let codexDrift = registry.verifyVersion(backend: "codex", detectedVersion: "0.150.0")
        if case .compatibleWithDegradation(let warning) = codexDrift.status {
            XCTAssertTrue(warning.contains("version mismatch"))
            XCTAssertTrue(warning.contains("0.150.0"))
        } else {
            XCTFail("Expected compatibleWithDegradation for codex 0.150.0")
        }

        // 3. Incompatible version below threshold
        let codexOld = registry.verifyVersion(backend: "codex", detectedVersion: "0.130.0")
        if case .incompatible(let error) = codexOld.status {
            XCTAssertTrue(error.contains("below minimum"))
        } else {
            XCTFail("Expected incompatible for codex 0.130.0")
        }
    }
}
