import XCTest
import Foundation
import PharosClientKit
@testable import Pharos

@MainActor
final class SessionStreamingAndSteeringTests: XCTestCase {

    // MARK: - 1. Streaming Delta Coalescing Tests

    func testStreamingDeltaCoalescing() async {
        let mockService = MockPharosClientService()
        let vm = SessionConversationViewModel(sessionId: "ses_stream_1", clientService: mockService)

        // Simulate turn started event
        let turn = CanonicalTurn(
            turnId: "turn_1",
            sessionId: "ses_stream_1",
            turnNumber: 1,
            status: .inProgress
        )
        vm.handleClientEvent(.turnStarted(turn))

        XCTAssertTrue(vm.isTurnInProgress)
        XCTAssertEqual(vm.activeTurnId, "turn_1")

        // Simulate streaming deltas
        let d1 = CanonicalStreamingDelta(
            sessionId: "ses_stream_1",
            turnId: "turn_1",
            deltaType: .textDelta("Analyzing ")
        )
        let d2 = CanonicalStreamingDelta(
            sessionId: "ses_stream_1",
            turnId: "turn_1",
            deltaType: .textDelta("codebase...")
        )
        let r1 = CanonicalStreamingDelta(
            sessionId: "ses_stream_1",
            turnId: "turn_1",
            deltaType: .reasoningDelta("Inspecting file dependencies")
        )

        vm.handleClientEvent(.streamingDelta(d1))
        vm.handleClientEvent(.streamingDelta(d2))
        vm.handleClientEvent(.streamingDelta(r1))

        // Verify coalesced output in live buffers
        XCTAssertEqual(vm.liveStreamingText, "Analyzing codebase...")
        XCTAssertEqual(vm.liveReasoningText, "Inspecting file dependencies")

        // Simulate turn completion
        let completedTurn = CanonicalTurn(
            turnId: "turn_1",
            sessionId: "ses_stream_1",
            turnNumber: 1,
            status: .completed,
            steps: [
                CanonicalStep(
                    stepId: "step_1",
                    stepNumber: 1,
                    status: .completed,
                    blocks: [
                        CanonicalBlock(
                            blockId: "blk_1",
                            kind: .assistantText("Analyzing codebase...")
                        )
                    ]
                )
            ]
        )
        vm.handleClientEvent(.turnCompleted(completedTurn))

        XCTAssertFalse(vm.isTurnInProgress)
        XCTAssertNil(vm.activeTurnId)
        XCTAssertEqual(vm.liveStreamingText, "")
        XCTAssertEqual(vm.turns.count, 1)
        XCTAssertEqual(vm.turns.first?.status, .completed)
    }

    // MARK: - 2. Mid-Turn Steering Dispatch Tests

    func testMidTurnSteeringDispatch() async {
        let session = ClientSessionSummary(
            sessionId: "ses_steer_1",
            machineId: "mini",
            agentType: "codex",
            workspacePath: "/Users/pai/pharos",
            title: "Steering Test",
            status: .working,
            avatarSeed: "codex_1"
        )
        let mockService = MockPharosClientService(sessions: [session])
        let vm = SessionConversationViewModel(sessionId: "ses_steer_1", clientService: mockService)

        // Queue first turn
        await vm.sendPrompt(text: "Run test suite", isSteer: false)
        XCTAssertEqual(vm.turns.count, 1)
        XCTAssertTrue(vm.isTurnInProgress)

        // Inject mid-turn steering prompt while active
        await vm.sendPrompt(text: "Focus only on auth tests", isSteer: true)
        XCTAssertEqual(vm.turns.count, 2)
        XCTAssertTrue(vm.isTurnInProgress)
        XCTAssertNil(vm.activeError)
    }

    // MARK: - 3. Interactive Approval Waterfall Tests

    func testInteractiveApprovalWaterfall() async {
        let mockService = MockPharosClientService()
        let vm = SessionConversationViewModel(sessionId: "ses_appr_1", clientService: mockService)

        let approval = CanonicalApprovalRequest(
            approvalId: "appr_99",
            sessionId: "ses_appr_1",
            kind: .toolPermission(
                toolName: "execute_shell",
                params: ["command": .string("rm -rf /tmp/build")],
                explanation: "Clean ephemeral build artifacts"
            )
        )

        // Approval required event
        vm.handleClientEvent(.approvalRequired(approval))
        XCTAssertNotNil(vm.activeApproval)
        XCTAssertEqual(vm.activeApproval?.approvalId, "appr_99")

        // Resolve approval
        await vm.resolveApproval(decision: ApprovalDecision(choice: .allowedOnce))
        XCTAssertNil(vm.activeApproval)
    }

    // MARK: - 4. Daemon Unreachable Error Surfacing (Never Dropped)

    func testDaemonUnreachableSurfacesError() async {
        let mockService = MockPharosClientService()
        let vm = SessionConversationViewModel(sessionId: "ses_offline_1", clientService: mockService)

        let err = PharosClientError.backendUnreachable(backend: "codex", reason: "app-server-control.sock connection refused")
        vm.handleClientEvent(.backendError(err))

        XCTAssertNotNil(vm.activeError)
        if case .backendUnreachable(let backend, let reason) = vm.activeError {
            XCTAssertEqual(backend, "codex")
            XCTAssertTrue(reason.contains("connection refused"))
        } else {
            XCTFail("Expected .backendUnreachable error")
        }

        vm.dismissError()
        XCTAssertNil(vm.activeError)
    }

    // MARK: - 5. History Isolation Invariant (No Thread Message Leakage)

    func testHistoryIsolationInvariant() async {
        // Seed thread message into mock service
        let threadMsg = ClientThreadMessage(
            id: "th_msg_1",
            threadId: "th_roster_99",
            senderId: "agent_codex",
            senderName: "Codex",
            text: "Hello from thread roster"
        )
        let mockService = MockPharosClientService(
            sessions: [
                ClientSessionSummary(
                    sessionId: "ses_iso_1",
                    machineId: "mini",
                    agentType: "codex",
                    workspacePath: "/Users/pai/pharos",
                    title: "Iso Test",
                    status: .working,
                    avatarSeed: "codex_1"
                )
            ],
            sessionHistories: ["ses_iso_1": []],
            threadMessages: ["th_roster_99": [threadMsg]]
        )
        let vm = SessionConversationViewModel(sessionId: "ses_iso_1", clientService: mockService)

        // Load session history
        await vm.loadHistory()

        // Assert 1:1 session history contains zero thread messages
        XCTAssertTrue(vm.turns.isEmpty)
        for turn in vm.turns {
            for step in turn.steps {
                for block in step.blocks {
                    if case .userText(let t) = block.kind {
                        XCTAssertNotEqual(t, threadMsg.text)
                    }
                    if case .assistantText(let t) = block.kind {
                        XCTAssertNotEqual(t, threadMsg.text)
                    }
                }
            }
        }
    }
}
