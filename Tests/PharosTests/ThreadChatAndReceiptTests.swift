import XCTest
import Foundation
import PharosClientKit
@testable import Pharos

@MainActor
final class ThreadChatAndReceiptTests: XCTestCase {

    // MARK: - 1. Implicit Human Participant Invariant (RFC-006 §2)

    func testImplicitHumanParticipantInvariant() async {
        // Setup mock service with thread containing agents and accidental "human" ID
        let thread = ClientThreadSummary(
            threadId: "room_dev",
            title: "Development Roster",
            memberIds: ["codex_agent", "agy_agent", "human", "tester"]
        )
        let codexMember = ClientMemberDetail(
            name: "codex_agent",
            agent: "codex",
            machine: "mini",
            model: "gpt-4o",
            mode: "yolo",
            status: "working",
            avatarSeed: "codex_seed"
        )
        let agyMember = ClientMemberDetail(
            name: "agy_agent",
            agent: "agy",
            machine: "air",
            model: "claude-3-5-sonnet",
            mode: "yolo",
            status: "idle",
            avatarSeed: "agy_seed"
        )

        let mockService = MockPharosClientService(
            threads: [thread],
            members: [
                "codex_agent": codexMember,
                "agy_agent": agyMember
            ]
        )

        let vm = ThreadConversationViewModel(
            threadId: "room_dev",
            clientService: mockService,
            implicitHumanId: "human",
            implicitHumanName: "Pai"
        )

        await vm.loadThreadData()

        // Invariant: Human is strictly excluded from roster members
        XCTAssertEqual(vm.rosterMembers.count, 2)
        XCTAssertTrue(vm.rosterMembers.contains(where: { $0.name == "codex_agent" }))
        XCTAssertTrue(vm.rosterMembers.contains(where: { $0.name == "agy_agent" }))
        XCTAssertFalse(vm.rosterMembers.contains(where: { $0.name == "human" }))
        XCTAssertFalse(vm.rosterMembers.contains(where: { $0.name == "tester" }))

        // Invariant: Human can still compose, broadcast, and be recorded as sender
        await vm.sendMessage(text: "Reviewing deployment architecture")
        XCTAssertEqual(vm.messages.count, 1)
        let sentMsg = vm.messages.first
        XCTAssertEqual(sentMsg?.senderId, "human")
        XCTAssertEqual(sentMsg?.senderName, "Pai")
        XCTAssertEqual(sentMsg?.text, "Reviewing deployment architecture")
    }

    // MARK: - 2. Plain Chat Bubble Invariant (RFC-006 §5)

    func testPlainChatBubbleInvariant() async {
        // Plain DTO carries text and optional attachments; strictly no intermediate steps or tool calls
        let agentMsg = ClientThreadMessage(
            id: "msg_plain_1",
            threadId: "room_dev",
            senderId: "codex_agent",
            senderName: "Codex",
            senderAvatarSeed: "codex_seed",
            text: "All 12 architecture boundary tests have passed.",
            timestamp: Date(),
            receipt: .delivered,
            attachments: [
                CanonicalAttachment(
                    id: "att_1",
                    filename: "report.json",
                    mimeType: "application/json",
                    sizeBytes: 1024,
                    uri: "file:///tmp/report.json"
                )
            ]
        )

        let mockService = MockPharosClientService(
            threads: [ClientThreadSummary(threadId: "room_dev", title: "Dev", memberIds: ["codex_agent"])],
            threadMessages: ["room_dev": [agentMsg]],
            members: ["codex_agent": ClientMemberDetail(name: "codex_agent", agent: "codex", machine: "mini", model: "gpt-4o", mode: "yolo", status: "idle", avatarSeed: "codex_seed")]
        )

        let vm = ThreadConversationViewModel(threadId: "room_dev", clientService: mockService)
        await vm.loadThreadData()

        XCTAssertEqual(vm.messages.count, 1)
        let loaded = vm.messages.first!
        XCTAssertEqual(loaded.text, "All 12 architecture boundary tests have passed.")
        XCTAssertEqual(loaded.attachments.count, 1)
        XCTAssertEqual(loaded.attachments.first?.filename, "report.json")
        XCTAssertEqual(loaded.receipt, DeliveryReceiptState.delivered)
    }

    // MARK: - 3. Multi-Agent Delivery Receipt Progression

    func testMultiAgentDeliveryReceiptStateTransitions() async {
        let mockService = MockPharosClientService()
        let vm = ThreadConversationViewModel(threadId: "room_dev", clientService: mockService)

        // Seed initial message with pending receipt
        let msg = ClientThreadMessage(
            id: "msg_receipt_1",
            threadId: "room_dev",
            senderId: "human",
            senderName: "You",
            text: "Deploying release candidate",
            timestamp: Date(),
            receipt: .pending
        )
        vm.handleClientEvent(.threadMessageReceived(msg))

        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages.first?.receipt, .pending)

        // Transition 1: .delivered across mesh
        vm.handleClientEvent(.threadReceiptUpdated(
            threadId: "room_dev",
            messageId: "msg_receipt_1",
            receipt: .delivered
        ))
        XCTAssertEqual(vm.messages.first?.receipt, .delivered)

        // Transition 2: .consumed by agent daemon
        vm.handleClientEvent(.threadReceiptUpdated(
            threadId: "room_dev",
            messageId: "msg_receipt_1",
            receipt: .consumed
        ))
        XCTAssertEqual(vm.messages.first?.receipt, .consumed)
    }

    // MARK: - 4. Unverified Fallback Receipt for DSH Nodes

    func testUnverifiedFallbackReceiptForDsh() async {
        let mockService = MockPharosClientService()
        let vm = ThreadConversationViewModel(threadId: "room_dsh", clientService: mockService)

        let msg = ClientThreadMessage(
            id: "msg_dsh_1",
            threadId: "room_dsh",
            senderId: "human",
            senderName: "You",
            text: "Hello dsh plugin",
            timestamp: Date(),
            receipt: .pending
        )
        vm.handleClientEvent(.threadMessageReceived(msg))

        // Update to unverified fallback (e.g. dsh-plugin-pharos delivery fallback)
        vm.handleClientEvent(.threadReceiptUpdated(
            threadId: "room_dsh",
            messageId: "msg_dsh_1",
            receipt: .unverifiedFallback
        ))

        XCTAssertEqual(vm.messages.first?.receipt, .unverifiedFallback)
    }

    // MARK: - 5. Member Status Updates and Error Surfacing

    func testMemberStatusUpdatesAndErrorSurfacing() async {
        let thread = ClientThreadSummary(
            threadId: "room_status",
            title: "Status Thread",
            memberIds: ["codex"]
        )
        let codexMember = ClientMemberDetail(
            name: "codex",
            agent: "codex",
            machine: "mini",
            model: "gpt-4o",
            mode: "yolo",
            status: "idle",
            avatarSeed: "seed_1"
        )
        let mockService = MockPharosClientService(
            threads: [thread],
            members: ["codex": codexMember]
        )

        let vm = ThreadConversationViewModel(threadId: "room_status", clientService: mockService)
        await vm.loadThreadData()

        XCTAssertEqual(vm.rosterMembers.first?.status, "idle")

        // Status update event
        vm.handleClientEvent(.memberStatusChanged(name: "codex", status: "working"))
        XCTAssertEqual(vm.rosterMembers.first?.status, "working")

        // Backend error event
        let err = PharosClientError.connectionFailed("Mesh node unreachable")
        vm.handleClientEvent(.backendError(err))
        XCTAssertNotNil(vm.activeError)

        vm.dismissError()
        XCTAssertNil(vm.activeError)
    }
}
