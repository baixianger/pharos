import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import PharosMeshCore
@testable import PharosRuntime

final class LightInventoryTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-inv-test-\(UUID().uuidString)")
            .appendingPathComponent(name)
        tempDirs.append(dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 1. Codex Daemon List Mapping

    func testCodexDaemonListMapping() throws {
        let tempDir = makeTempDir("daemon-test")
        let sockPath = "/tmp/phinv-\(UUID().uuidString.prefix(8)).sock"
        unlink(sockPath)
        defer { unlink(sockPath) }

        let server = FakeCodexDaemonServer(path: sockPath)
        try server.start()
        defer { server.stop() }

        var requestedParams: [[String: Any]] = []
        server.customHandler = { method, params, reqId in
            guard method == "thread/list" else { return nil }
            if let params {
                requestedParams.append(params)
            }
            let cursor = params?["cursor"] as? String

            if cursor == nil || cursor?.isEmpty == true {
                // Page 1
                return [
                    "id": reqId ?? 1,
                    "result": [
                        "threads": [
                            [
                                "id": "t1",
                                "name": "Feature Alpha",
                                "preview": "secret prompt Alpha",
                                "cwd": "/tmp/p1",
                                "updatedAt": 1700000000,
                                "status": ["type": "waitingOnApproval"],
                                "source": "cli"
                            ],
                            [
                                "id": "t-eph",
                                "name": "Ephemeral Task",
                                "ephemeral": true,
                                "cwd": "/tmp/peph",
                                "updatedAt": 1700000010,
                                "status": ["type": "active"]
                            ]
                        ],
                        "nextCursor": "cur-2"
                    ]
                ]
            } else if cursor == "cur-2" {
                // Page 2
                return [
                    "id": reqId ?? 1,
                    "result": [
                        "threads": [
                            [
                                "id": "t2",
                                "name": "Feature Beta",
                                "preview": "secret prompt Beta",
                                "cwd": "/tmp/p2",
                                "updatedAt": 1700000050,
                                "status": ["type": "active"]
                            ],
                            [
                                "id": "t3",
                                "name": "Feature Gamma",
                                "preview": "secret prompt Gamma",
                                "cwd": "/tmp/p3",
                                "updatedAt": 1700000100,
                                "status": ["type": "idle"]
                            ],
                            [
                                "id": "t4",
                                "name": "Feature Delta",
                                "preview": "secret prompt Delta",
                                "cwd": "/tmp/p4",
                                "updatedAt": 1700000020,
                                "status": ["type": "UserInput"]
                            ]
                        ],
                        "nextCursor": nil as Any? as Any
                    ]
                ]
            }
            return nil
        }

        // Allow server socket thread to start listening
        usleep(50_000)

        let client = CodexDaemonClient(socketPath: sockPath, timeout: 5)
        let collector = SessionInventoryCollector(
            codexDaemon: { client },
            agyBin: "/nonexistent",
            cursorChatsDir: tempDir.appendingPathComponent("nonexistent-cursor")
        )

        let inventory = collector.collect(node: "mini")
        let codexSessions = inventory.sessions.filter { $0.app == "codex" }

        // Verify request parameters sent
        XCTAssertGreaterThanOrEqual(requestedParams.count, 2)
        XCTAssertEqual(requestedParams[0]["limit"] as? Int, 100)
        XCTAssertEqual(requestedParams[0]["archived"] as? Bool, false)

        // Ephemeral thread t-eph must be skipped!
        XCTAssertEqual(codexSessions.count, 4)
        XCTAssertFalse(codexSessions.contains(where: { $0.id == "t-eph" }))

        // Preview MUST NOT be used for title!
        let t1 = codexSessions.first(where: { $0.id == "t1" })
        XCTAssertEqual(t1?.title, "Feature Alpha")
        XCTAssertNotEqual(t1?.title, "secret prompt Alpha")
        XCTAssertEqual(t1?.state, "needs_human")
        XCTAssertEqual(t1?.cwd, "/tmp/p1")
        XCTAssertEqual(t1?.project, "p1")

        let t2 = codexSessions.first(where: { $0.id == "t2" })
        XCTAssertEqual(t2?.title, "Feature Beta")
        XCTAssertEqual(t2?.state, "active")

        let t3 = codexSessions.first(where: { $0.id == "t3" })
        XCTAssertEqual(t3?.title, "Feature Gamma")
        XCTAssertEqual(t3?.state, "idle")

        let t4 = codexSessions.first(where: { $0.id == "t4" })
        XCTAssertEqual(t4?.title, "Feature Delta")
        XCTAssertEqual(t4?.state, "needs_human")

        // Sorted by lastActive desc: t3 (1700000100), t2 (1700000050), t4 (1700000020), t1 (1700000000)
        XCTAssertEqual(codexSessions.map(\.id), ["t3", "t2", "t4", "t1"])
    }

    // MARK: - 2. Codex Rollout Fallback

    func testCodexRolloutFallback() throws {
        let tempDir = makeTempDir("rollout-test")
        let sessionsDir = tempDir.appendingPathComponent("sessions/2026/11/04", isDirectory: true)
        let archivedDir = tempDir.appendingPathComponent("archived_sessions/2026/11/04", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedDir, withIntermediateDirectories: true)

        // 1. Good rollout file
        let goodFile = sessionsDir.appendingPathComponent("rollout-20261104-100000-sess-good.jsonl")
        let goodContent = """
        {"timestamp":"2026-11-04T10:00:00Z","type":"session_meta","payload":{"id":"sess-good","cwd":"/Users/pai/myrepo","source":"cli"}}
        {"timestamp":"2026-11-04T10:01:00Z","type":"event_msg","payload":{"type":"user_message","message":"Secret user message"}}
        """
        try goodContent.write(to: goodFile, atomically: true, encoding: .utf8)

        // 2. Exec rollout file (should be skipped)
        let execFile = sessionsDir.appendingPathComponent("rollout-20261104-090000-sess-exec.jsonl")
        let execContent = """
        {"timestamp":"2026-11-04T09:00:00Z","type":"session_meta","payload":{"id":"sess-exec","cwd":"/Users/pai/myrepo","source":"exec"}}
        """
        try execContent.write(to: execFile, atomically: true, encoding: .utf8)

        // 3. Archived rollout file (should be ignored)
        let archFile = archivedDir.appendingPathComponent("rollout-20261104-080000-sess-arch.jsonl")
        let archContent = """
        {"timestamp":"2026-11-04T08:00:00Z","type":"session_meta","payload":{"id":"sess-arch","cwd":"/Users/pai/myrepo","source":"cli"}}
        """
        try archContent.write(to: archFile, atomically: true, encoding: .utf8)

        // 4. session_index.jsonl with thread_name
        let indexFile = tempDir.appendingPathComponent("session_index.jsonl")
        let indexContent = """
        {"id":"sess-good","thread_name":"Rollout Project Work"}
        {"id":"sess-other","thread_name":"Other"}
        """
        try indexContent.write(to: indexFile, atomically: true, encoding: .utf8)

        let collector = SessionInventoryCollector(
            codexDaemon: { nil }, // No daemon
            codexRolloutRoot: tempDir,
            codexSessionIndexURL: indexFile,
            agyBin: "/nonexistent",
            cursorChatsDir: tempDir.appendingPathComponent("nonexistent-cursor")
        )

        let inventory = collector.collect(node: "mini")
        let codexSessions = inventory.sessions.filter { $0.app == "codex" }

        XCTAssertEqual(codexSessions.count, 1)
        let s = codexSessions[0]
        XCTAssertEqual(s.id, "sess-good")
        XCTAssertEqual(s.title, "Rollout Project Work") // Resolved from session_index.jsonl
        XCTAssertEqual(s.cwd, "/Users/pai/myrepo")
        XCTAssertEqual(s.project, "myrepo")
        XCTAssertEqual(s.state, "notLoaded")
        XCTAssertEqual(s.source, "cli")

        XCTAssertTrue(inventory.notes.contains("codex: daemon not running, read rollouts"))
    }

    // MARK: - 3. Agy Metadata Fallback

    func testAgyMetadataFallback() throws {
        let tempDir = makeTempDir("agy-fallback")
        let convDir = tempDir.appendingPathComponent("conversations", isDirectory: true)
        let cacheDir = tempDir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // DB files (empty files just to exist)
        try Data().write(to: convDir.appendingPathComponent("s1.db"))
        try Data().write(to: convDir.appendingPathComponent("s2.db"))
        try Data().write(to: convDir.appendingPathComponent("s3-archived.db"))
        try Data().write(to: convDir.appendingPathComponent("s4-hidden.db"))
        try Data().write(to: convDir.appendingPathComponent("s5-internal.db"))

        // cache/conversation_metadata.json
        let metadataURL = cacheDir.appendingPathComponent("conversation_metadata.json")
        let metadataObj: [String: Any] = [
            "conversations": [
                "s1": [
                    "summary": [
                        "Title": "Agy Project One",
                        "Preview": "Secret preview content that should never appear in title"
                    ],
                    "is_internal": false,
                    "last_modified_time": 1700000100
                ],
                "s2": [
                    "summary": [
                        "Title": "Agy Project Two",
                        "Preview": "Another secret preview"
                    ],
                    "is_internal": false,
                    "last_modified_time": 1700000200
                ],
                "s3-archived": [
                    "summary": ["Title": "Archived Conversation"],
                    "archived": true
                ],
                "s4-hidden": [
                    "summary": ["Title": "Hidden Conversation"],
                    "hidden": true
                ],
                "s5-internal": [
                    "summary": ["Title": "Internal System Conversation"],
                    "is_internal": true
                ]
            ]
        ]
        let metaData = try JSONSerialization.data(withJSONObject: metadataObj)
        try metaData.write(to: metadataURL)

        // cache/last_conversations.json (testing both dir -> id and id -> dir mappings)
        let lastConvURL = cacheDir.appendingPathComponent("last_conversations.json")
        let lastConvObj: [String: String] = [
            "/Users/pai/first-project": "s1",
            "s2": "/Users/pai/second-project"
        ]
        let lastData = try JSONSerialization.data(withJSONObject: lastConvObj)
        try lastData.write(to: lastConvURL)

        let collector = SessionInventoryCollector(
            codexDaemon: { nil },
            codexRolloutRoot: tempDir.appendingPathComponent("nonexistent-codex"),
            agyBin: "/nonexistent", // forces fallback
            agyAppDataDir: tempDir,
            cursorChatsDir: tempDir.appendingPathComponent("nonexistent-cursor")
        )

        let inventory = collector.collect(node: "mini")
        let agySessions = inventory.sessions.filter { $0.app == "agy" }

        // Only s1 and s2 should be collected (s3, s4, s5 skipped)
        XCTAssertEqual(agySessions.count, 2)

        let s1 = agySessions.first(where: { $0.id == "s1" })
        XCTAssertEqual(s1?.title, "Agy Project One")
        XCTAssertNotEqual(s1?.title, "Secret preview content that should never appear in title")
        XCTAssertEqual(s1?.cwd, "/Users/pai/first-project")
        XCTAssertEqual(s1?.project, "first-project")
        XCTAssertEqual(s1?.state, "unknown")
        XCTAssertEqual(s1?.source, "cli")

        let s2 = agySessions.first(where: { $0.id == "s2" })
        XCTAssertEqual(s2?.title, "Agy Project Two")
        XCTAssertEqual(s2?.cwd, "/Users/pai/second-project")
        XCTAssertEqual(s2?.project, "second-project")

        // Sorted by lastActive desc: s2 (1700000200) then s1 (1700000100)
        XCTAssertEqual(agySessions.map(\.id), ["s2", "s1"])
        XCTAssertTrue(inventory.notes.contains("agy: acp failed, read metadata cache"))
    }

    // MARK: - 4. ACP Session List Parse

    func testACPSessionListParse() throws {
        let tempDir = makeTempDir("acp-test")
        let fakeAgyScript = tempDir.appendingPathComponent("fake-agy")

        // Create a shell script simulating agy acp stdio JSON-RPC
        let scriptContent = """
        #!/bin/sh
        while IFS= read -r line; do
            case "$line" in
                *initialize*)
                    echo '{"id":1,"result":{"protocolVersion":1}}'
                    ;;
                *session*list*|*session*)
                    echo '{"id":2,"result":{"sessions":[{"sessionId":"acp-sess-42","cwd":"/Users/pai/personal/%E8%BF%BD%E6%80%9D","title":"Memory Trace","updatedAt":"2026-11-04T12:00:00Z"}]}}'
                    ;;
            esac
        done
        """
        try scriptContent.write(to: fakeAgyScript, atomically: true, encoding: .utf8)
        chmod(fakeAgyScript.path, S_IRWXU)

        let entries = try SessionInventoryCollector.queryACP(bin: fakeAgyScript.path, timeout: 5)
        XCTAssertEqual(entries.count, 1)

        let entry = entries[0]
        XCTAssertEqual(entry.app, "agy")
        XCTAssertEqual(entry.id, "acp-sess-42")
        // Percent-decoding check
        XCTAssertEqual(entry.cwd, "/Users/pai/personal/追思")
        XCTAssertEqual(entry.project, "追思")
        XCTAssertEqual(entry.title, "Memory Trace")
        XCTAssertNotNil(entry.lastActive)
        XCTAssertEqual(entry.state, "unknown")
        XCTAssertEqual(entry.source, "cli")
    }

    // MARK: - 5. Workspace Derivation

    func testWorkspaceDerivation() throws {
        let tempDir = makeTempDir("workspace-test")
        let invStore = LightInventoryStore(rootDir: tempDir)
        let wsStore = LightWorkspaceStore(rootDir: tempDir)

        let sessions = [
            LightSessionEntry(app: "codex", id: "s1", cwd: "/Users/pai/projects/my-web"),
            LightSessionEntry(app: "agy", id: "s2", cwd: "/Users/pai/projects/my-web"),
            LightSessionEntry(app: "codex", id: "s3", cwd: "/Users/pai/projects/My.App!Test"),
            LightSessionEntry(app: "cursor", id: "s4", cwd: "/other/disk/my-web"), // Collision with my-web!
            LightSessionEntry(app: "codex", id: "s5", cwd: "/third/disk/my-web")   // Second collision!
        ]
        let inv = LightNodeInventory(node: "host1", at: Date(), sessions: sessions, notes: [])
        try invStore.save(node: "host1", inventory: inv)

        var workspaces = wsStore.workspaces(for: "host1")
        XCTAssertEqual(workspaces.count, 4)

        let ws1 = workspaces.first(where: { $0.path == "/Users/pai/projects/my-web" })
        XCTAssertEqual(ws1?.name, "my-web")
        XCTAssertEqual(ws1?.apps.sorted(), ["agy", "codex"])
        XCTAssertEqual(ws1?.source, "derived")

        let wsSanitized = workspaces.first(where: { $0.path == "/Users/pai/projects/My.App!Test" })
        XCTAssertEqual(wsSanitized?.name, "my.app-test")

        let wsCol1 = workspaces.first(where: { $0.path == "/other/disk/my-web" })
        XCTAssertEqual(wsCol1?.name, "my-web-2")

        let wsCol2 = workspaces.first(where: { $0.path == "/third/disk/my-web" })
        XCTAssertEqual(wsCol2?.name, "my-web-3")

        // Test stability: Save again with new session, existing assignments remain intact
        let sessions2 = sessions + [
            LightSessionEntry(app: "codex", id: "s6", cwd: "/fourth/disk/my-web")
        ]
        let inv2 = LightNodeInventory(node: "host1", at: Date(), sessions: sessions2, notes: [])
        try invStore.save(node: "host1", inventory: inv2)

        workspaces = wsStore.workspaces(for: "host1")
        XCTAssertEqual(workspaces.count, 5)
        XCTAssertEqual(workspaces.first(where: { $0.path == "/other/disk/my-web" })?.name, "my-web-2")
        XCTAssertEqual(workspaces.first(where: { $0.path == "/third/disk/my-web" })?.name, "my-web-3")
        XCTAssertEqual(workspaces.first(where: { $0.path == "/fourth/disk/my-web" })?.name, "my-web-4")

        // Test manual workspace preservation
        let manual = try wsStore.addManual(node: "host1", path: "/manual/path/custom", name: "my-custom")
        XCTAssertEqual(manual.source, "manual")
        XCTAssertEqual(manual.name, "my-custom")

        try invStore.save(node: "host1", inventory: inv2)
        workspaces = wsStore.workspaces(for: "host1")
        let manualFound = workspaces.first(where: { $0.path == "/manual/path/custom" })
        XCTAssertNotNil(manualFound)
        XCTAssertEqual(manualFound?.source, "manual")
        XCTAssertEqual(manualFound?.name, "my-custom")
    }

    // MARK: - 6. Address Resolution

    func testAddressResolution() throws {
        let tempDir = makeTempDir("address-test")
        let invStore = LightInventoryStore(rootDir: tempDir)

        let sessions = [
            LightSessionEntry(app: "codex", id: "abcdef123456", cwd: "/Users/pai/projects/pharos", title: "Task 1"),
            LightSessionEntry(app: "codex", id: "abcdef999999", cwd: "/Users/pai/projects/pharos", title: "Task 2"),
            LightSessionEntry(app: "agy", id: "12345678-abcd-1111", cwd: "/Users/pai/projects/pharos", title: "Task 3"),
            LightSessionEntry(app: "agy", id: "fedcba98-2222-3333", cwd: nil, title: "Task 4")
        ]
        let inv = LightNodeInventory(node: "mini", at: Date(), sessions: sessions, notes: [])
        try invStore.save(node: "mini", inventory: inv)

        // 1. Full 4-part address
        let res1 = try LightDirectory.resolve("mini/codex/pharos/abcdef12", inventoryStore: invStore)
        XCTAssertEqual(res1.host, "mini")
        XCTAssertEqual(res1.app, "codex")
        XCTAssertEqual(res1.entry.id, "abcdef123456")

        // 2. 3-part address (project omitted, unique prefix >= 4 chars)
        let res2 = try LightDirectory.resolve("mini/agy/1234", inventoryStore: invStore)
        XCTAssertEqual(res2.host, "mini")
        XCTAssertEqual(res2.app, "agy")
        XCTAssertEqual(res2.entry.id, "12345678-abcd-1111")

        // 3. Ambiguous prefix
        XCTAssertThrowsError(try LightDirectory.resolve("mini/codex/pharos/abcdef", inventoryStore: invStore)) { error in
            guard let resolveErr = error as? LightDirectory.ResolveError,
                  case .ambiguous(let candidates) = resolveErr else {
                XCTFail("expected ambiguous error, got \(error)")
                return
            }
            XCTAssertEqual(candidates.count, 2)
            XCTAssertTrue(candidates.contains("abcdef123456"))
            XCTAssertTrue(candidates.contains("abcdef999999"))
        }

        // 4. Unknown host
        XCTAssertThrowsError(try LightDirectory.resolve("studio/codex/pharos/abcdef12", inventoryStore: invStore)) { error in
            guard let resolveErr = error as? LightDirectory.ResolveError,
                  case .unknownHost(let h) = resolveErr else {
                XCTFail("expected unknownHost error, got \(error)")
                return
            }
            XCTAssertEqual(h, "studio")
        }

        // 5. No session match
        XCTAssertThrowsError(try LightDirectory.resolve("mini/codex/pharos/nonexistent", inventoryStore: invStore)) { error in
            guard let resolveErr = error as? LightDirectory.ResolveError,
                  case .noSession = resolveErr else {
                XCTFail("expected noSession error, got \(error)")
                return
            }
        }

        // 6. Project "-" for session with no cwd
        let res4 = try LightDirectory.resolve("mini/agy/-/fedcba98", inventoryStore: invStore)
        XCTAssertEqual(res4.entry.id, "fedcba98-2222-3333")
    }

    // MARK: - 7. `pharos ls` Levels

    func testLsLevels() throws {
        let tempDir = makeTempDir("ls-test")
        let invStore = LightInventoryStore(rootDir: tempDir)

        let sessions = [
            LightSessionEntry(app: "codex", id: "c11111112222", cwd: "/tmp/proj1", title: "Codex Session"),
            LightSessionEntry(app: "agy", id: "a22222223333", cwd: "/tmp/proj1", title: "Agy Session")
        ]
        let inv = LightNodeInventory(node: "mini", at: Date(), sessions: sessions, notes: [])
        try invStore.save(node: "mini", inventory: inv)

        // Level 0: No target -> host summary
        let res0 = LightInventoryCommands.executeLs(
            arguments: [],
            rootDir: tempDir,
            router: nil,
            members: [],
            now: Date()
        )
        XCTAssertEqual(res0.exitCode, 0)
        XCTAssertTrue(res0.text.contains("mini"))
        XCTAssertTrue(res0.text.contains("workspaces"))
        XCTAssertTrue(res0.text.contains("apps agy:1 codex:1"))

        // Level 1: host -> workspaces
        let res1 = LightInventoryCommands.executeLs(
            arguments: ["mini"],
            rootDir: tempDir,
            router: nil,
            members: [],
            now: Date()
        )
        XCTAssertEqual(res1.exitCode, 0)
        XCTAssertTrue(res1.text.contains("WORKSPACE\tPATH\tSOURCE\tAPPS"))
        XCTAssertTrue(res1.text.contains("proj1"))

        // Level 2: host/app -> workspaces for app
        let res2 = LightInventoryCommands.executeLs(
            arguments: ["mini/codex"],
            rootDir: tempDir,
            router: nil,
            members: [],
            now: Date()
        )
        XCTAssertEqual(res2.exitCode, 0)
        XCTAssertTrue(res2.text.contains("WORKSPACE\tPATH\tSOURCE\tSESSIONS"))
        XCTAssertTrue(res2.text.contains("proj1\t/tmp/proj1\tderived\t1"))

        // Level 3: host/app/project -> sessions
        let res3 = LightInventoryCommands.executeLs(
            arguments: ["mini/codex/proj1"],
            rootDir: tempDir,
            router: nil,
            members: [],
            now: Date()
        )
        XCTAssertEqual(res3.exitCode, 0)
        XCTAssertTrue(res3.text.contains("ADDRESS\tTITLE\tLAST\tSTATE\tMEMBER"))
        XCTAssertTrue(res3.text.contains("mini/codex/proj1/c1111111"))
        XCTAssertTrue(res3.text.contains("Codex Session"))

        // JSON check
        let resJson = LightInventoryCommands.executeLs(
            arguments: ["mini/codex/proj1", "--json"],
            rootDir: tempDir,
            router: nil,
            members: [],
            now: Date()
        )
        XCTAssertEqual(resJson.exitCode, 0)
        XCTAssertTrue(resJson.text.contains("\"id\" : \"c11111112222\""))
    }

    // MARK: - 8. Inventory Store Round Trip & File Mode

    func testInventoryStoreRoundTrip() throws {
        let tempDir = makeTempDir("store-test")
        let store = LightInventoryStore(rootDir: tempDir)

        let session = LightSessionEntry(app: "codex", id: "sess-100", cwd: "/tmp/code", title: "Store Test")
        let inv = LightNodeInventory(node: "node1", at: Date(timeIntervalSince1970: 1700000000), sessions: [session], notes: ["note 1"])

        try store.save(node: "node1", inventory: inv)

        let fileURL = store.fileURL(for: "node1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Check 0600 permissions
        #if canImport(Darwin) || canImport(Glibc)
        var statBuf = stat()
        stat(fileURL.path, &statBuf)
        let mode = statBuf.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
        XCTAssertEqual(mode, S_IRUSR | S_IWUSR)
        #endif

        let loaded = store.load(node: "node1")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.node, "node1")
        XCTAssertEqual(loaded?.sessions.count, 1)
        XCTAssertEqual(loaded?.sessions[0].id, "sess-100")
        XCTAssertEqual(loaded?.notes, ["note 1"])

        let all = store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertNotNil(all["node1"])
    }

    // MARK: - 9. `pharos agents` Listing & Stale Warning

    func testAgentsListing() throws {
        let tempDir = makeTempDir("agents-test")
        let store = LightInventoryStore(rootDir: tempDir)

        let now = Date(timeIntervalSince1970: 10_000)
        let freshTime = now.addingTimeInterval(-60) // 1m old
        let staleTime = now.addingTimeInterval(-360) // 6m old (> 5 min)

        let s1 = LightSessionEntry(app: "codex", id: "cx-11112222", cwd: "/tmp/p1", title: "Active Codex", lastActive: freshTime, state: "active")
        let s2 = LightSessionEntry(app: "agy", id: "ag-33334444", cwd: "/tmp/p2", title: "Idle Agy", lastActive: staleTime, state: "idle")

        let invMini = LightNodeInventory(node: "mini", at: freshTime, sessions: [s1], notes: ["note mini"])
        let invStudio = LightNodeInventory(node: "studio", at: staleTime, sessions: [s2], notes: ["note studio"])

        try store.save(node: "mini", inventory: invMini)
        try store.save(node: "studio", inventory: invStudio)

        // Member matching check
        let member = LightMember(
            name: "cx-bot",
            host: "mini",
            app: "codex",
            project: "p1",
            sessionID: "cx-11112222",
            routes: []
        )

        let res = LightInventoryCommands.executeAgents(
            arguments: [],
            rootDir: tempDir,
            router: nil,
            members: [member],
            now: now
        )
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(res.text.contains("HOST\tAPP\tSESSION\tPROJECT\tTITLE\tLAST\tSTATE\tMEMBER"))
        XCTAssertTrue(res.text.contains("mini\tcodex\tcx-11112\tp1\tActive Codex\t1m\tactive\tcx-bot"))
        XCTAssertTrue(res.text.contains("studio\tagy\tag-33334\tp2\tIdle Agy\t6m\tidle\t-"))

        // Fresh footer
        XCTAssertTrue(res.text.contains("host mini: inventory 1m old (note mini)"))
        // Stale footer (> 5m)
        XCTAssertTrue(res.text.contains("host studio: inventory 6m old (stale; pharos agents --refresh --host studio) (note studio)"))

        // Filter --app codex
        let resApp = LightInventoryCommands.executeAgents(
            arguments: ["--app", "codex"],
            rootDir: tempDir,
            router: nil,
            members: [member],
            now: now
        )
        XCTAssertTrue(resApp.text.contains("cx-11112"))
        XCTAssertFalse(resApp.text.contains("ag-33334"))

        // Filter --project p2
        let resProj = LightInventoryCommands.executeAgents(
            arguments: ["--project", "p2"],
            rootDir: tempDir,
            router: nil,
            members: [member],
            now: now
        )
        XCTAssertFalse(resProj.text.contains("cx-11112"))
        XCTAssertTrue(resProj.text.contains("ag-33334"))
    }

    // MARK: - 10. `member adopt` Tests

    private final class MockAdoptAgents: LightMemberAgents, @unchecked Sendable {
        var notes: [String] = []
        var onAdopt: ((_ name: String, _ app: String, _ cwd: String, _ sessionID: String, _ host: String, _ model: String?, _ tmuxSession: String?, _ project: String, _ autoRevive: Bool) throws -> LightMember)?

        func launch(name: String, app: String, cwd: String, host: String, model: String?, tmuxSession: String?, openingMessage: String?, project: String) throws -> LightMember {
            throw CLIAgentLifecycleError.invalid("not launch")
        }
        func revive(_ member: LightMember) throws -> LightTmuxBinding {
            throw CLIAgentLifecycleError.invalid("not revive")
        }
        func stop(_ member: LightMember, force: Bool) throws -> LightTmuxBinding {
            throw CLIAgentLifecycleError.invalid("not stop")
        }
        func status(_ member: LightMember) -> LightMemberRuntimeStatus? { nil }

        func adopt(name: String, app: String, cwd: String, sessionID: String, host: String, model: String?, tmuxSession: String?, project: String, autoRevive: Bool) throws -> LightMember {
            if let onAdopt {
                return try onAdopt(name, app, cwd, sessionID, host, model, tmuxSession, project, autoRevive)
            }
            let binding = LightTmuxBinding(session: tmuxSession ?? "pharos-\(name)", cwd: cwd, model: model, agentPID: 1234, agentStarted: "now")
            return LightMember(
                name: name,
                host: host,
                app: app,
                project: project,
                sessionID: sessionID,
                routes: [LightRoute(id: "tmux", access: .write, fallback: false, summary: "tmux")],
                tmux: binding
            )
        }
    }

    func testAdoptSuccessAndErrors() throws {
        let tempDir = makeTempDir("adopt-test")
        let relayStore = tempDir.appendingPathComponent("relay")
        let relay = try LightRelay(store: relayStore)
        let invStore = LightInventoryStore(rootDir: relay.storeURL)

        let sessionIdle = LightSessionEntry(app: "codex", id: "sess-idle-1", cwd: "/tmp/adopt-proj", title: "Idle Task", state: "idle")
        let sessionBusy = LightSessionEntry(app: "codex", id: "sess-busy-2", cwd: "/tmp/adopt-proj", title: "Busy Task", state: "active")
        let sessionNoCwd = LightSessionEntry(app: "agy", id: "sess-nocwd-3", cwd: nil, title: "No Cwd Task", state: "unknown")
        let sessionCursor = LightSessionEntry(app: "cursor", id: "sess-cursor-4", cwd: "/tmp/adopt-proj", title: "Cursor Task", state: "unknown")

        let inv = LightNodeInventory(node: "local", at: Date(), sessions: [sessionIdle, sessionBusy, sessionNoCwd, sessionCursor], notes: [])
        try invStore.save(node: "local", inventory: inv)

        let mockAgents = MockAdoptAgents()

        // 1. Success address form
        let resSuccess = LightCommands.execute(
            command: "member",
            arguments: ["adopt", "local/codex/adopt-proj/sess-idle-1", "--name", "bot-1"],
            relay: relay,
            routesForApp: LightRouteCatalog.defaults(for:),
            agents: mockAgents
        )
        XCTAssertEqual(resSuccess.exitCode, 0)
        XCTAssertTrue(resSuccess.text.contains("adopted bot-1 (app codex) on local in tmux pharos-bot-1, session sess-idle-1"))
        XCTAssertNotNil(relay.member(named: "bot-1"))

        // 2. Duplicate member name error
        let resDupName = LightCommands.execute(
            command: "member",
            arguments: ["adopt", "local/codex/adopt-proj/sess-idle-1", "--name", "bot-1"],
            relay: relay,
            routesForApp: LightRouteCatalog.defaults(for:),
            agents: mockAgents
        )
        XCTAssertEqual(resDupName.exitCode, 1)
        XCTAssertTrue(resDupName.text.contains("bot-1"))
        XCTAssertTrue(resDupName.text.contains("already registered"))

        // 3. Duplicate session ID error
        let resDupSess = LightCommands.execute(
            command: "member",
            arguments: ["adopt", "local/codex/adopt-proj/sess-idle-1", "--name", "bot-2"],
            relay: relay,
            routesForApp: LightRouteCatalog.defaults(for:),
            agents: mockAgents
        )
        XCTAssertEqual(resDupSess.exitCode, 1)
        XCTAssertTrue(resDupSess.text.contains("member 'bot-1' already has session id 'sess-idle-1'"))

        // 4. Busy codex without --force error
        let resBusy = LightCommands.execute(
            command: "member",
            arguments: ["adopt", "local/codex/adopt-proj/sess-busy-2", "--name", "bot-busy"],
            relay: relay,
            routesForApp: LightRouteCatalog.defaults(for:),
            agents: mockAgents
        )
        XCTAssertEqual(resBusy.exitCode, 1)
        XCTAssertTrue(resBusy.text.contains("session is busy in another client; --force to attach anyway"))

        // 5. Busy codex with --force succeeds!
        let resBusyForce = LightCommands.execute(
            command: "member",
            arguments: ["adopt", "local/codex/adopt-proj/sess-busy-2", "--name", "bot-busy", "--force"],
            relay: relay,
            routesForApp: LightRouteCatalog.defaults(for:),
            agents: mockAgents
        )
        XCTAssertEqual(resBusyForce.exitCode, 0)
        XCTAssertTrue(resBusyForce.text.contains("adopted bot-busy"))

        // 6. Missing cwd error
        let resNoCwd = LightCommands.execute(
            command: "member",
            arguments: ["adopt", "local", "agy", "sess-nocwd-3", "--name", "bot-nocwd"],
            relay: relay,
            routesForApp: LightRouteCatalog.defaults(for:),
            agents: mockAgents
        )
        XCTAssertEqual(resNoCwd.exitCode, 1)
        XCTAssertTrue(resNoCwd.text.contains("no cwd known for sess-nocwd-3; pass --dir"))

        // 7. Missing cwd with --dir succeeds!
        let resWithDir = LightCommands.execute(
            command: "member",
            arguments: ["adopt", "local", "agy", "sess-nocwd-3", "--name", "bot-nocwd", "--dir", "/tmp/custom-dir"],
            relay: relay,
            routesForApp: LightRouteCatalog.defaults(for:),
            agents: mockAgents
        )
        XCTAssertEqual(resWithDir.exitCode, 0)
        XCTAssertTrue(resWithDir.text.contains("adopted bot-nocwd"))

        // 8. Unsupported app error
        let resCursor = LightCommands.execute(
            command: "member",
            arguments: ["adopt", "local", "cursor", "sess-cursor-4", "--name", "bot-cursor"],
            relay: relay,
            routesForApp: LightRouteCatalog.defaults(for:),
            agents: mockAgents
        )
        XCTAssertEqual(resCursor.exitCode, 1)
        XCTAssertTrue(resCursor.text.contains("adopt supports codex and agy; use pharos member register for cursor"))
    }

    // MARK: - 11. Launch without --dir Resolves Project Workspace

    func testLaunchResolvesWorkspaceProject() throws {
        let tempDir = makeTempDir("launch-ws-test")
        let relayStore = tempDir.appendingPathComponent("relay")
        let relay = try LightRelay(store: relayStore)
        let wsStore = LightWorkspaceStore(rootDir: relay.storeURL)

        _ = try wsStore.addManual(node: "local", path: "/tmp/project-auto-dir", name: "my-service")

        final class LaunchAgent: LightMemberAgents, @unchecked Sendable {
            var notes: [String] = []
            var recordedCwd: String?
            func launch(name: String, app: String, cwd: String, host: String, model: String?, tmuxSession: String?, openingMessage: String?, project: String) throws -> LightMember {
                self.recordedCwd = cwd
                let binding = LightTmuxBinding(session: tmuxSession ?? "pharos-\(name)", cwd: cwd)
                return LightMember(name: name, host: host, app: app, project: project, sessionID: "s-1", routes: [], tmux: binding)
            }
            func revive(_ member: LightMember) throws -> LightTmuxBinding { throw CLIAgentLifecycleError.invalid("not revive") }
            func stop(_ member: LightMember, force: Bool) throws -> LightTmuxBinding { throw CLIAgentLifecycleError.invalid("not stop") }
            func status(_ member: LightMember) -> LightMemberRuntimeStatus? { nil }
        }

        let launcher = LaunchAgent()
        let res = LightCommands.execute(
            command: "member",
            arguments: ["launch", "--app", "codex", "--name", "launch-bot", "--project", "my-service"],
            relay: relay,
            routesForApp: LightRouteCatalog.defaults(for:),
            agents: launcher
        )
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertEqual(launcher.recordedCwd, "/tmp/project-auto-dir")
    }

    // MARK: - 12. Project Workspaces Without --app

    func testProjectWorkspacesWithoutApp() throws {
        let tempDir = makeTempDir("project-ws-test")

        // 1. Add workspace
        let resAdd = LightInventoryCommands.executeProjectWorkspaces(
            arguments: ["add", "--host", "mini", "--path", "/tmp/my-ws-dir", "--name", "my-ws"],
            rootDir: tempDir
        )
        XCTAssertNotNil(resAdd)
        XCTAssertEqual(resAdd?.exitCode, 0)
        XCTAssertTrue(resAdd?.text.contains("added workspace 'my-ws' on mini: /tmp/my-ws-dir") == true)

        // 2. List workspaces
        let resList = LightInventoryCommands.executeProjectWorkspaces(
            arguments: ["list", "--host", "mini"],
            rootDir: tempDir
        )
        XCTAssertNotNil(resList)
        XCTAssertEqual(resList?.exitCode, 0)
        XCTAssertTrue(resList?.text.contains("NAME\tPATH\tSOURCE\tAPPS\tSESSIONS") == true)
        XCTAssertTrue(resList?.text.contains("my-ws\t/tmp/my-ws-dir\tmanual\t-\t0") == true)

        // 3. With --app flag returns nil so achat handler handles it
        let resWithApp = LightInventoryCommands.executeProjectWorkspaces(
            arguments: ["list", "--host", "mini", "--app", "codex"],
            rootDir: tempDir
        )
        XCTAssertNil(resWithApp)
    }
}
