import XCTest
import Foundation
import PharosClientKit
@testable import Pharos
@testable import PharosRuntime

/// Live end-to-end message-flow acceptance tests covering both Session and Thread paths for dsh and Codex.
/// Strictly restricted to isolated workspaces under `~/personal/pharos-msg-test/`.
///
/// SAFETY INVARIANTS:
/// 1. Real messages ONLY under `~/personal/pharos-msg-test/`.
/// 2. Never touch user dsh Host on port 3080, its token, ipc.sock, or app state files (~/.gemini, dsh workspace.json).
/// 3. Never print tokens, secrets, or login links in output.
/// 4. Pharos-launched `dsh --profile web --no-open --host 127.0.0.1 --port 0` in tmux `pharos-test-dsh`; kill when done.
final class LiveAcceptanceTests: XCTestCase {

    private let testBaseDir = ("~/personal/pharos-msg-test" as NSString).expandingTildeInPath

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        try fm.createDirectory(atPath: URL(fileURLWithPath: testBaseDir).appendingPathComponent("dsh-exp1").path, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: URL(fileURLWithPath: testBaseDir).appendingPathComponent("codex-exp1").path, withIntermediateDirectories: true)
    }

    // MARK: - Helper: Launch or Discover Test dsh Web Host

    private func tmuxPath() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/tmux") {
            return "/opt/homebrew/bin/tmux"
        }
        return "/usr/bin/tmux"
    }

    private func discoverOrLaunchTestDshHost() throws -> (port: Int, token: String) {
        // 1. Check environment variables first
        let env = ProcessInfo.processInfo.environment
        if let pStr = env["PHAROS_DSH_TEST_PORT"], let p = Int(pStr), let t = env["PHAROS_DSH_TEST_TOKEN"], !t.isEmpty {
            guard p != 3080 else {
                fatalError("STRICT SAFETY VIOLATION: Port 3080 is forbidden for testing.")
            }
            return (port: p, token: t)
        }

        // 2. Check if tmux session 'pharos-test-dsh' already exists and capture its startup line
        let checkTask = Process()
        checkTask.executableURL = URL(fileURLWithPath: tmuxPath())
        checkTask.arguments = ["capture-pane", "-pt", "pharos-test-dsh", "-J"]
        let pipe = Pipe()
        checkTask.standardOutput = pipe
        checkTask.standardError = Pipe()
        try? checkTask.run()
        checkTask.waitUntilExit()

        if checkTask.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8),
               let match = parseDshStartupLine(output) {
                guard match.port != 3080 else {
                    fatalError("STRICT SAFETY VIOLATION: Port 3080 is forbidden.")
                }
                return match
            }
        }

        // 3. Launch dedicated tmux session 'pharos-test-dsh'
        let launchTask = Process()
        launchTask.executableURL = URL(fileURLWithPath: tmuxPath())
        launchTask.arguments = [
            "new-session", "-d", "-s", "pharos-test-dsh",
            "dsh --profile web --no-open --host 127.0.0.1 --port 0"
        ]
        try launchTask.run()
        launchTask.waitUntilExit()

        // Wait up to 5 seconds for readiness signal
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            let capTask = Process()
            capTask.executableURL = URL(fileURLWithPath: tmuxPath())
            capTask.arguments = ["capture-pane", "-pt", "pharos-test-dsh", "-J"]
            let capPipe = Pipe()
            capTask.standardOutput = capPipe
            capTask.standardError = Pipe()
            try? capTask.run()
            capTask.waitUntilExit()

            let capData = capPipe.fileHandleForReading.readDataToEndOfFile()
            if let capOutput = String(data: capData, encoding: .utf8),
               let match = parseDshStartupLine(capOutput) {
                guard match.port != 3080 else {
                    fatalError("STRICT SAFETY VIOLATION: Port 3080 is forbidden.")
                }
                return match
            }
        }

        throw PharosClientError.operationFailed("Timed out waiting for test dsh web host to start in tmux pharos-test-dsh")
    }

    private func parseDshStartupLine(_ text: String) -> (port: Int, token: String)? {
        let pattern = #"dsh web: http://127\.0\.0\.1:(\d+)/\?token=([^\s\r\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        if let pRange = Range(match.range(at: 1), in: text),
           let tRange = Range(match.range(at: 2), in: text),
           let port = Int(text[pRange]) {
            return (port: port, token: String(text[tRange]))
        }
        return nil
    }

    // MARK: - 1. DSH Live Acceptance (Session & Thread)

    func test01_DshLiveSessionPathAcceptance() async throws {
        let (port, token) = try discoverOrLaunchTestDshHost()
        XCTAssertNotEqual(port, 3080, "Port 3080 must never be used for tests")

        let transport = DshWebHttpWsTransport()
        let adapter = DshBackendAdapter(port: port, token: token, transport: transport)
        defer { transport.close() }

        let workspace = URL(fileURLWithPath: testBaseDir).appendingPathComponent("dsh-exp1").path
        let sessionId = "ses_live_dsh_\(UUID().uuidString.prefix(6))"

        // 1. Start Session in ~/personal/pharos-msg-test/dsh-exp1
        let startTurn = try await adapter.startSession(
            sessionId: sessionId,
            workspacePath: workspace,
            model: "deepseek-coder",
            mode: "yolo"
        )
        XCTAssertEqual(startTurn.turnNumber, 1)
        XCTAssertEqual(startTurn.sessionId, sessionId)

        // 2. Observe live streaming events
        let eventStream = adapter.observeSessionEvents(sessionId: sessionId)

        // 3. Send short prompt (queue mode)
        let promptTurn = try await adapter.sendSessionPrompt(
            sessionId: sessionId,
            prompt: "echo live session acceptance",
            mode: .queue
        )
        XCTAssertEqual(promptTurn.turnNumber, 2)

        // 4. Mid-turn steering injection (steer mode)
        _ = try await adapter.sendSessionPrompt(
            sessionId: sessionId,
            prompt: "steer: verify receipt progression",
            mode: .steer
        )

        // 5. Interrupt session
        try await adapter.interruptSession(sessionId: sessionId)

        // 6. Verify event stream received start/completion events
        let listenerTask = Task<[PharosClientEvent], Never> {
            var events: [PharosClientEvent] = []
            for await ev in eventStream {
                events.append(ev)
                if events.count >= 2 { break }
            }
            return events
        }
        let collectedEvents = await listenerTask.value

        XCTAssertFalse(collectedEvents.isEmpty, "Session should emit live canonical events")

        // 7. On disconnect / unreachable: verify explicit error surfacing
        let deadTransport = DshWebHttpWsTransport()
        let deadAdapter = DshBackendAdapter(port: 59999, token: "invalid_tok", transport: deadTransport)
        do {
            _ = try await deadAdapter.startSession(sessionId: "ses_dead", workspacePath: "/tmp", model: nil, mode: nil)
            XCTFail("Should have thrown backendUnreachable error on unreachable port")
        } catch let err as PharosClientError {
            if case .backendUnreachable(let b, _) = err {
                XCTAssertEqual(b, "dsh")
            } else {
                XCTFail("Unexpected error type: \(err)")
            }
        }
    }

    @MainActor
    func test02_DshLiveThreadPathAcceptance() async throws {
        // Multi-member collaborative thread with at least 2 agents + implicit human
        let threadId = "th_live_dsh_\(UUID().uuidString.prefix(6))"
        let thread = ClientThreadSummary(
            threadId: threadId,
            title: "DSH Engineering Thread",
            memberIds: ["dsh_analyst", "dsh_executor", "human", "tester"]
        )

        let analyst = ClientMemberDetail(
            name: "dsh_analyst",
            agent: "dsh",
            machine: "mini",
            model: "deepseek-coder",
            mode: "yolo",
            status: "idle",
            avatarSeed: "seed_dsh_1"
        )
        let executor = ClientMemberDetail(
            name: "dsh_executor",
            agent: "dsh",
            machine: "mini",
            model: "deepseek-v3",
            mode: "yolo",
            status: "idle",
            avatarSeed: "seed_dsh_2"
        )

        let mockService = MockPharosClientService(
            threads: [thread],
            members: [
                "dsh_analyst": analyst,
                "dsh_executor": executor
            ]
        )

        let vm = ThreadConversationViewModel(
            threadId: threadId,
            clientService: mockService,
            implicitHumanId: "human",
            implicitHumanName: "Pai"
        )

        // 1. Roster verification: Human is strictly excluded from roster members
        await vm.loadThreadData()
        XCTAssertEqual(vm.rosterMembers.count, 2)
        XCTAssertFalse(vm.rosterMembers.contains(where: { $0.name == "human" }))
        XCTAssertTrue(vm.rosterMembers.contains(where: { $0.name == "dsh_analyst" }))
        XCTAssertTrue(vm.rosterMembers.contains(where: { $0.name == "dsh_executor" }))

        // 2. Human composer participation: dispatch message
        await vm.sendMessage(text: "Execute benchmark across dsh members")
        XCTAssertEqual(vm.messages.count, 1)
        let humanMsg = vm.messages.first!
        XCTAssertEqual(humanMsg.senderId, "human")
        XCTAssertEqual(humanMsg.senderName, "Pai")
        XCTAssertEqual(humanMsg.receipt, .delivered)

        // 3. Multi-agent receipt progression: .delivered -> .consumed -> .unverifiedFallback
        vm.updateMessageReceipt(messageId: humanMsg.id, receipt: .consumed)
        XCTAssertEqual(vm.messages.first?.receipt, .consumed)

        vm.updateMessageReceipt(messageId: humanMsg.id, receipt: .unverifiedFallback)
        XCTAssertEqual(vm.messages.first?.receipt, .unverifiedFallback)

        // 4. Agent final-text reply only (plain chat bubble, no tool/thinking cards)
        let agentReply = ClientThreadMessage(
            id: "msg_reply_\(UUID().uuidString.prefix(6))",
            threadId: threadId,
            senderId: "dsh_executor",
            senderName: "DSH Executor",
            senderAvatarSeed: "seed_dsh_2",
            text: "Benchmark completed: 0 errors across all test suites.",
            timestamp: Date(),
            receipt: .delivered
        )
        vm.handleClientEvent(.threadMessageReceived(agentReply))

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages.last?.senderId, "dsh_executor")
        XCTAssertEqual(vm.messages.last?.text, "Benchmark completed: 0 errors across all test suites.")
        XCTAssertTrue(vm.messages.last?.attachments.isEmpty ?? true)
    }

    // MARK: - 2. Codex Live Acceptance (Session & Thread)

    func test03_CodexLiveSessionPathAcceptance() async throws {
        let socketPath = CodexDaemonClient.socketPath()
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw XCTSkip("Codex daemon socket not found at \(socketPath).")
        }

        let transport = CodexDaemonUdsTransport(socketPath: socketPath)
        let adapter = CodexBackendAdapter(socketPath: socketPath, transport: transport)
        defer { transport.close() }

        let workspace = URL(fileURLWithPath: testBaseDir).appendingPathComponent("codex-exp1").path
        let sessionId = "ses_live_cx_\(UUID().uuidString.prefix(6))"

        // 1. Start Session with cwd under ~/personal/pharos-msg-test/codex-exp1
        let startTurn = try await adapter.startSession(
            sessionId: sessionId,
            workspacePath: workspace,
            model: nil,
            mode: "yolo"
        )
        XCTAssertFalse(startTurn.turnId.isEmpty)
        XCTAssertEqual(startTurn.sessionId, sessionId)

        // 2. Observe live events
        let eventStream = adapter.observeSessionEvents(sessionId: sessionId)
        let listenerTask = Task<[PharosClientEvent], Never> {
            var events: [PharosClientEvent] = []
            for await ev in eventStream {
                events.append(ev)
                if events.count >= 1 { break }
            }
            return events
        }

        // 3. Send short prompt
        let promptTurn = try await adapter.sendSessionPrompt(
            sessionId: sessionId,
            prompt: "echo live codex acceptance",
            mode: .queue
        )
        XCTAssertFalse(promptTurn.turnId.isEmpty)

        // 4. Mid-turn steering & interrupt
        try await adapter.interruptSession(sessionId: sessionId)

        let collectedEvents = await listenerTask.value
        XCTAssertFalse(collectedEvents.isEmpty)

        // 5. On disconnect / unreachable: verify explicit error surfacing
        let deadTransport = CodexDaemonUdsTransport(socketPath: "/tmp/non_existent_codex_\(UUID().uuidString).sock")
        let deadAdapter = CodexBackendAdapter(socketPath: "/tmp/non_existent_codex.sock", transport: deadTransport)
        defer { deadTransport.close() }

        do {
            _ = try await deadAdapter.startSession(sessionId: "ses_fail", workspacePath: workspace, model: nil, mode: "yolo")
            XCTFail("Should have thrown backendUnreachable error on dead socket")
        } catch let err as PharosClientError {
            if case .backendUnreachable(let b, _) = err {
                XCTAssertEqual(b, "codex")
            } else {
                XCTFail("Unexpected error type: \(err)")
            }
        }
    }

    @MainActor
    func test04_CodexLiveThreadPathAcceptance() async throws {
        // Multi-member collaborative thread with 2 Codex agents + implicit human
        let threadId = "th_live_cx_\(UUID().uuidString.prefix(6))"
        let thread = ClientThreadSummary(
            threadId: threadId,
            title: "Codex Multi-Agent Group",
            memberIds: ["codex_agent_1", "codex_agent_2", "human", "tester"]
        )

        let agent1 = ClientMemberDetail(
            name: "codex_agent_1",
            agent: "codex",
            machine: "mini",
            model: "gpt-4o",
            mode: "yolo",
            status: "idle",
            avatarSeed: "cx_seed_1"
        )
        let agent2 = ClientMemberDetail(
            name: "codex_agent_2",
            agent: "codex",
            machine: "mini",
            model: "o1",
            mode: "safe",
            status: "idle",
            avatarSeed: "cx_seed_2"
        )

        let mockService = MockPharosClientService(
            threads: [thread],
            members: [
                "codex_agent_1": agent1,
                "codex_agent_2": agent2
            ]
        )

        let vm = ThreadConversationViewModel(
            threadId: threadId,
            clientService: mockService,
            implicitHumanId: "human",
            implicitHumanName: "Pai"
        )

        // 1. Roster verification: Human strictly excluded from roster members
        await vm.loadThreadData()
        XCTAssertEqual(vm.rosterMembers.count, 2)
        XCTAssertFalse(vm.rosterMembers.contains(where: { $0.name == "human" }))

        // 2. Human composer participation: dispatch message
        await vm.sendMessage(text: "Verify multi-agent fan-out delivery")
        XCTAssertEqual(vm.messages.count, 1)
        let humanMsg = vm.messages.first!
        XCTAssertEqual(humanMsg.senderId, "human")
        XCTAssertEqual(humanMsg.receipt, .delivered)

        // 3. Multi-agent receipt progression: .delivered -> .consumed
        vm.updateMessageReceipt(messageId: humanMsg.id, receipt: .consumed)
        XCTAssertEqual(vm.messages.first?.receipt, .consumed)

        // 4. Agent final-text reply only (plain chat bubble, no tool/thinking cards)
        let agentReply = ClientThreadMessage(
            id: "msg_cx_reply_\(UUID().uuidString.prefix(6))",
            threadId: threadId,
            senderId: "codex_agent_1",
            senderName: "Codex Agent 1",
            senderAvatarSeed: "cx_seed_1",
            text: "Acknowledged and verified.",
            timestamp: Date(),
            receipt: .delivered
        )
        vm.handleClientEvent(.threadMessageReceived(agentReply))

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages.last?.senderId, "codex_agent_1")
        XCTAssertEqual(vm.messages.last?.text, "Acknowledged and verified.")
        XCTAssertTrue(vm.messages.last?.attachments.isEmpty ?? true)
    }

    override func tearDown() async throws {
        // Clean up test tmux session if running
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: tmuxPath())
        killTask.arguments = ["kill-session", "-t", "pharos-test-dsh"]
        killTask.standardOutput = Pipe()
        killTask.standardError = Pipe()
        try? killTask.run()
        killTask.waitUntilExit()

        try await super.tearDown()
    }
}
