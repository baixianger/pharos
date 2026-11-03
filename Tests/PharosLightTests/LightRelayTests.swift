import XCTest
@testable import PharosMeshCore
@testable import PharosRuntime

final class LightRelayTests: XCTestCase {
    private var stores: [URL] = []

    override func tearDown() {
        for store in stores {
            try? FileManager.default.removeItem(at: store)
        }
        stores.removeAll()
        super.tearDown()
    }

    func testRegistryResolvesStableNamesAndRejectsConflicts() throws {
        let relay = try makeRelay()
        let codex = try relay.register(member("codex-mini-pharos", app: "codex", session: "sess-codex"))
        XCTAssertEqual(try relay.register(codex).sessionID, "sess-codex")
        XCTAssertEqual(relay.member(named: "codex-mini-pharos")?.routes.map(\.id), ["app-server"])
        XCTAssertThrowsError(try relay.register(member("codex-mini-pharos", app: "codex", session: "other-session"))) { error in
            XCTAssertEqual(error as? LightRelayError, .duplicateMember("codex-mini-pharos"))
        }
        XCTAssertThrowsError(try relay.register(member("Owner@Example.com", app: "codex", session: "sess-1")))
        XCTAssertThrowsError(try relay.register(member("codex-mini-pharos", app: "codex", session: "sess-codex", host: "10.1.2.3")))
        XCTAssertEqual(relay.listMembers().map(\.name), ["codex-mini-pharos"])
    }

    func testReplyIDIssueLookupExpiryAndOnce() throws {
        let clock = ManualClock()
        let driver = FakeDriver(delivered("app-server"))
        let relay = try makeRelay(driver: driver, now: clock.now)
        let sent = try sendToCodex(relay, text: "ping")
        let replyID = try XCTUnwrap(sent.deliveries.first?.replyID)
        XCTAssertTrue(LightTokens.isValid(replyID, prefix: "r"))
        XCTAssertGreaterThanOrEqual(replyID.count, 10)
        XCTAssertTrue(sent.deliveries[0].header.contains("pharos reply \(replyID)"))
        XCTAssertTrue(sent.deliveries[0].header.contains("[pharos from=owner thread=\(sent.threadID) reply-id=\(replyID) hop=1/8]"))
        XCTAssertFalse(sent.deliveries[0].header.contains("codex-mini-pharos"))

        let answered = try relay.reply(replyID, text: "ack")
        XCTAssertEqual(answered.threadID, sent.threadID)
        XCTAssertEqual(answered.deliveries.map(\.to), ["owner"])
        XCTAssertEqual(try relay.read(thread: sent.threadID).filter { $0.kind == .message }.map(\.text), ["ping", "ack"])

        clock.advance(25 * 60 * 60)
        XCTAssertThrowsError(try relay.reply(replyID, text: "late")) { error in
            XCTAssertEqual(error as? LightRelayError, .expiredReply(replyID))
        }
        XCTAssertEqual(relay.rejections().last?.reason, "expired")
        XCTAssertThrowsError(try relay.reply(replyID, text: "again")) { error in
            XCTAssertEqual(error as? LightRelayError, .unknownReply(replyID))
        }

        let onceRelay = try makeRelay(driver: FakeDriver(delivered("app-server")))
        let onceSent = try sendToCodex(onceRelay, text: "once", once: true)
        let onceID = try XCTUnwrap(onceSent.deliveries.first?.replyID)
        _ = try onceRelay.reply(onceID, text: "first")
        XCTAssertThrowsError(try onceRelay.reply(onceID, text: "second")) { error in
            XCTAssertEqual(error as? LightRelayError, .consumedReply(onceID))
        }
        XCTAssertEqual(onceRelay.rejections().map(\.reason), ["consumed"])

        XCTAssertThrowsError(try relay.reply("nope", text: "x")) { error in
            XCTAssertEqual(error as? LightRelayError, .malformedReply("nope"))
        }
        XCTAssertThrowsError(try relay.reply("r_notissued", text: "x")) { error in
            XCTAssertEqual(error as? LightRelayError, .unknownReply("r_notissued"))
        }
        XCTAssertEqual(relay.rejections().map(\.reason).suffix(2), ["malformed", "unknown"])
        let before = relay.rejections().count
        XCTAssertThrowsError(try relay.read(replyID: "r_notissued"))
        XCTAssertEqual(relay.rejections().count, before)
    }

    func testSendIsPointToPointAndAReplyInheritsTheThread() throws {
        let driver = FakeDriver(delivered("app-server"))
        let relay = try makeRelay(driver: driver)
        try registerTrio(relay)
        XCTAssertEqual(LightMentions.tokens(in: "owner@example.com @codex-mini-pharos"), ["codex-mini-pharos"])

        XCTAssertThrowsError(try relay.send(from: "owner", to: [], text: "nobody")) { error in
            XCTAssertEqual(error as? LightRelayError, .noRecipients)
        }
        XCTAssertThrowsError(try relay.send(from: "owner", to: ["nobody"], text: "hi")) { error in
            XCTAssertEqual(error as? LightRelayError, .unknownMember("nobody"))
        }
        XCTAssertTrue(relay.listThreads().isEmpty)

        let direct = try relay.send(from: "owner", to: ["codex-mini-pharos"], text: "owner@example.com just talking")
        XCTAssertEqual(direct.deliveries.map(\.to), ["codex-mini-pharos"])
        XCTAssertEqual(direct.unresolved, [])
        let directView = try relay.show(thread: direct.threadID)
        XCTAssertEqual(directView.kind, .direct)
        XCTAssertEqual(directView.participants, ["owner", "codex-mini-pharos"])
        XCTAssertEqual(directView.thread.originator, "owner")

        let copied = try relay.send(from: "owner", to: ["codex-mini-pharos", "claude-mini", "codex-mini-pharos"], text: "ping both")
        XCTAssertNotEqual(copied.threadID, direct.threadID)
        XCTAssertEqual(copied.deliveries.map(\.to), ["codex-mini-pharos", "claude-mini"])
        XCTAssertEqual(Set(copied.deliveries.map(\.replyID)).count, 2)
        XCTAssertEqual(copied.hop, 1)
        for delivery in copied.deliveries {
            XCTAssertTrue(delivery.header.contains("thread=\(copied.threadID)"))
            XCTAssertTrue(delivery.header.contains("reply-id=\(delivery.replyID)"))
            let other = delivery.to == "claude-mini" ? "codex-mini-pharos" : "claude-mini"
            XCTAssertFalse(delivery.header.contains(other))
        }
        let group = try relay.show(thread: copied.threadID)
        XCTAssertEqual(group.kind, .group)
        XCTAssertEqual(group.participants, ["owner", "codex-mini-pharos", "claude-mini"])

        let back = try relay.reply(copied.deliveries[0].replyID, text: "ack")
        XCTAssertEqual(back.threadID, copied.threadID)
        XCTAssertEqual(back.deliveries.map(\.to), ["owner"])
        let broadcast = try relay.reply(direct.deliveries[0].replyID, text: "@ALL everyone")
        XCTAssertEqual(broadcast.threadID, direct.threadID)
        XCTAssertEqual(broadcast.deliveries.map(\.to), ["owner"])
        XCTAssertEqual(broadcast.unresolved, ["all"])

        let mentioned = try relay.reply(copied.deliveries[1].replyID, text: "@owner @codex-mini-pharos your turn @ghost")
        XCTAssertEqual(mentioned.threadID, copied.threadID)
        XCTAssertEqual(mentioned.deliveries.map(\.to), ["owner", "codex-mini-pharos"])
        XCTAssertEqual(mentioned.unresolved, ["ghost"])
        XCTAssertEqual(try relay.show(thread: copied.threadID).participants, ["owner", "codex-mini-pharos", "claude-mini"])

        let fresh = try relay.send(from: "owner", to: ["claude-mini"], text: "@all @codex-mini-pharos new topic")
        XCTAssertNotEqual(fresh.threadID, copied.threadID)
        XCTAssertEqual(fresh.deliveries.map(\.to), ["claude-mini"])
        XCTAssertEqual(try relay.show(thread: fresh.threadID).kind, .direct)
    }

    func testHopFollowsTheReplyChainAndStopsAtTheOriginator() throws {
        let relay = try makeRelay(driver: FakeDriver(delivered("app-server")))
        try registerTrio(relay)
        let sent = try relay.send(from: "owner", to: ["codex-mini-pharos"], text: "start", hopLimit: 3)
        XCTAssertEqual(sent.hop, 1)
        let toCodex = try XCTUnwrap(sent.deliveries.first?.replyID)
        let back = try relay.reply(toCodex, text: "@claude-mini joining")
        XCTAssertEqual(back.hop, 2)
        XCTAssertEqual(back.threadID, sent.threadID)
        XCTAssertEqual(back.deliveries.map(\.to), ["owner", "claude-mini"])
        let toOwner = try XCTUnwrap(back.deliveries.first { $0.to == "owner" }?.replyID)
        let again = try relay.reply(toOwner, text: "still here")
        XCTAssertEqual(again.hop, 3)
        XCTAssertEqual(again.threadID, sent.threadID)
        let toCodexAgain = try XCTUnwrap(again.deliveries.first { $0.to == "codex-mini-pharos" }?.replyID)
        let stopped = try relay.reply(toCodexAgain, text: "cannot continue")
        XCTAssertTrue(stopped.stopped)
        XCTAssertEqual(stopped.notice?.contains("Hop limit 3 reached"), true)
        XCTAssertEqual(stopped.deliveries.map(\.to), ["owner"])
        let stillOpen = try XCTUnwrap(back.deliveries.first { $0.to == "claude-mini" }?.replyID)
        XCTAssertThrowsError(try relay.reply(stillOpen, text: "later")) { error in
            XCTAssertEqual(error as? LightRelayError, .threadStopped(sent.threadID))
        }
        let anotherTopic = try relay.send(from: "owner", to: ["codex-mini-pharos"], text: "fresh")
        XCTAssertNotEqual(anotherTopic.threadID, sent.threadID)
        XCTAssertFalse(anotherTopic.stopped)
        let terminal = try XCTUnwrap(stopped.deliveries.first?.replyID)
        let ack = try relay.reply(terminal, text: "seen")
        XCTAssertTrue(ack.deliveries.isEmpty)
        XCTAssertTrue(try relay.read(thread: sent.threadID).contains { $0.text == "seen" })
    }

    func testReusableReplyAdvancesHopInsteadOfResettingIt() throws {
        let relay = try makeRelay(driver: FakeDriver(delivered("app-server")))
        let sent = try sendToCodex(relay, text: "start", hopLimit: 3)
        let replyID = try XCTUnwrap(sent.deliveries.first?.replyID)
        let first = try relay.reply(replyID, text: "one")
        XCTAssertEqual(first.hop, 2)
        let second = try relay.reply(replyID, text: "two")
        XCTAssertEqual(second.hop, 3)
        let third = try relay.reply(replyID, text: "three")
        XCTAssertTrue(third.stopped)
        XCTAssertEqual(third.threadID, sent.threadID)
    }

    func testSingleWriterQueuePreservesOrder() throws {
        let driver = FakeDriver(LightDriveResult(state: .busy, route: "app-server", fallback: false, liveVerified: false, detail: "writer lock"))
        let relay = try makeRelay(driver: driver)
        let first = try sendToCodex(relay, text: "one")
        let second = try sendToCodex(relay, text: "two")
        XCTAssertNotEqual(first.threadID, second.threadID)
        XCTAssertEqual(first.deliveries.map(\.state), [.queued])
        XCTAssertEqual(second.deliveries.map(\.state), [.queued])
        XCTAssertEqual(driver.calls.filter { $0.state == .delivered }.map(\.name), [])

        driver.result = delivered("app-server")
        XCTAssertEqual(relay.pump(), 2)
        let deliveredTo = driver.calls.filter { $0.state == .delivered }.map(\.body)
        XCTAssertEqual(deliveredTo.count, 2)
        XCTAssertTrue(deliveredTo[0].contains("one"))
        XCTAssertTrue(deliveredTo[1].contains("two"))
        XCTAssertTrue(deliveredTo[0].contains("pharos reply"))
        let firstStates = try relay.read(thread: first.threadID).filter { $0.kind == .delivery }.compactMap(\.state)
        let secondStates = try relay.read(thread: second.threadID).filter { $0.kind == .delivery }.compactMap(\.state)
        XCTAssertEqual(firstStates.last, .delivered)
        XCTAssertEqual(secondStates.last, .delivered)
    }

    func testQueuedReplyExpiresAndNotifiesTheOriginator() throws {
        let clock = ManualClock()
        let driver = FakeDriver(LightDriveResult(state: .busy, route: nil, fallback: false, liveVerified: false, detail: "busy"))
        let relay = try makeRelay(driver: driver, now: clock.now)
        let sent = try sendToCodex(relay, text: "hold")
        clock.advance(73 * 60 * 60)
        let report = relay.sweep()
        XCTAssertEqual(report.expiredQueued, 1)
        XCTAssertGreaterThanOrEqual(report.notices, 1)
        let log = try relay.read(thread: sent.threadID)
        XCTAssertTrue(log.contains { $0.kind == .notice && $0.to == "owner" && $0.text.contains("expired before delivery") })
        XCTAssertTrue(log.contains { $0.state == .expired })
    }

    func testWaitIngestsAProvenSessionReplyOnce() throws {
        let driver = FakeDriver(delivered("app-server"))
        let relay = try makeRelay(driver: driver)
        let sent = try sendToCodex(relay, text: "question")
        let replyID = try XCTUnwrap(sent.deliveries.first?.replyID)
        let pending = try relay.wait(replyID: replyID, timeout: 0)
        XCTAssertEqual(pending.status, .pending)
        driver.reads["codex-mini-pharos"] = "answer from the session"
        let waited = try relay.wait(replyID: replyID, timeout: 0)
        XCTAssertEqual(waited.status, .replied)
        XCTAssertEqual(waited.text, "answer from the session")
        let callsAfter = driver.calls.count
        let again = try relay.wait(replyID: replyID, timeout: 0)
        XCTAssertEqual(again.status, .replied)
        XCTAssertEqual(driver.calls.count, callsAfter)
    }

    func testForwarderDoesNotTouchTheLocalLedger() throws {
        let driver = FakeDriver(delivered("app-server"))
        let forwarder = RecordingForwarder(result: LightForwardResult(ok: true, message: "forwarded"))
        let relay = try makeRelay(driver: driver, forwarder: forwarder)
        let sent = try sendToCodex(relay, text: "hi")
        let replyID = try XCTUnwrap(sent.deliveries.first?.replyID)
        let forwarded = try relay.reply(replyID, text: "via ssh")
        XCTAssertTrue(forwarded.forwarded)
        XCTAssertEqual(forwarder.seen.map(\.0), [replyID])
        XCTAssertEqual(try relay.read(thread: sent.threadID).filter { $0.kind == .message }.map(\.text), ["hi"])
    }

    func testWebhookIsLoopbackOnlyAndIntakeReplies() throws {
        XCTAssertThrowsError(try LightRelay(store: freshStore(), webhook: "http://example.com/hook")) { error in
            XCTAssertEqual(error as? LightRelayError, .webhookNotLoopback)
        }
        let relay = try makeRelay(driver: FakeDriver(delivered("app-server")), webhook: "http://127.0.0.1:9/pharos/reply")
        let sent = try sendToCodex(relay, text: "hi")
        XCTAssertTrue(sent.deliveries[0].header.contains("http://127.0.0.1:9/pharos/reply"))
        let replyID = sent.deliveries[0].replyID
        let body = #"{"replyId":"\#(replyID)","text":"posted"}"#.data(using: .utf8)!
        let accepted = try LightWebhookIntake.accept(body, relay: relay)
        XCTAssertEqual(accepted.threadID, sent.threadID)
        XCTAssertEqual(accepted.deliveries.map(\.to), ["owner"])
    }

    func testStoreReloadsDerivedParticipantsWithoutARoster() throws {
        let store = freshStore()
        let first = try LightRelay(store: store, driver: FakeDriver(delivered("app-server")))
        try registerTrio(first)
        let sent = try first.send(from: "owner", to: ["codex-mini-pharos", "claude-mini"], text: "persist")
        let before = try first.show(thread: sent.threadID)
        let second = try LightRelay(store: store, driver: IdleLightDriver())
        XCTAssertEqual(second.member(named: "codex-mini-pharos")?.sessionID, "sess-codex")
        let after = try second.show(thread: sent.threadID)
        XCTAssertEqual(after.participants, before.participants)
        XCTAssertEqual(after.kind, .group)
        XCTAssertEqual(try second.read(replyID: sent.deliveries[0].replyID).first { $0.kind == .message }?.text, "persist")
        let data = try Data(contentsOf: store.appendingPathComponent("state.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let threads = try XCTUnwrap(object["threads"] as? [[String: Any]])
        XCTAssertEqual(threads.count, 1)
        XCTAssertNil(threads[0]["participants"])
        XCTAssertNil(threads[0]["members"])
        XCTAssertNil(threads[0]["openedBy"])
        XCTAssertEqual(threads[0]["originator"] as? String, "owner")
        XCTAssertEqual(object["version"] as? Int, 2)
    }

    func testExternalDriverDefersTheHeadlessRouteWithoutClaimingALiveTurn() throws {
        let driver = ExternalLightDriver()
        let relay = try makeRelay(driver: driver)
        _ = try relay.register(member("owner", app: "shell", session: "owner-1", routes: [LightRoute.named("native")]))
        _ = try relay.register(member("codex-mini-pharos", app: "codex", session: "sess-codex", routes: []))
        let sent = try relay.send(from: "owner", to: ["codex-mini-pharos"], text: "hello")
        XCTAssertEqual(sent.deliveries.first?.state, .deferred)
        XCTAssertEqual(sent.deliveries.first?.route, "app-server")
        XCTAssertEqual(sent.deliveries.first?.fallback, false)
        XCTAssertEqual(sent.deliveries.first?.liveVerified, false)
        XCTAssertNil(driver.readReply(member: member("codex-mini-pharos", app: "codex", session: "sess-codex"), since: Date()))
    }

    func testCommandsRoundTrip() throws {
        let relay = try makeRelay(driver: FakeDriver(delivered("native")))
        let routes: (String) -> [LightRoute] = { _ in [LightRoute.named("native")] }
        func run(_ command: String, _ arguments: [String]) -> LightCLIResult {
            LightCommands.execute(command: command, arguments: arguments, relay: relay, routesForApp: routes)
        }
        XCTAssertEqual(run("member", ["register"]).exitCode, 2)
        XCTAssertEqual(run("member", ["register", "--name", "owner", "--host", "broker", "--app", "shell", "--project", "pharos", "--session", "owner-1"]).exitCode, 0)
        XCTAssertEqual(run("member", ["register", "--name", "codex-mini-pharos", "--host", "broker", "--app", "codex", "--project", "pharos", "--session", "sess-codex"]).exitCode, 0)
        XCTAssertEqual(run("member", ["register", "--name", "claude-mini", "--host", "broker", "--app", "claude", "--project", "pharos", "--session", "sess-claude"]).exitCode, 0)
        XCTAssertEqual(run("thread", ["new", "--member", "owner", "--member", "codex-mini-pharos"]).exitCode, 2)
        XCTAssertEqual(run("thread", ["add", "t_nope", "--member", "claude-mini"]).exitCode, 2)
        let sent = run("send", ["--from", "owner", "codex-mini-pharos", "--", "hello", "there"])
        XCTAssertEqual(sent.exitCode, 0)
        XCTAssertTrue(sent.text.contains("delivered"))
        XCTAssertTrue(sent.text.contains("hop 1/8"))
        let threadID = sent.text.split(separator: "\n").first.map { line -> String in
            let parts = line.split(separator: " ")
            return parts.count >= 2 ? String(parts[1]) : ""
        } ?? ""
        let listed = run("thread", ["list"])
        XCTAssertTrue(listed.text.contains(threadID))
        XCTAssertTrue(listed.text.contains("direct"))
        XCTAssertTrue(listed.text.contains("owner,codex-mini-pharos"))
        let shown = run("thread", ["show", threadID])
        XCTAssertTrue(shown.text.contains("kind direct"))
        XCTAssertTrue(shown.text.contains("hello there"))
        let read = run("read", ["--thread", threadID])
        XCTAssertTrue(read.text.contains("hello there"))
        let replyID = sent.text.split(separator: "\n").dropFirst().first.map { String($0.split(separator: "\t")[2]) } ?? ""
        XCTAssertEqual(run("read", [replyID]).exitCode, 0)
        let group = run("send", ["--from", "owner", "--to", "codex-mini-pharos", "--to", "claude-mini", "--hop-limit", "4", "--", "both"])
        XCTAssertEqual(group.exitCode, 0)
        XCTAssertTrue(group.text.contains("hop 1/4"))
        let groupID = group.text.split(separator: "\n").first.map { String($0.split(separator: " ")[1]) } ?? ""
        let groupShow = run("thread", ["show", groupID])
        XCTAssertTrue(groupShow.text.contains("kind group"))
        XCTAssertTrue(groupShow.text.contains("owner,codex-mini-pharos,claude-mini"))
        XCTAssertEqual(run("member", ["list"]).text.contains("codex-mini-pharos"), true)
    }

    private func registerPair(_ relay: LightRelay) throws {
        if relay.member(named: "owner") == nil {
            _ = try relay.register(member("owner", app: "shell", session: "owner-1"))
        }
        if relay.member(named: "codex-mini-pharos") == nil {
            _ = try relay.register(member("codex-mini-pharos", app: "codex", session: "sess-codex"))
        }
    }

    private func registerTrio(_ relay: LightRelay) throws {
        try registerPair(relay)
        if relay.member(named: "claude-mini") == nil {
            _ = try relay.register(member("claude-mini", app: "claude", session: "sess-claude", routes: []))
        }
    }

    private func sendToCodex(_ relay: LightRelay, text: String, hopLimit: Int? = nil, once: Bool = false) throws -> LightSendResult {
        try registerPair(relay)
        return try relay.send(from: "owner", to: ["codex-mini-pharos"], text: text, once: once, hopLimit: hopLimit)
    }

    private func makeRelay(driver: any LightSessionDriver = IdleLightDriver(),
                           now: (@Sendable () -> Date)? = nil,
                           forwarder: (any LightReplyForwarding)? = nil,
                           webhook: String? = nil) throws -> LightRelay {
        if let now {
            return try LightRelay(store: freshStore(), now: now, driver: driver, forwarder: forwarder, webhook: webhook)
        }
        return try LightRelay(store: freshStore(), driver: driver, forwarder: forwarder, webhook: webhook)
    }

    private func freshStore() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pharos-light-\(UUID().uuidString)", isDirectory: true)
        stores.append(url)
        return url
    }

    private func member(_ name: String, app: String, session: String, host: String = "broker",
                        routes: [LightRoute]? = nil) -> LightMember {
        LightMember(name: name, host: host, app: app, project: "pharos", sessionID: session,
                    routes: routes ?? [LightRoute.named("app-server")])
    }

    private func delivered(_ route: String) -> LightDriveResult {
        LightDriveResult(state: .delivered, route: route, fallback: false, liveVerified: true, detail: "fake")
    }
}

final class LightDriverTests: XCTestCase {
    func testRouteOrderPrefersHeadlessAndLabelsTmuxLast() {
        XCTAssertEqual(LightRouteCatalog.defaults(for: "codex").map(\.id), ["app-server", "ipc", "desktop", "tmux"])
        XCTAssertEqual(LightRouteCatalog.defaults(for: "dsh").map(\.id), ["web", "desktop", "files", "tmux"])
        XCTAssertEqual(LightRouteCatalog.defaults(for: "claude").map(\.id), ["headless", "tmux"])
        XCTAssertEqual(LightRouteCatalog.defaults(for: "ag").map(\.id), ["desktop"])
        XCTAssertTrue(LightRouteCatalog.codex.last?.fallback == true)
        XCTAssertEqual(LightRouteCatalog.dsh.first { $0.id == "files" }?.access, .read)
        let codex = member("codex-mini-pharos", app: "codex", session: "sess-codex", routes: [])
        XCTAssertEqual(LightRoutePlanner.select(member: codex, operation: .send)?.id, "app-server")
        let filesThenTmux = member("codex-mini-pharos", app: "dsh", session: "sess-dsh", routes: [
            LightRoute(id: "files", access: .read, fallback: false, summary: "read-only session files."),
            LightRoute(id: "tmux", access: .write, fallback: true, summary: "last resort: tmux send-keys and capture-pane."),
        ])
        let selected = LightRoutePlanner.select(member: filesThenTmux, operation: .send)
        XCTAssertEqual(selected?.id, "tmux")
        XCTAssertEqual(selected?.fallback, true)
    }

    func testHeadlessArgvDoesNotAnswerApprovalsOrLeaveLoopback() {
        let codex = member("codex-mini-pharos", app: "codex", session: "sess-codex", routes: [])
        let route = try! XCTUnwrap(LightRoutePlanner.select(member: codex, operation: .send))
        let invocation = LightRoutePlanner.invocation(member: codex, route: route, body: "hello", binaries: .names)
        XCTAssertEqual(invocation.argv, ["codex", "exec", "resume", "sess-codex", "-", "--json", "--skip-git-repo-check"])
        XCTAssertEqual(invocation.stdin, "hello")
        XCTAssertTrue(invocation.executable)
        assertNoApprovalBypass(invocation.argv + [invocation.summary])

        let claude = member("claude-mini", app: "claude", session: "sess-claude", routes: [])
        let claudeRoute = try! XCTUnwrap(LightRoutePlanner.select(member: claude, operation: .send))
        let claudeCall = LightRoutePlanner.invocation(member: claude, route: claudeRoute, body: "hello", binaries: .names)
        XCTAssertEqual(claudeCall.argv, ["claude", "-p", "--resume", "sess-claude"])
        XCTAssertEqual(claudeCall.stdin, "hello")
        assertNoApprovalBypass(claudeCall.argv)

        let dsh = member("dsh-mini", app: "dsh", session: "sess-dsh", routes: [])
        let dshRoute = try! XCTUnwrap(LightRoutePlanner.select(member: dsh, operation: .send))
        let dshCall = LightRoutePlanner.invocation(member: dsh, route: dshRoute, body: "hello", binaries: .names)
        XCTAssertEqual(dshCall.argv, ["dsh", "--profile", "web", "--no-open", "--port", "0", "--host", "127.0.0.1"])
        XCTAssertFalse(dshCall.executable)
        XCTAssertTrue(dshCall.loopback)
        XCTAssertTrue(dshCall.summary.contains("stop after the turn"))

        let tmux = LightRoutePlanner.invocation(
            member: filesThenTmuxMember(),
            route: LightRoute.named("tmux"),
            body: "hello",
            binaries: .names
        )
        XCTAssertEqual(tmux.argv.prefix(4), ["tmux", "send-keys", "-t", "sess-dsh"].prefix(4))
        XCTAssertTrue(tmux.fallback)
        XCTAssertTrue(tmux.summary.contains("last resort"))
        let capture = LightRoutePlanner.readInvocation(member: filesThenTmuxMember(), route: LightRoute.named("tmux"), binaries: .names)
        XCTAssertEqual(capture.argv, ["tmux", "capture-pane", "-t", "sess-dsh", "-p"])
    }

    func testLiveFailureFallsThroughWithoutMarkingTheTurnVerified() {
        let runner = ScriptedRunner([
            LightProcessOutput(status: 1, stdout: "", stderr: "writer lock"),
        ])
        let driver = ExternalLightDriver(allowLive: true, runner: runner)
        let codex = member("codex-mini-pharos", app: "codex", session: "sess-codex", routes: [])
        let result = driver.deliver(member: codex, body: "hello")
        XCTAssertEqual(result.state, .deferred)
        XCTAssertEqual(result.route, "ipc")
        XCTAssertFalse(result.liveVerified)
        XCTAssertEqual(runner.invocations.map { $0.argv.first }, ["codex"])
        XCTAssertTrue(result.detail.contains("not certified") || result.detail.contains("unverified"))
        XCTAssertNil(driver.readReply(member: codex, since: Date()))
    }

    func testSSHForwarderUsesTheExistingRouteWithoutATunnel() {
        let runner = ScriptedRunner([LightProcessOutput(status: 0, stdout: "", stderr: "")])
        let forwarder = SSHLightReplyForwarder(destination: "broker-ssh", runner: runner)
        let result = forwarder.forward(replyID: "r_token1xxx", text: "hello 'there'")
        XCTAssertEqual(result?.ok, true)
        let argv = try! XCTUnwrap(runner.invocations.first?.argv)
        XCTAssertEqual(argv.prefix(6).map { $0 }, ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "--"])
        XCTAssertEqual(argv.dropFirst(6).first, "broker-ssh")
        XCTAssertFalse(argv.contains("-L"))
        XCTAssertFalse(argv.contains("-R"))
        XCTAssertTrue(argv.joined(separator: " ").contains("pharos reply 'r_token1xxx'"))
        XCTAssertTrue(argv.joined(separator: " ").contains(SSHLightReplyForwarder.shellQuote("hello 'there'")))
    }

    private func assertNoApprovalBypass(_ parts: [String]) {
        let joined = parts.joined(separator: " ").lowercased()
        for banned in ["dangerously", "approve-for-me", "bypass", "requestapproval"] {
            XCTAssertFalse(joined.contains(banned), banned)
        }
    }

    private func filesThenTmuxMember() -> LightMember {
        member("dsh-mini", app: "dsh", session: "sess-dsh", routes: [LightRoute.named("tmux")])
    }

    private func member(_ name: String, app: String, session: String, routes: [LightRoute]) -> LightMember {
        LightMember(name: name, host: "broker", app: app, project: "pharos", sessionID: session, routes: routes)
    }
}

private final class ManualClock: @unchecked Sendable {
    var current = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { current }
    func advance(_ interval: TimeInterval) { current = current.addingTimeInterval(interval) }
}

private final class FakeDriver: LightSessionDriver, @unchecked Sendable {
    struct Call {
        var name: String
        var body: String
        var state: LightDriveResult.State
    }

    var result: LightDriveResult
    var calls: [Call] = []
    var reads: [String: String] = [:]

    init(_ result: LightDriveResult) { self.result = result }

    func deliver(member: LightMember, body: String) -> LightDriveResult {
        calls.append(Call(name: member.name, body: body, state: result.state))
        return result
    }

    func readReply(member: LightMember, since: Date) -> String? {
        _ = since
        return reads[member.name]
    }
}

private final class RecordingForwarder: LightReplyForwarding, @unchecked Sendable {
    var result: LightForwardResult?
    var seen: [(String, String)] = []
    init(result: LightForwardResult?) { self.result = result }
    func forward(replyID: String, text: String) -> LightForwardResult? {
        seen.append((replyID, text))
        return result
    }
}

private final class ScriptedRunner: LightProcessRunning, @unchecked Sendable {
    var results: [LightProcessOutput]
    var invocations: [LightInvocation] = []
    init(_ results: [LightProcessOutput]) { self.results = results }
    func run(_ invocation: LightInvocation, stdin: String) -> LightProcessOutput {
        var copy = invocation
        copy.stdin = stdin
        invocations.append(copy)
        if results.isEmpty { return LightProcessOutput(status: 1, stdout: "", stderr: "none") }
        return results.removeFirst()
    }
}
