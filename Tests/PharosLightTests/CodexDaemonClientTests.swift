import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import PharosRuntime

private final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool

    init(_ value: Bool) {
        self._value = value
    }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
}

final class FakeCodexDaemonServer: @unchecked Sendable {
    let path: String
    private var serverFd: Int32 = -1
    private var clientFd: Int32 = -1
    private let isRunning = AtomicBool(true)
    private let lock = NSLock()
    private var _receivedPayloads: [String] = []
    var threadStatus: [String: Any]?
    var customHandler: ((_ method: String, _ params: [String: Any]?, _ reqId: Int?) -> [String: Any]?)? = nil

    var receivedPayloads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedPayloads
    }

    init(path: String) {
        self.path = path
    }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CodexDaemonError.unavailable("failed to create server socket")
        }

        #if canImport(Darwin)
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var tv = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = path.withCString { strncpy(ptr, $0, maxLen - 1) }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.bind(fd, $0, len)
                #else
                Glibc.bind(fd, $0, len)
                #endif
            }
        }
        guard bindRes == 0 else {
            #if canImport(Darwin)
            Darwin.close(fd)
            #else
            Glibc.close(fd)
            #endif
            throw CodexDaemonError.unavailable("server bind failed")
        }

        #if canImport(Darwin)
        guard Darwin.listen(fd, 5) == 0 else {
            Darwin.close(fd)
            throw CodexDaemonError.unavailable("server listen failed")
        }
        #else
        guard Glibc.listen(fd, 5) == 0 else {
            Glibc.close(fd)
            throw CodexDaemonError.unavailable("server listen failed")
        }
        #endif

        self.serverFd = fd

        Thread.detachNewThread { [weak self] in
            self?.runServer()
        }
    }

    func pushFrame(_ json: [String: Any]) {
        lock.lock()
        let cFd = self.clientFd
        lock.unlock()
        guard cFd >= 0 else { return }
        if let d = try? JSONSerialization.data(withJSONObject: json) {
            let frame = WebSocketFrame.encode(opcode: 0x1, payload: d, fin: true, masked: false)
            _ = frame.withUnsafeBytes {
                #if canImport(Darwin)
                Darwin.send(cFd, $0.baseAddress!, frame.count, 0)
                #else
                Glibc.send(cFd, $0.baseAddress!, frame.count, Int32(MSG_NOSIGNAL))
                #endif
            }
        }
    }

    func closeClient() {
        lock.lock()
        let cFd = self.clientFd
        self.clientFd = -1
        lock.unlock()
        if cFd >= 0 {
            #if canImport(Darwin)
            Darwin.close(cFd)
            #else
            Glibc.close(cFd)
            #endif
        }
    }

    private func runServer() {
        while isRunning.value {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let cFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    #if canImport(Darwin)
                    Darwin.accept(serverFd, $0, &clientLen)
                    #else
                    Glibc.accept(serverFd, $0, &clientLen)
                    #endif
                }
            }
            guard cFd >= 0 else {
                if !isRunning.value { break }
                continue
            }
            lock.lock()
            self.clientFd = cFd
            lock.unlock()

            var tv = timeval(tv_sec: 4, tv_usec: 0)
            setsockopt(cFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(cFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            // Read HTTP Upgrade
            var headerBuf = Data()
            var buf = [UInt8](repeating: 0, count: 1024)
            var upgradeSuccess = false
            while isRunning.value {
                #if canImport(Darwin)
                let n = Darwin.read(cFd, &buf, buf.count)
                #else
                let n = Glibc.read(cFd, &buf, buf.count)
                #endif
                if n <= 0 { break }
                headerBuf.append(buf, count: n)
                if headerBuf.range(of: Data("\r\n\r\n".utf8)) != nil {
                    upgradeSuccess = true
                    break
                }
            }

            if !upgradeSuccess {
                #if canImport(Darwin)
                Darwin.close(cFd)
                #else
                Glibc.close(cFd)
                #endif
                lock.lock()
                if self.clientFd == cFd { self.clientFd = -1 }
                lock.unlock()
                continue
            }

            // Reply HTTP 101 Switching Protocols
            let resp101 = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
            _ = resp101.utf8CString.withUnsafeBufferPointer {
                #if canImport(Darwin)
                Darwin.send(cFd, $0.baseAddress!, resp101.utf8.count, 0)
                #else
                Glibc.send(cFd, $0.baseAddress!, resp101.utf8.count, Int32(MSG_NOSIGNAL))
                #endif
            }

            // Frame receive loop
            var inBuffer = Data()
            while isRunning.value {
                if let frame = WebSocketFrame.decode(inBuffer) {
                    inBuffer.removeSubrange(0..<frame.consumed)
                    if frame.opcode == 0x1 {
                        if let text = String(data: frame.payload, encoding: .utf8) {
                            lock.lock()
                            _receivedPayloads.append(text)
                            lock.unlock()
                            handleClientMessage(text, clientFd: cFd)
                        }
                    } else if frame.opcode == 0x8 {
                        break
                    }
                    continue
                }

                var pfd = pollfd(fd: cFd, events: Int16(POLLIN), revents: 0)
                let pollRet = poll(&pfd, 1, 200)
                if pollRet <= 0 {
                    if !isRunning.value { break }
                    lock.lock()
                    let stillOurClient = (self.clientFd == cFd)
                    lock.unlock()
                    if !stillOurClient { break }
                    continue
                }

                #if canImport(Darwin)
                let n = Darwin.read(cFd, &buf, buf.count)
                #else
                let n = Glibc.read(cFd, &buf, buf.count)
                #endif
                if n <= 0 { break }
                inBuffer.append(buf, count: n)
            }

            lock.lock()
            if self.clientFd == cFd {
                #if canImport(Darwin)
                Darwin.close(cFd)
                #else
                Glibc.close(cFd)
                #endif
                self.clientFd = -1
            }
            lock.unlock()
        }
    }

    private func handleClientMessage(_ text: String, clientFd: Int32) {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        let reqId = obj["id"] as? Int
        let method = obj["method"] as? String ?? ""

        func sendFrame(_ json: [String: Any]) {
            if let d = try? JSONSerialization.data(withJSONObject: json) {
                let frame = WebSocketFrame.encode(opcode: 0x1, payload: d, fin: true, masked: false)
                _ = frame.withUnsafeBytes {
                    #if canImport(Darwin)
                    Darwin.send(clientFd, $0.baseAddress!, frame.count, 0)
                    #else
                    Glibc.send(clientFd, $0.baseAddress!, frame.count, Int32(MSG_NOSIGNAL))
                    #endif
                }
            }
        }

        if let customHandler, let customResp = customHandler(method, obj["params"] as? [String: Any], reqId) {
            sendFrame(customResp)
            return
        }

        switch method {
        case "initialize":
            sendFrame(["id": 0, "result": ["serverInfo": ["name": "codex-test", "version": "0.1"]]])
        case "initialized":
            break
        case "thread/loaded/list":
            sendFrame(["id": reqId ?? 1, "result": ["data": ["01a1a81b-test"], "nextCursor": nil as Any? as Any]])
        case "thread/read":
            // Notification before response
            sendFrame(["method": "thread/status/changed", "params": ["threadId": "01a1a81b-test"]])
            // Server request before response (approvals that client MUST NOT answer)
            sendFrame([
                "id": "srv-1",
                "method": "item/commandExecution/requestApproval",
                "params": [
                    "threadId": "01a1a81b-test",
                    "reason": "write file",
                    "command": "touch x"
                ]
            ])
            let statusObj = threadStatus ?? [
                "type": "active",
                "activeFlags": ["waitingOnApproval"]
            ]
            // Response
            sendFrame([
                "id": reqId ?? 1,
                "result": [
                    "thread": [
                        "id": "01a1a81b-test",
                        "cwd": "/Users/x/dir",
                        "path": "/Users/x/.codex/sessions/rollout.jsonl",
                        "originator": "codex-tui",
                        "status": statusObj
                    ]
                ]
            ])
        case "thread/queue/add":
            let params = obj["params"] as? [String: Any]
            let cid = params?["clientUserMessageId"] as? String ?? "r-1"
            sendFrame([
                "id": reqId ?? 1,
                "result": [
                    "queuedSubmission": [
                        "id": "sub-123",
                        "clientUserMessageId": cid
                    ]
                ]
            ])
        case "thread/turns/list":
            sendFrame([
                "id": reqId ?? 1,
                "result": [
                    "data": [
                        [
                            "id": "turn-1",
                            "status": "completed",
                            "startedAt": 1793821748,
                            "completedAt": 1793821751,
                            "items": [
                                [
                                    "type": "userMessage",
                                    "clientId": "r-test-1",
                                    "content": [["type": "text", "text": "ping"]]
                                ],
                                [
                                    "type": "agentMessage",
                                    "text": "PONG-1",
                                    "phase": "final_answer"
                                ]
                            ]
                        ]
                    ],
                    "nextCursor": nil as Any? as Any
                ]
            ])
        case "error/test":
            sendFrame([
                "id": reqId ?? 1,
                "error": [
                    "code": -32600,
                    "message": "canned rpc error"
                ]
            ])
        default:
            break
        }
    }

    func stop() {
        isRunning.value = false
        if clientFd >= 0 {
            #if canImport(Darwin)
            Darwin.close(clientFd)
            #else
            Glibc.close(clientFd)
            #endif
            clientFd = -1
        }
        if serverFd >= 0 {
            #if canImport(Darwin)
            Darwin.close(serverFd)
            #else
            Glibc.close(serverFd)
            #endif
            serverFd = -1
        }
        unlink(path)
    }
}

final class CodexDaemonClientTests: XCTestCase {
    private var socketsToClean: [String] = []

    override func tearDown() {
        for s in socketsToClean {
            unlink(s)
        }
        socketsToClean.removeAll()
        super.tearDown()
    }

    func testWebSocketFrameEncodeDecodeRoundTrip() {
        // 1. Length < 126, masked
        let smallPayload = Data("hello websocket".utf8)
        let frameSmallMasked = WebSocketFrame.encode(opcode: 0x1, payload: smallPayload, fin: true, masked: true)
        let decodedSmallMasked = WebSocketFrame.decode(frameSmallMasked)
        XCTAssertNotNil(decodedSmallMasked)
        XCTAssertEqual(decodedSmallMasked?.fin, true)
        XCTAssertEqual(decodedSmallMasked?.opcode, 0x1)
        XCTAssertEqual(decodedSmallMasked?.payload, smallPayload)
        XCTAssertEqual(decodedSmallMasked?.consumed, frameSmallMasked.count)

        // 2. Length 126..65535 (16-bit length), unmasked
        let mediumPayload = Data((0..<500).map { UInt8($0 % 256) })
        let frameMed = WebSocketFrame.encode(opcode: 0x2, payload: mediumPayload, fin: true, masked: false)
        let decodedMed = WebSocketFrame.decode(frameMed)
        XCTAssertNotNil(decodedMed)
        XCTAssertEqual(decodedMed?.fin, true)
        XCTAssertEqual(decodedMed?.opcode, 0x2)
        XCTAssertEqual(decodedMed?.payload, mediumPayload)
        XCTAssertEqual(decodedMed?.consumed, frameMed.count)

        // 3. Length > 65535 (64-bit length), masked
        let largePayload = Data(repeating: 0x42, count: 70_000)
        let frameLarge = WebSocketFrame.encode(opcode: 0x1, payload: largePayload, fin: true, masked: true)
        let decodedLarge = WebSocketFrame.decode(frameLarge)
        XCTAssertNotNil(decodedLarge)
        XCTAssertEqual(decodedLarge?.fin, true)
        XCTAssertEqual(decodedLarge?.opcode, 0x1)
        XCTAssertEqual(decodedLarge?.payload, largePayload)
        XCTAssertEqual(decodedLarge?.consumed, frameLarge.count)

        // 4. Ping and Pong control frames
        let pingPayload = Data("ping-data".utf8)
        let pingFrame = WebSocketFrame.encode(opcode: 0x9, payload: pingPayload, fin: true, masked: false)
        let decodedPing = WebSocketFrame.decode(pingFrame)
        XCTAssertEqual(decodedPing?.opcode, 0x9)
        XCTAssertEqual(decodedPing?.payload, pingPayload)
    }

    func testMissingSocketReturnsUnavailable() {
        let path = "/tmp/pcx-nonexistent-\(UUID().uuidString.prefix(6)).sock"
        let client = CodexDaemonClient(socketPath: path, timeout: 1)
        XCTAssertThrowsError(try client.connect()) { error in
            guard case CodexDaemonError.unavailable = error else {
                XCTFail("Expected .unavailable but got \(error)")
                return
            }
        }
    }

    func testFakeDaemonHandshakeAndCalls() throws {
        let sockPath = "/tmp/pcx-\(UUID().uuidString.prefix(8)).sock"
        socketsToClean.append(sockPath)

        let server = FakeCodexDaemonServer(path: sockPath)
        try server.start()
        defer { server.stop() }

        // Give the background thread time to bind
        Thread.sleep(forTimeInterval: 0.05)

        let client = CodexDaemonClient(socketPath: sockPath, timeout: 3)
        defer { client.close() }

        try client.connect()

        // 1. loadedThreads
        let threads = try client.loadedThreads()
        XCTAssertEqual(threads, ["01a1a81b-test"])

        // 2. readThread
        let info = try client.readThread("01a1a81b-test")
        XCTAssertEqual(info.id, "01a1a81b-test")
        XCTAssertEqual(info.cwd, "/Users/x/dir")
        XCTAssertEqual(info.originator, "codex-tui")
        XCTAssertEqual(info.status, .active(flags: ["waitingOnApproval"]))
        XCTAssertTrue(info.status.needsHuman)
        XCTAssertTrue(info.status.busy)

        // Assert server request was recorded
        let requests = client.observedServerRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].id, "srv-1")
        XCTAssertEqual(requests[0].method, "item/commandExecution/requestApproval")
        XCTAssertEqual(requests[0].summary, "touch x")

        // Assert notification was recorded
        let notifications = client.notifications
        XCTAssertTrue(notifications.contains(where: { ($0["method"] as? String) == "thread/status/changed" }))

        // Assert client NEVER sent any frame containing "srv-1"
        for payload in server.receivedPayloads {
            XCTAssertFalse(payload.contains("srv-1"), "Client must never answer server approvals!")
        }

        // 3. queueAdd
        let subId = try client.queueAdd(thread: "01a1a81b-test", text: "ping", clientID: "r-test-1")
        XCTAssertEqual(subId, "sub-123")

        // 4. turns
        let turns = try client.turns(thread: "01a1a81b-test")
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].id, "turn-1")
        XCTAssertEqual(turns[0].status, "completed")
        XCTAssertEqual(turns[0].clientIDs, ["r-test-1"])
        XCTAssertEqual(turns[0].finalAnswer, "PONG-1")
        XCTAssertEqual(turns[0].startedAt, Date(timeIntervalSince1970: 1793821748))
        XCTAssertEqual(turns[0].completedAt, Date(timeIntervalSince1970: 1793821751))

        // 5. RPC error
        XCTAssertThrowsError(try client.call("error/test", [:])) { error in
            guard case CodexDaemonError.rpc(let code, let msg) = error else {
                XCTFail("Expected .rpc error, got \(error)")
                return
            }
            XCTAssertEqual(code, -32600)
            XCTAssertEqual(msg, "canned rpc error")
        }
    }

    func testReplyInTurns() {
        let t1 = Date(timeIntervalSince1970: 1_793_821_748)
        let t2 = Date(timeIntervalSince1970: 1_793_821_800)

        let turns = [
            CodexTurn(
                id: "turn-1",
                status: "completed",
                startedAt: t1,
                completedAt: t1.addingTimeInterval(3),
                clientIDs: ["r-first"],
                finalAnswer: "PONG-1"
            ),
            CodexTurn(
                id: "turn-2",
                status: "completed",
                startedAt: t2,
                completedAt: t2.addingTimeInterval(3),
                clientIDs: ["r-second"],
                finalAnswer: "PONG-2"
            ),
            CodexTurn(
                id: "turn-3",
                status: "failed",
                startedAt: t2.addingTimeInterval(10),
                clientIDs: ["r-failed"],
                finalAnswer: nil,
                errorMessage: "failed"
            )
        ]

        // Reply by clientID
        XCTAssertEqual(CodexDaemonClient.reply(in: turns, clientID: "r-first", since: nil), "PONG-1")
        XCTAssertEqual(CodexDaemonClient.reply(in: turns, clientID: "r-second", since: nil), "PONG-2")
        // Failed turn returns nil
        XCTAssertNil(CodexDaemonClient.reply(in: turns, clientID: "r-failed", since: nil))

        // Reply by since (with 2s skew)
        let since1 = t1.addingTimeInterval(1.0) // t1 >= since1 - 2s
        XCTAssertEqual(CodexDaemonClient.reply(in: turns, clientID: nil, since: since1), "PONG-1")

        let since2 = t2.addingTimeInterval(1.0)
        XCTAssertEqual(CodexDaemonClient.reply(in: turns, clientID: nil, since: since2), "PONG-2")
    }

    func testIsQuota() {
        XCTAssertTrue(CodexDaemonClient.isQuota("usageLimitExceeded"))
        XCTAssertTrue(CodexDaemonClient.isQuota("rateLimitExceeded"))
        XCTAssertTrue(CodexDaemonClient.isQuota("quota exceeded"))
        XCTAssertTrue(CodexDaemonClient.isQuota("429 Too Many Requests"))
        XCTAssertFalse(CodexDaemonClient.isQuota("internalServerError"))
        XCTAssertFalse(CodexDaemonClient.isQuota(nil))
    }

    func testSocketPath() {
        let envCustom = ["CODEX_HOME": "/custom/codex"]
        XCTAssertEqual(
            CodexDaemonClient.socketPath(env: envCustom),
            "/custom/codex/app-server-control/app-server-control.sock"
        )

        let defaultPath = CodexDaemonClient.socketPath(env: [:])
        XCTAssertTrue(defaultPath.hasSuffix(".codex/app-server-control/app-server-control.sock"))
    }
}
