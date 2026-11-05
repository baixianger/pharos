import XCTest
@testable import PharosMeshCore
@testable import PharosRuntime

final class LightThreadRosterTests: XCTestCase {
    private var stores: [URL] = []

    override func tearDown() {
        for store in stores { try? FileManager.default.removeItem(at: store) }
        stores.removeAll()
        super.tearDown()
    }

    private func makeRelay() throws -> LightRelay {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-roster-test-\(UUID().uuidString)")
        stores.append(dir)
        return try LightRelay(store: dir)
    }

    private func registerMember(_ relay: LightRelay, name: String, host: String = "local", app: String = "codex") throws {
        _ = try relay.register(LightMember(
            name: name, host: host, app: app, project: "test-proj", sessionID: "sess-\(name)",
            routes: [LightRoute(id: "tmux", access: .write, fallback: false, summary: "tmux")]
        ))
    }

    private func run(_ relay: LightRelay, _ command: String, _ args: [String],
                     agents: (any LightMemberAgents)? = nil,
                     hostOwner: (@Sendable (String) -> String)? = nil,
                     refreshInventory: (@Sendable (_ host: String) -> Void)? = nil) -> LightCLIResult {
        LightCommands.execute(
            command: command,
            arguments: args,
            relay: relay,
            routesForApp: { _ in [LightRoute(id: "tmux", access: .write, fallback: false, summary: "")] },
            agents: agents,
            hostOwner: hostOwner,
            refreshInventory: refreshInventory
        )
    }

    // MARK: - 1. Roster on Send

    func testRosterOnSend() throws {
        let relay = try makeRelay()
        try registerMember(relay, name: "alice")
        try registerMember(relay, name: "bob")
        try registerMember(relay, name: "charlie")

        // Order kept, sender first, deduped
        let sent = try relay.send(from: "alice", to: ["bob"], cc: ["charlie", "bob", "alice"], text: "hi team")
        let members = try relay.threadMembers(sent.threadID)
        XCTAssertEqual(members, ["alice", "bob", "charlie"])

        let view = try relay.show(thread: sent.threadID)
        XCTAssertEqual(view.participants, ["alice", "bob", "charlie"])
        XCTAssertEqual(view.roster, ["alice", "bob", "charlie"])
        XCTAssertEqual(view.thread.roster, ["alice", "bob", "charlie"])
    }

    // MARK: - 2. DM vs Group Kind

    func testDMVsGroupKind() throws {
        let relay = try makeRelay()
        try registerMember(relay, name: "alice")
        try registerMember(relay, name: "bob")
        try registerMember(relay, name: "charlie")
        try registerMember(relay, name: "dave")

        // 2 members -> direct (DM)
        let dm = try relay.send(from: "alice", to: ["bob"], text: "private chat")
        var dmView = try relay.show(thread: dm.threadID)
        XCTAssertEqual(dmView.kind, .direct)

        // 3 members -> group
        let group = try relay.send(from: "alice", to: ["bob"], cc: ["charlie"], text: "group chat")
        var groupView = try relay.show(thread: group.threadID)
        XCTAssertEqual(groupView.kind, .group)

        // Remove from group (3 -> 2): transitions to .direct
        try relay.removeThreadMember(group.threadID, name: "charlie")
        groupView = try relay.show(thread: group.threadID)
        XCTAssertEqual(groupView.kind, .direct)

        // Add to DM (2 -> 3): transitions to .group
        try relay.addThreadMember(dm.threadID, name: "dave")
        dmView = try relay.show(thread: dm.threadID)
        XCTAssertEqual(dmView.kind, .group)
    }

    // MARK: - 3. Add/Remove Members and Notices

    func testAddRemoveMembersAndNotices() throws {
        let relay = try makeRelay()
        try registerMember(relay, name: "alice")
        try registerMember(relay, name: "bob")
        try registerMember(relay, name: "charlie")
        try registerMember(relay, name: "dave")

        let sent = try relay.send(from: "alice", to: ["bob"], text: "start")
        let tid = sent.threadID

        // Add charlie by pharos (default)
        try relay.addThreadMember(tid, name: "charlie")
        XCTAssertEqual(try relay.threadMembers(tid), ["alice", "bob", "charlie"])
        let logAfterCharlie = try relay.read(thread: tid)
        XCTAssertTrue(logAfterCharlie.contains { $0.kind == .notice && $0.text == "charlie added by pharos" })

        // Add dave by alice
        try relay.addThreadMember(tid, name: "dave", by: "alice")
        XCTAssertEqual(try relay.threadMembers(tid), ["alice", "bob", "charlie", "dave"])
        let logAfterDave = try relay.read(thread: tid)
        XCTAssertTrue(logAfterDave.contains { $0.kind == .notice && $0.text == "dave added by alice" })

        // Add unknown member -> unknownMember
        XCTAssertThrowsError(try relay.addThreadMember(tid, name: "ghost")) { error in
            XCTAssertEqual(error as? LightRelayError, .unknownMember("ghost"))
        }

        // Remove charlie by pharos (default)
        try relay.removeThreadMember(tid, name: "charlie")
        XCTAssertEqual(try relay.threadMembers(tid), ["alice", "bob", "dave"])
        let logRemoveCharlie = try relay.read(thread: tid)
        XCTAssertTrue(logRemoveCharlie.contains { $0.kind == .notice && $0.text == "charlie removed" })

        // Remove dave by bob
        try relay.removeThreadMember(tid, name: "dave", by: "bob")
        XCTAssertEqual(try relay.threadMembers(tid), ["alice", "bob"])
        let logRemoveDave = try relay.read(thread: tid)
        XCTAssertTrue(logRemoveDave.contains { $0.kind == .notice && $0.text == "dave removed by bob" })

        // Remove member not in thread -> memberNotInThread
        XCTAssertThrowsError(try relay.removeThreadMember(tid, name: "dave")) { error in
            XCTAssertEqual(error as? LightRelayError, .memberNotInThread(member: "dave", thread: tid))
        }

        // Remove originator alice while bob remains -> allowed!
        try relay.removeThreadMember(tid, name: "alice")
        XCTAssertEqual(try relay.threadMembers(tid), ["bob"])

        // Remove last member bob -> cannotRemoveLastMember
        XCTAssertThrowsError(try relay.removeThreadMember(tid, name: "bob")) { error in
            XCTAssertEqual(error as? LightRelayError, .cannotRemoveLastMember(thread: tid))
        }
    }

    // MARK: - 4. sendToThread Fan-out Excludes Sender and Removed Members

    func testSendToThreadFanoutExcludesSenderAndRemovedMembers() throws {
        let relay = try makeRelay()
        try registerMember(relay, name: "alice")
        try registerMember(relay, name: "bob")
        try registerMember(relay, name: "charlie")

        let sent = try relay.send(from: "alice", to: ["bob", "charlie"], text: "first")
        let tid = sent.threadID

        // Save charlie's replyID from initial delivery
        let charlieDelivery = try XCTUnwrap(sent.deliveries.first { $0.to == "charlie" })
        let charlieTicket = charlieDelivery.replyID

        // Send to thread: fanout excludes sender "alice"
        let res1 = try relay.sendToThread(tid, from: "alice", text: "round 2")
        XCTAssertEqual(res1.deliveries.map(\.to).sorted(), ["bob", "charlie"])

        // Remove charlie
        try relay.removeThreadMember(tid, name: "charlie")

        // Send to thread again: fanout delivers only to "bob"
        let res2 = try relay.sendToThread(tid, from: "alice", text: "round 3")
        XCTAssertEqual(res2.deliveries.map(\.to), ["bob"])

        // Charlie tries to send to thread: rejected with memberNotInThread
        XCTAssertThrowsError(try relay.sendToThread(tid, from: "charlie", text: "intruder")) { error in
            XCTAssertEqual(error as? LightRelayError, .memberNotInThread(member: "charlie", thread: tid))
        }

        // Charlie's reply using previous ticket is still recorded
        let replyRes = try relay.reply(charlieTicket, text: "replying after removed")
        XCTAssertEqual(replyRes.threadID, tid)
        let log = try relay.read(thread: tid)
        XCTAssertTrue(log.contains { $0.from == "charlie" && $0.text == "replying after removed" })
    }

    // MARK: - 5. Old-Thread Fallback

    func testOldThreadFallback() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-old-thread-test-\(UUID().uuidString)")
        stores.append(dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("logs"), withIntermediateDirectories: true)
        let state = #"{"version":3,"members":[{"name":"alice","host":"local","app":"codex","project":"test","sessionID":"a-1","routes":[{"id":"tmux","access":"write","fallback":false,"summary":"tmux"}]},{"name":"bob","host":"local","app":"codex","project":"test","sessionID":"b-1","routes":[{"id":"tmux","access":"write","fallback":false,"summary":"tmux"}]}],"threads":[{"id":"t_old_1","originator":"alice","hopLimit":8,"stopped":false,"createdAt":1700000000}],"ledger":[],"outbox":[]}"#
        try Data(state.utf8).write(to: dir.appendingPathComponent("state.json"))
        let line = #"{"id":"m_old1","kind":"message","threadID":"t_old_1","from":"alice","text":"old hello","mentions":[],"hop":1,"at":1700000000,"recipients":["bob"]}"#
        try Data((line + "\n").utf8).write(to: dir.appendingPathComponent("logs/t_old_1.jsonl"))

        let relay = try LightRelay(store: dir)

        // Showing old thread computes participants
        let view = try relay.show(thread: "t_old_1")
        XCTAssertEqual(view.participants, ["alice", "bob"])
        XCTAssertNil(view.roster)

        // threadMembers returns computed participants
        let members = try relay.threadMembers("t_old_1")
        XCTAssertEqual(members, ["alice", "bob"])

        // Calling sendToThread materializes roster
        let res = try relay.sendToThread("t_old_1", from: "alice", text: "now updated")
        XCTAssertEqual(res.deliveries.map(\.to), ["bob"])

        let updatedView = try relay.show(thread: "t_old_1")
        XCTAssertEqual(updatedView.roster, ["alice", "bob"])
        XCTAssertEqual(updatedView.thread.roster, ["alice", "bob"])
    }

    // MARK: - 6. Add by Address Triggers Adopt

    private final class MockAdoptAgents: LightMemberAgents, @unchecked Sendable {
        var adopted: [(name: String, app: String, cwd: String, sessionID: String, host: String)] = []

        func launch(name: String, app: String, cwd: String, host: String, model: String?, tmuxSession: String?,
                    openingMessage: String?, project: String) throws -> LightMember {
            throw CLIAgentLifecycleError.invalid("not launch")
        }
        func revive(_ member: LightMember) throws -> LightTmuxBinding {
            throw CLIAgentLifecycleError.invalid("not revive")
        }
        func stop(_ member: LightMember, force: Bool) throws -> LightTmuxBinding {
            throw CLIAgentLifecycleError.invalid("not stop")
        }
        func status(_ member: LightMember) -> LightMemberRuntimeStatus? { nil }

        func adopt(name: String, app: String, cwd: String, sessionID: String, host: String, model: String?,
                   tmuxSession: String?, project: String, autoRevive: Bool) throws -> LightMember {
            adopted.append((name: name, app: app, cwd: cwd, sessionID: sessionID, host: host))
            let binding = LightTmuxBinding(session: tmuxSession ?? "pharos-\(name)", cwd: cwd, model: model,
                                          agentPID: 1234, agentStarted: "now")
            return LightMember(
                name: name, host: host, app: app, project: project, sessionID: sessionID,
                routes: [LightRoute(id: "tmux", access: .write, fallback: false, summary: "tmux")],
                tmux: binding
            )
        }
    }

    func testAddByAddressTriggersAdopt() throws {
        let relay = try makeRelay()
        try registerMember(relay, name: "alice")
        try registerMember(relay, name: "bob")

        let invStore = LightInventoryStore(rootDir: relay.storeURL)
        let session = LightSessionEntry(app: "codex", id: "019a2b3c4d5e", cwd: "/tmp/my-proj", title: "Task", state: "idle")
        let inv = LightNodeInventory(node: "mini", at: Date(), sessions: [session], notes: [])
        try invStore.save(node: "mini", inventory: inv)

        let mockAgents = MockAdoptAgents()
        let sent = try relay.send(from: "alice", to: ["bob"], text: "setup")
        let tid = sent.threadID

        // Add by address with --name
        let res = run(
            relay, "thread", [tid, "member", "add", "mini/codex/my-proj/019a2b3c4d5e", "--name", "my-adopted"],
            agents: mockAgents
        )
        XCTAssertEqual(res.exitCode, 0, res.text)
        XCTAssertTrue(res.text.contains("added my-adopted to \(tid)"))
        XCTAssertEqual(mockAgents.adopted.count, 1)
        XCTAssertEqual(mockAgents.adopted[0].name, "my-adopted")
        XCTAssertEqual(mockAgents.adopted[0].sessionID, "019a2b3c4d5e")

        // Member list for thread shows adopted member
        let listRes = run(relay, "thread", [tid, "member", "list"])
        XCTAssertEqual(listRes.exitCode, 0)
        XCTAssertTrue(listRes.text.contains("my-adopted\tcodex/mini"))

        // Adding again by address detects already existing member and does not adopt again
        let res2 = run(
            relay, "thread", [tid, "member", "add", "mini/codex/my-proj/019a2b3c4d5e"],
            agents: mockAgents
        )
        XCTAssertEqual(res2.exitCode, 0, res2.text)
        XCTAssertTrue(res2.text.contains("added my-adopted to \(tid)"))
        XCTAssertEqual(mockAgents.adopted.count, 1, "Should not adopt again")
    }

    // MARK: - 7. CLI Parsing of Thread and Member Commands

    func testCLIParsing() throws {
        let relay = try makeRelay()
        try registerMember(relay, name: "alice")
        try registerMember(relay, name: "bob")
        try registerMember(relay, name: "charlie")

        // thread list columns: THREAD\tSTATE\tKIND\tMEMBERS\tHOP-LIMIT
        let sent = try relay.send(from: "alice", to: ["bob"], text: "hello")
        let listRes = run(relay, "thread", ["list"])
        XCTAssertEqual(listRes.exitCode, 0)
        let lines = listRes.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "THREAD\tSTATE\tKIND\tMEMBERS\tHOP-LIMIT")
        XCTAssertTrue(lines[1].contains(sent.threadID))
        XCTAssertTrue(lines[1].contains("\topen\tdm\talice,bob\t"))

        // thread <id> member list
        let memberListRes = run(relay, "thread", [sent.threadID, "member", "list"])
        XCTAssertEqual(memberListRes.exitCode, 0)
        XCTAssertTrue(memberListRes.text.contains("alice\tcodex/local"))
        XCTAssertTrue(memberListRes.text.contains("bob\tcodex/local"))

        // thread <id> member add charlie
        let addRes = run(relay, "thread", [sent.threadID, "member", "add", "charlie", "--from", "alice"])
        XCTAssertEqual(addRes.exitCode, 0)
        XCTAssertTrue(addRes.text.contains("added charlie to \(sent.threadID)"))

        // Alternative syntax: thread member list <id>
        let altListRes = run(relay, "thread", ["member", "list", sent.threadID])
        XCTAssertEqual(altListRes.exitCode, 0)
        XCTAssertTrue(altListRes.text.contains("charlie\tcodex/local"))

        // thread <id> member remove charlie
        let removeRes = run(relay, "thread", [sent.threadID, "member", "remove", "charlie"])
        XCTAssertEqual(removeRes.exitCode, 0)
        XCTAssertTrue(removeRes.text.contains("removed charlie from \(sent.threadID)"))

        // send --thread T --from X -- text
        let sendThreadRes = run(relay, "send", ["--thread", sent.threadID, "--from", "alice", "--", "message to thread"])
        XCTAssertEqual(sendThreadRes.exitCode, 0, sendThreadRes.text)
        XCTAssertTrue(sendThreadRes.text.contains("thread \(sent.threadID)"))

        // send --thread T with --to is an error
        let badSendRes = run(relay, "send", ["--thread", sent.threadID, "--from", "alice", "--to", "bob", "--", "illegal"])
        XCTAssertEqual(badSendRes.exitCode, 1)
        XCTAssertTrue(badSendRes.text.contains("--to cannot be used with --thread"))

        // thread stop <id>
        let stopRes = run(relay, "thread", ["stop", sent.threadID])
        XCTAssertEqual(stopRes.exitCode, 0)
        XCTAssertTrue(stopRes.text.contains("stopped thread \(sent.threadID)"))

        // Sending to stopped thread fails
        let stoppedSend = run(relay, "send", ["--thread", sent.threadID, "--from", "alice", "--", "stopped now"])
        XCTAssertEqual(stoppedSend.exitCode, 1)
        XCTAssertTrue(stoppedSend.text.contains("thread \(sent.threadID) is stopped"))
    }
}
