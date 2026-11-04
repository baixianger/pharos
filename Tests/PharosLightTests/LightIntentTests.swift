import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import PharosMeshCore
@testable import PharosRuntime

final class LightIntentTests: XCTestCase {
    private var stores: [URL] = []

    override func tearDown() {
        for store in stores { try? FileManager.default.removeItem(at: store) }
        stores.removeAll()
        super.tearDown()
    }

    func testBodyMentionsNeverDeliverAndOnlyHint() throws {
        let driver = RecordingDriver()
        let relay = try makeRelay(driver: driver)
        try registerTrio(relay)
        let sent = try relay.send(from: "owner", to: ["codex"], text: "please ask @claude and mail owner@example.com")
        XCTAssertEqual(sent.deliveries.map(\.to), ["codex"])
        XCTAssertEqual(sent.hints, ["claude"])
        XCTAssertEqual(driver.names, ["codex"])
        let cli = LightCommands.execute(command: "send", arguments: ["--from", "owner", "--to", "codex", "--", "hi @claude"],
                                        relay: relay, routesForApp: { _ in [] })
        XCTAssertEqual(cli.exitCode, 0, cli.text)
        XCTAssertEqual(cli.notes, ["hint: body mentions @claude; use --cc claude to copy them"])
        XCTAssertFalse(cli.text.contains("claude"))
        let json = LightCommands.execute(command: "send", arguments: ["--from", "owner", "--to", "codex", "--json", "--", "hi @claude"],
                                         relay: relay, routesForApp: { _ in [] })
        XCTAssertTrue(json.text.contains("\"hints\""))
    }

    func testAskAnswerIsRecordedForTheSenderUnlessDeliver() throws {
        let driver = RecordingDriver()
        let relay = try makeRelay(driver: driver)
        try registerTrio(relay)
        let sent = try relay.send(from: "codex", to: ["claude"], text: "what is 2+2?")
        XCTAssertEqual(sent.intent, .ask)
        let ask = try XCTUnwrap(sent.deliveries.first)
        XCTAssertTrue(ask.header.contains("intent=ask"))
        XCTAssertTrue(ask.header.contains("pharos reply \(ask.replyID)"))
        XCTAssertFalse(ask.header.contains("@mention"))
        driver.reads["claude"] = "4"
        let waited = try relay.wait(replyID: ask.replyID, timeout: 0)
        XCTAssertEqual(waited.status, .replied)
        XCTAssertEqual(waited.text, "4")
        XCTAssertEqual(waited.send?.deliveries.map(\.state), [.recorded])
        XCTAssertNotNil(waited.nextReplyID)
        XCTAssertEqual(driver.names, ["claude"], "the answer must not wake the asker")
        let log = try relay.read(thread: sent.threadID)
        XCTAssertEqual(log.last { $0.kind == .message }?.intent, .answer)
        XCTAssertTrue(log.contains { $0.kind == .delivery && $0.to == "codex" && $0.state == .recorded })
        // Asking back is delivered.
        let back = try relay.reply(ask.replyID, text: "which base?", intent: .ask)
        XCTAssertEqual(back.deliveries.map(\.state), [.delivered])

        // --deliver on send applies to its replies.
        let woke = try relay.send(from: "codex", to: ["claude"], text: "ping", deliverReplies: true)
        let reply = try relay.reply(woke.deliveries[0].replyID, text: "pong")
        XCTAssertEqual(reply.deliveries.map(\.state), [.delivered])
        XCTAssertTrue(reply.deliveries[0].header.contains("This is an answer; do not reply unless you need clarification."))
        XCTAssertFalse(reply.deliveries[0].header.contains("pharos reply"))
        XCTAssertEqual(driver.names.last, "codex")
        // --deliver on reply.
        let plain = try relay.send(from: "codex", to: ["claude"], text: "ping2")
        let replied = try relay.reply(plain.deliveries[0].replyID, text: "pong2", deliver: true)
        XCTAssertEqual(replied.deliveries.map(\.state), [.delivered])
        let shown = LightCommands.execute(command: "thread", arguments: ["show", woke.threadID], relay: relay, routesForApp: { _ in [] })
        XCTAssertTrue(shown.text.contains("intent ask"))
        XCTAssertTrue(shown.text.contains("deliver-replies yes"))
        XCTAssertTrue(shown.text.contains("message\tanswer\tclaude -> codex\tpong"))
    }

    func testInformIsDeliveredWithoutAReplyInvitationAndIsNotHarvested() throws {
        let driver = RecordingDriver()
        let relay = try makeRelay(driver: driver)
        try registerTrio(relay)
        let sent = try relay.send(from: "owner", to: ["claude"], cc: ["codex"], text: "build is green", intent: .inform)
        XCTAssertEqual(sent.deliveries.map(\.to), ["claude", "codex"])
        XCTAssertEqual(sent.deliveries.map(\.state), [.delivered, .delivered])
        let fyi = sent.deliveries[0].header
        XCTAssertTrue(fyi.contains("intent=inform"))
        XCTAssertTrue(fyi.contains("This is an FYI; do not reply unless you need clarification."))
        XCTAssertFalse(fyi.contains("pharos reply"))
        XCTAssertTrue(sent.deliveries[1].header.contains(" cc]"))
        XCTAssertTrue(sent.deliveries[1].header.contains("You are copied."))
        driver.reads["claude"] = "Noted."
        XCTAssertEqual(try relay.wait(replyID: sent.deliveries[0].replyID, timeout: 0).status, .pending)
        XCTAssertFalse(try relay.read(thread: sent.threadID).contains { $0.text == "Noted." })
        XCTAssertEqual(try relay.read(thread: sent.threadID).first?.cc, ["codex"])
    }

    func testReplyCCCopiesAndHarvestedRepliesAreNeverCopied() throws {
        let driver = RecordingDriver()
        let relay = try makeRelay(driver: driver)
        try registerTrio(relay)
        let sent = try relay.send(from: "owner", to: ["claude"], text: "status?")
        let copied = try relay.reply(sent.deliveries[0].replyID, text: "fine", cc: ["codex"])
        XCTAssertEqual(copied.deliveries.map(\.to), ["owner", "codex"])
        XCTAssertEqual(copied.deliveries.map(\.state), [.recorded, .delivered])
        XCTAssertTrue(copied.deliveries[1].header.contains("You are copied."))
        XCTAssertThrowsError(try relay.reply(sent.deliveries[0].replyID, text: "x", cc: ["ghost"])) { error in
            XCTAssertEqual(error as? LightRelayError, .unknownMember("ghost"))
        }
        let second = try relay.send(from: "owner", to: ["claude"], text: "again?")
        driver.reads["claude"] = "@codex also fine"
        let waited = try relay.wait(replyID: second.deliveries[0].replyID, timeout: 0)
        XCTAssertEqual(waited.send?.deliveries.map(\.to), ["owner"])
    }

    func testDiscussRunsToTheRoundCapAndRecordsAConclusion() throws {
        let driver = RecordingDriver()
        let relay = try makeRelay(driver: driver)
        try registerTrio(relay)
        let sent = try relay.send(from: "owner", to: ["codex"], text: "tabs or spaces?", intent: .discuss, rounds: 2)
        let opener = try XCTUnwrap(sent.deliveries.first)
        XCTAssertTrue(opener.header.contains("intent=discuss round=1/2"))
        XCTAssertTrue(opener.header.contains("DONE"))
        let first = try relay.reply(opener.replyID, text: "spaces")
        XCTAssertEqual(first.deliveries.map(\.to), ["owner"])
        XCTAssertEqual(first.deliveries.map(\.state), [.delivered])
        XCTAssertTrue(first.deliveries[0].header.contains("round=2/2"))
        XCTAssertNil(first.closed)
        let second = try relay.reply(first.deliveries[0].replyID, text: "agreed, spaces")
        XCTAssertEqual(second.closed, true)
        XCTAssertEqual(second.notice, "Discussion closed: round cap 2 reached.")
        let ask = try XCTUnwrap(second.deliveries.first)
        XCTAssertEqual(ask.to, "owner")
        XCTAssertTrue(ask.header.contains("one-line conclusion"))
        let conclusion = try relay.reply(ask.replyID, text: "Use spaces.")
        XCTAssertTrue(conclusion.deliveries.isEmpty)
        let view = try relay.show(thread: sent.threadID)
        XCTAssertEqual(view.thread.closed, true)
        XCTAssertEqual(view.thread.roundsUsed, 2)
        XCTAssertEqual(view.thread.conclusion, "Use spaces.")
        let shown = LightCommands.execute(command: "thread", arguments: ["show", sent.threadID], relay: relay, routesForApp: { _ in [] })
        XCTAssertTrue(shown.text.contains("intent discuss"))
        XCTAssertTrue(shown.text.contains("rounds 2/2"))
        XCTAssertTrue(shown.text.contains("discussion closed"))
        XCTAssertTrue(shown.text.contains("conclusion Use spaces."))
        // A late reply after close is recorded, not delivered.
        let late = try relay.reply(opener.replyID, text: "one more thing")
        XCTAssertEqual(late.deliveries.map(\.state), [.recorded])
    }

    func testDiscussEndsOnDoneAndStaysWithinTheHopLimit() throws {
        let relay = try makeRelay(driver: RecordingDriver())
        try registerTrio(relay)
        let sent = try relay.send(from: "owner", to: ["codex"], text: "anything?", intent: .discuss)
        XCTAssertTrue(sent.deliveries[0].header.contains("round=1/4"))
        let done = try relay.reply(sent.deliveries[0].replyID, text: "DONE.")
        XCTAssertEqual(done.closed, true)
        XCTAssertEqual(done.notice, "Discussion closed: codex answered DONE.")
        XCTAssertTrue(LightRelay.isDone("done"))
        XCTAssertTrue(LightRelay.isDone("**DONE** nothing new"))
        XCTAssertFalse(LightRelay.isDone("Donezo"))
        XCTAssertFalse(LightRelay.isDone("I am done with the review"))

        let short = try relay.send(from: "owner", to: ["codex"], text: "go", intent: .discuss, rounds: 10, hopLimit: 2)
        let one = try relay.reply(short.deliveries[0].replyID, text: "a")
        let two = try relay.reply(one.deliveries[0].replyID, text: "b")
        XCTAssertTrue(two.stopped)
        XCTAssertEqual(two.closed, true)
    }

    func testCommandsParseIntentCCDeliverAndRounds() throws {
        let relay = try makeRelay(driver: RecordingDriver())
        try registerTrio(relay)
        func run(_ command: String, _ arguments: [String]) -> LightCLIResult {
            LightCommands.execute(command: command, arguments: arguments, relay: relay, routesForApp: { _ in [] })
        }
        XCTAssertEqual(run("send", ["--from", "owner", "--to", "codex", "--intent", "gossip", "--", "x"]).exitCode, 2)
        XCTAssertEqual(run("send", ["--from", "owner", "--to", "codex", "--rounds", "2", "--", "x"]).exitCode, 2)
        let discuss = run("send", ["--from", "owner", "--to", "codex", "--cc", "claude", "--intent", "discuss", "--rounds", "3", "--", "topic"])
        XCTAssertEqual(discuss.exitCode, 0, discuss.text)
        XCTAssertTrue(discuss.text.contains("intent discuss"))
        let lines = discuss.text.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        let replyID = String(lines[1].split(separator: "\t")[2])
        let replied = run("reply", [replyID, "--intent", "inform", "--deliver", "--cc", "claude", "--", "--note"])
        XCTAssertEqual(replied.exitCode, 0, replied.text)
        let threadID = String(lines[0].split(separator: " ")[1])
        XCTAssertTrue(run("thread", ["show", threadID]).text.contains("--note"))
        XCTAssertEqual(LightIntent.parse("FYI"), .inform)
        XCTAssertNil(LightIntent.parse("nope"))
        for word in ["ask", "inform", "answer", "discuss", "--cc", "--deliver", "--rounds", "subagent", "webhook"] {
            XCTAssertTrue(LightCommands.chatHelp.contains(word), word)
        }
    }

    func testOldThreadsAndLogsStillLoad() throws {
        let store = freshStore()
        try FileManager.default.createDirectory(at: store.appendingPathComponent("logs"), withIntermediateDirectories: true)
        let state = #"{"version":3,"members":[{"name":"owner","host":"broker","app":"shell","project":"pharos","sessionID":"o-1","routes":[]},{"name":"codex","host":"broker","app":"codex","project":"pharos","sessionID":"c-1","routes":[]}],"threads":[{"id":"t_oldthread01","originator":"owner","hopLimit":8,"stopped":false,"createdAt":1700000000}],"ledger":[{"replyID":"r_oldreply001","threadID":"t_oldthread01","from":"owner","to":"codex","hop":1,"expiresAt":4000000000,"once":false,"consumed":false,"terminal":false,"issuedAt":1700000000}],"outbox":[]}"#
        try Data(state.utf8).write(to: store.appendingPathComponent("state.json"))
        let line = #"{"id":"m_oldmessage1","kind":"message","threadID":"t_oldthread01","from":"owner","text":"old","mentions":[],"hop":1,"at":1700000000}"#
        try Data((line + "\n").utf8).write(to: store.appendingPathComponent("logs/t_oldthread01.jsonl"))
        let relay = try LightRelay(store: store, driver: RecordingDriver())
        XCTAssertNil(try relay.show(thread: "t_oldthread01").thread.intent)
        let answered = try relay.reply("r_oldreply001", text: "new")
        XCTAssertEqual(answered.deliveries.map(\.state), [.recorded])
    }

    // MARK: Webhook members

    func testTwoWebhookMembersPostToTheirOwnServers() throws {
        let alpha = try FakeHTTPServer()
        let beta = try FakeHTTPServer(status: 202)
        defer { alpha.stop(); beta.stop() }
        let file = freshStore().appendingPathComponent("config/webhooks.json")
        let webhooks = LightWebhookStore(url: file)
        func hook(_ arguments: [String], stdin: String? = nil, env: [String: String] = [:]) -> LightCLIResult {
            LightWebhookCommands.execute(arguments: arguments, store: webhooks, environment: env, readStdin: { stdin })
        }
        XCTAssertEqual(hook(["set", "alpha", "--url", alpha.url, "--secret", "leak"]).exitCode, 2)
        XCTAssertEqual(hook(["set", "alpha", "--url", "http://example.com/hook", "--secret-stdin"], stdin: "s").exitCode, 1)
        XCTAssertEqual(hook(["set", "alpha", "--url", alpha.url + "/hook/path-token"]).exitCode, 1, "a new webhook needs a secret")
        let setAlpha = hook(["set", "alpha", "--url", alpha.url + "/hook/path-token", "--header-name", "X-Alpha-Key", "--secret-stdin"], stdin: "alpha-secret\n")
        XCTAssertEqual(setAlpha.exitCode, 0, setAlpha.text)
        XCTAssertFalse(setAlpha.text.contains("alpha-secret"))
        let secretFile = freshStore()
        try FileManager.default.createDirectory(at: secretFile, withIntermediateDirectories: true)
        try Data("beta-file-secret".utf8).write(to: secretFile.appendingPathComponent("s"))
        XCTAssertEqual(hook(["set", "beta", "--url", beta.url, "--secret-file", secretFile.appendingPathComponent("s").path]).exitCode, 0)
        XCTAssertEqual(hook(["set", "gamma", "--url", beta.url, "--secret-env", "GAMMA_KEY"], env: ["GAMMA_KEY": "g"]).exitCode, 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let listed = hook(["list"])
        XCTAssertTrue(listed.text.contains("alpha\thttp://127.0.0.1:\(alpha.port)\tX-Alpha-Key\t***"), listed.text)
        XCTAssertTrue(listed.text.contains("beta\t"))
        for leaked in ["alpha-secret", "beta-file-secret", "path-token"] {
            XCTAssertFalse(listed.text.contains(leaked))
            XCTAssertFalse(hook(["list", "--json"]).text.contains(leaked))
            XCTAssertFalse(hook(["show", "alpha"]).text.contains(leaked))
        }
        XCTAssertEqual(hook(["remove", "gamma"]).exitCode, 0)
        XCTAssertEqual(hook(["remove", "gamma"]).exitCode, 1)
        XCTAssertFalse(hook(["list"]).text.contains("gamma"))

        let driver = ExternalLightDriver(allowLive: true, webhooks: webhooks)
        let relay = try makeRelay(driver: driver)
        _ = try relay.register(LightMember(name: "owner", host: "broker", app: "shell", project: "pharos", sessionID: "o-1",
                                           routes: [LightRoute.named("native")]))
        func register(_ args: [String]) -> LightCLIResult {
            LightCommands.execute(command: "member", arguments: ["register"] + args, relay: relay,
                                  routesForApp: LightRouteCatalog.defaults(for:))
        }
        XCTAssertEqual(register(["--name", "bot-a", "--app", "webhook", "--webhook", "alpha"]).exitCode, 0)
        XCTAssertEqual(register(["--name", "bot-b", "--app", "webhook", "--webhook", "beta"]).exitCode, 0)
        XCTAssertEqual(relay.member(named: "bot-a")?.routes.map(\.id), ["webhook"])
        let sent = try relay.send(from: "owner", to: ["bot-a"], cc: ["bot-b"], text: "hello bots")
        XCTAssertEqual(sent.deliveries.map(\.state), [.delivered, .delivered])
        XCTAssertEqual(sent.deliveries.map(\.route), ["webhook", "webhook"])
        let a = try XCTUnwrap(alpha.requests.first)
        let b = try XCTUnwrap(beta.requests.first)
        XCTAssertEqual(alpha.requests.count, 1)
        XCTAssertEqual(beta.requests.count, 1)
        XCTAssertEqual(a.path, "/hook/path-token")
        XCTAssertEqual(a.headers["x-alpha-key"], "alpha-secret")
        XCTAssertEqual(b.headers["x-pharos-secret"], "beta-file-secret")
        XCTAssertNil(b.headers["x-alpha-key"])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: a.body) as? [String: Any])
        XCTAssertEqual(payload["replyId"] as? String, sent.deliveries[0].replyID)
        XCTAssertEqual(payload["threadId"] as? String, sent.threadID)
        XCTAssertEqual(payload["from"] as? String, "owner")
        XCTAssertEqual(payload["to"] as? String, "bot-a")
        XCTAssertEqual(payload["cc"] as? [String], ["bot-b"])
        XCTAssertEqual(payload["intent"] as? String, "ask")
        XCTAssertEqual(payload["text"] as? String, "hello bots")
        XCTAssertEqual(payload["hop"] as? Int, 1)
        XCTAssertEqual(payload["expectsReply"] as? Bool, true)
        XCTAssertEqual(payload["replyCommand"] as? String, "pharos reply \(sent.deliveries[0].replyID) -- \"...\"")
        let bPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: b.body) as? [String: Any])
        XCTAssertEqual(bPayload["to"] as? String, "bot-b")
        XCTAssertEqual(bPayload["expectsReply"] as? Bool, false)
        // No harvest: the bot answers with `pharos reply`.
        XCTAssertEqual(try relay.wait(replyID: sent.deliveries[0].replyID, timeout: 0).status, .pending)
        let answered = try relay.reply(sent.deliveries[0].replyID, text: "hi owner")
        XCTAssertEqual(answered.deliveries.map(\.to), ["owner"])
        XCTAssertEqual(alpha.requests.count, 1)

        // An unconfigured webhook fails without posting anywhere; no live flag means no POST.
        _ = try relay.register(LightMember(name: "bot-c", host: "webhook", app: "webhook", project: "webhook",
                                           sessionID: "missing", routes: LightRouteCatalog.webhook))
        XCTAssertEqual(try relay.send(from: "owner", to: ["bot-c"], text: "x").deliveries.map(\.state), [.failed])
        let offline = ExternalLightDriver(allowLive: false, webhooks: webhooks)
        let member = try XCTUnwrap(relay.member(named: "bot-a"))
        XCTAssertEqual(offline.deliver(member: member, body: "x").state, .deferred)
        XCTAssertEqual(alpha.requests.count, 1)
    }

    // MARK: Helpers

    private func registerTrio(_ relay: LightRelay) throws {
        for (name, app) in [("owner", "shell"), ("codex", "codex"), ("claude", "claude")] {
            _ = try relay.register(LightMember(name: name, host: "broker", app: app, project: "pharos",
                                               sessionID: "\(name)-1", routes: [LightRoute.named("native")]))
        }
    }

    private func makeRelay(driver: any LightSessionDriver) throws -> LightRelay {
        try LightRelay(store: freshStore(), driver: driver)
    }

    private func freshStore() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pharos-intent-\(UUID().uuidString)", isDirectory: true)
        stores.append(url)
        return url
    }
}

private final class RecordingDriver: LightSessionDriver, @unchecked Sendable {
    var names: [String] = []
    var bodies: [String] = []
    var reads: [String: String] = [:]

    func deliver(member: LightMember, body: String) -> LightDriveResult {
        names.append(member.name)
        bodies.append(body)
        return LightDriveResult(state: .delivered, route: "native", fallback: false, liveVerified: true, detail: "fake")
    }

    func readReply(member: LightMember, since: Date) -> String? {
        reads.removeValue(forKey: member.name)
    }
}

/// Minimal HTTP/1.1 server on 127.0.0.1 for webhook tests. One request per connection.
final class FakeHTTPServer: @unchecked Sendable {
    struct Request {
        var path: String
        var headers: [String: String]
        var body: Data
    }

    let port: UInt16
    var url: String { "http://127.0.0.1:\(port)" }
    private let socketFD: Int32
    private let status: Int
    private let lock = NSLock()
    private var received: [Request] = []
    private var running = true

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    init(status: Int = 200) throws {
        self.status = status
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "fake-http", code: 1) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw NSError(domain: "fake-http", code: 2) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: actual.sin_port)
        socketFD = fd
        let thread = Thread { [weak self] in self?.serve() }
        thread.start()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        shutdown(socketFD, SHUT_RDWR)
        close(socketFD)
    }

    private func serve() {
        while true {
            let client = accept(socketFD, nil, nil)
            if client < 0 { return }
            handle(client)
            close(client)
            lock.lock(); let keep = running; lock.unlock()
            if !keep { return }
        }
    }

    private func handle(_ client: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Range<Data.Index>?
        var contentLength = 0
        while true {
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { break }
            data.append(buffer, count: count)
            if headerEnd == nil, let range = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range
                let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                    contentLength = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            if let headerEnd, data.count - headerEnd.upperBound >= contentLength { break }
        }
        guard let headerEnd else { return }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.split(separator: "\r\n").map(String.init)
        let requestLine = lines.isEmpty ? "" : lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = Data(data[headerEnd.upperBound...].prefix(contentLength))
        lock.lock()
        received.append(Request(path: parts.count > 1 ? String(parts[1]) : "", headers: headers, body: body))
        lock.unlock()
        let response = "HTTP/1.1 \(status) OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        _ = response.withCString { send(client, $0, strlen($0), 0) }
    }
}
