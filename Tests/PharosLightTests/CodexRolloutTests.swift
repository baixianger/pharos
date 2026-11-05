import XCTest
@testable import PharosRuntime

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class CodexRolloutTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func createTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-codex-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    func testPlainJsonlFirstCompletedReplyAndCwd() throws {
        let tempDir = createTempDir()
        let sessionsDir = tempDir.appendingPathComponent("sessions/2026/11/04", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let sessionID = "sess-plain-1"
        let rolloutFile = sessionsDir.appendingPathComponent("rollout-20261104-120000-\(sessionID).jsonl")

        let fixtureContent = """
        {"timestamp":"2026-11-04T19:48:34.000Z","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"\(tempDir.path)"}}
        {"timestamp":"2026-11-04T19:48:35.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"PONG"}}
        """
        try fixtureContent.write(to: rolloutFile, atomically: true, encoding: .utf8)

        let reader = CodexRolloutReader(root: tempDir.appendingPathComponent("sessions", isDirectory: true))

        XCTAssertEqual(reader.cwd(sessionID: sessionID), tempDir.path)

        let reply = reader.firstCompletedReply(
            sessionID: sessionID,
            since: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(reply, "PONG")
    }

    func testZstViaInjectedDecompressClosure() throws {
        let tempDir = createTempDir()
        let sessionsDir = tempDir.appendingPathComponent("sessions/2026/11/04", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let sessionID = "sess-zst-fake"
        let zstFile = sessionsDir.appendingPathComponent("rollout-20261104-130000-\(sessionID).jsonl.zst")
        try Data("dummy-zst-bytes".utf8).write(to: zstFile)

        let cannedJson = """
        {"timestamp":"2026-11-04T19:48:34.000Z","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"\(tempDir.path)"}}
        {"timestamp":"2026-11-04T19:48:35.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"PONG-FROM-ZST"}}
        """

        let decompressCalled = Box(false)
        let reader = CodexRolloutReader(
            root: tempDir.appendingPathComponent("sessions", isDirectory: true),
            decompress: { url in
                XCTAssertEqual(url.resolvingSymlinksInPath().path, zstFile.resolvingSymlinksInPath().path)
                decompressCalled.value = true
                return cannedJson.data(using: .utf8)
            }
        )

        XCTAssertEqual(reader.cwd(sessionID: sessionID), tempDir.resolvingSymlinksInPath().path)
        XCTAssertTrue(decompressCalled.value)

        let reply = reader.firstCompletedReply(
            sessionID: sessionID,
            since: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(reply, "PONG-FROM-ZST")
    }

    func testZstViaRealDefaultDecompressor() throws {
        let zstdPath: String?
        if let envBin = ProcessInfo.processInfo.environment["PHAROS_ZSTD_BIN"],
           FileManager.default.isExecutableFile(atPath: envBin) {
            zstdPath = envBin
        } else if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/zstd") {
            zstdPath = "/opt/homebrew/bin/zstd"
        } else if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/zstd") {
            zstdPath = "/usr/local/bin/zstd"
        } else if FileManager.default.isExecutableFile(atPath: "/usr/bin/zstd") {
            zstdPath = "/usr/bin/zstd"
        } else {
            zstdPath = nil
        }

        guard let zstd = zstdPath else {
            throw XCTSkip("zstd binary not found on this system")
        }

        let tempDir = createTempDir()
        let sessionsDir = tempDir.appendingPathComponent("sessions/2026/11/04", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let sessionID = "sess-zst-real"
        let plainFile = sessionsDir.appendingPathComponent("temp-\(sessionID).jsonl")
        let zstFile = sessionsDir.appendingPathComponent("rollout-20261104-140000-\(sessionID).jsonl.zst")

        let content = """
        {"timestamp":"2026-11-04T19:48:34.000Z","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"\(tempDir.path)"}}
        {"timestamp":"2026-11-04T19:48:35.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"REAL-ZSTD-PONG"}}
        """
        try content.write(to: plainFile, atomically: true, encoding: .utf8)

        // Compress using real zstd command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-f", plainFile.path, "-o", zstFile.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        // Remove the plain uncompressed file
        try FileManager.default.removeItem(at: plainFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zstFile.path))

        let reader = CodexRolloutReader(root: tempDir.appendingPathComponent("sessions", isDirectory: true))
        XCTAssertEqual(reader.cwd(sessionID: sessionID), tempDir.path)

        let reply = reader.firstCompletedReply(
            sessionID: sessionID,
            since: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(reply, "REAL-ZSTD-PONG")
    }

    func testArchivedSessionsLookup() throws {
        let tempDir = createTempDir()
        let sessionsDir = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archivedDir = tempDir.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedDir, withIntermediateDirectories: true)

        let sessionID = "archived-1"
        let archivedRollout = archivedDir.appendingPathComponent("rollout-20261104-150000-\(sessionID).jsonl")

        let content = """
        {"timestamp":"2026-11-04T19:48:34.000Z","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"\(tempDir.path)"}}
        {"timestamp":"2026-11-04T19:48:35.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"ARCHIVED-PONG"}}
        """
        try content.write(to: archivedRollout, atomically: true, encoding: .utf8)

        let reader = CodexRolloutReader(root: sessionsDir)
        let found = reader.rollout(sessionID: sessionID)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.resolvingSymlinksInPath().path, archivedRollout.resolvingSymlinksInPath().path)
        XCTAssertEqual(reader.cwd(sessionID: sessionID), tempDir.resolvingSymlinksInPath().path)
        XCTAssertEqual(reader.firstCompletedReply(sessionID: sessionID, since: Date(timeIntervalSince1970: 0)), "ARCHIVED-PONG")
    }

    func testPlainPreferredOverZst() throws {
        let tempDir = createTempDir()
        let sessionsDir = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archivedDir = tempDir.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedDir, withIntermediateDirectories: true)

        let reader = CodexRolloutReader(root: sessionsDir)

        // Case 1: Both exist in the same directory (sessions)
        let sess1 = "sess-both-same"
        let plainFile1 = sessionsDir.appendingPathComponent("rollout-001-\(sess1).jsonl")
        let zstFile1 = sessionsDir.appendingPathComponent("rollout-001-\(sess1).jsonl.zst")
        try "plain".write(to: plainFile1, atomically: true, encoding: .utf8)
        try "zst".write(to: zstFile1, atomically: true, encoding: .utf8)

        let found1 = reader.rollout(sessionID: sess1)
        XCTAssertEqual(found1?.resolvingSymlinksInPath().path, plainFile1.resolvingSymlinksInPath().path)

        // Case 2: ZST in sessions, plain JSONL in archived_sessions
        let sess2 = "sess-zst-sessions-plain-archived"
        let zstFile2 = sessionsDir.appendingPathComponent("rollout-002-\(sess2).jsonl.zst")
        let plainFile2 = archivedDir.appendingPathComponent("rollout-002-\(sess2).jsonl")
        try "zst".write(to: zstFile2, atomically: true, encoding: .utf8)
        try "plain".write(to: plainFile2, atomically: true, encoding: .utf8)

        let found2 = reader.rollout(sessionID: sess2)
        XCTAssertEqual(found2?.resolvingSymlinksInPath().path, plainFile2.resolvingSymlinksInPath().path)

        // Case 3: Only ZST exists in archived_sessions
        let sess3 = "sess-only-zst-archived"
        let zstFile3 = archivedDir.appendingPathComponent("rollout-003-\(sess3).jsonl.zst")
        try "zst".write(to: zstFile3, atomically: true, encoding: .utf8)

        let found3 = reader.rollout(sessionID: sess3)
        XCTAssertEqual(found3?.resolvingSymlinksInPath().path, zstFile3.resolvingSymlinksInPath().path)
    }

    func testReplyAfterMarkerPicksTheAnswerToThatTurn() throws {
        let tempDir = createTempDir()
        let sessionsDir = tempDir.appendingPathComponent("sessions/2026/11/04", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let sessionID = "sess-marker-1"
        let rolloutFile = sessionsDir.appendingPathComponent("rollout-20261104-120000-\(sessionID).jsonl")
        // Two queued sends flushed back to back: each answer must go to its own ask.
        let fixture = """
        {"timestamp":"2026-11-04T23:05:00.000Z","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"/tmp"}}
        {"timestamp":"2026-11-04T23:05:30.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"x reply-id=r_first"}]}}
        {"timestamp":"2026-11-04T23:05:38.000Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"x"}}
        {"timestamp":"2026-11-04T23:06:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"what was the code? reply-id=r_second"}}
        {"timestamp":"2026-11-04T23:06:26.000Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"TANGERINE-42"}}
        """
        try fixture.write(to: rolloutFile, atomically: true, encoding: .utf8)
        let reader = CodexRolloutReader(root: tempDir.appendingPathComponent("sessions", isDirectory: true))

        let first = reader.reply(sessionID: sessionID, afterMarker: "reply-id=r_first")
        XCTAssertTrue(first.found); XCTAssertEqual(first.text, "x")
        let second = reader.reply(sessionID: sessionID, afterMarker: "reply-id=r_second")
        XCTAssertTrue(second.found); XCTAssertEqual(second.text, "TANGERINE-42")
        XCTAssertFalse(reader.reply(sessionID: sessionID, afterMarker: "reply-id=r_none").found)
    }
}
