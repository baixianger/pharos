import XCTest
@testable import PharosRuntime

private final class TestClock: @unchecked Sendable {
    var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }
    func now() -> Date { current }
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

final class AgyTranscriptTests: XCTestCase {
    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        tempFiles.removeAll()
        super.tearDown()
    }

    private func tempStoreURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-agy-test-\(UUID().uuidString).json")
        tempFiles.append(url)
        return url
    }

    // MARK: - AgyTranscript Tests

    func testTranscriptParseWithSkippedIndexAndTornLastLine() {
        let jsonl = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-04T19:42:16Z","content":"<USER_REQUEST>\\nReply with exactly: pong\\n</USER_REQUEST>\\n<ADDITIONAL_METADATA>..."}
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-04T19:42:18Z","content":"pong","input_tokens":11967,"output_tokens":190}
        {"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-04T19:42:20Z","tool_calls":[{"id":"call_1"}],"thinking":"..."}
        {"step_index":4,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-04T19:42:21Z","content":"Created At: ..."}
        {"step_index":5,"source":"MODEL"
        """

        let steps = AgyTranscript.parse(jsonl)
        XCTAssertEqual(steps.count, 4)

        XCTAssertEqual(steps[0].index, 0)
        XCTAssertEqual(steps[0].source, "USER_EXPLICIT")
        XCTAssertEqual(steps[0].type, "USER_INPUT")
        XCTAssertEqual(steps[0].status, "DONE")
        XCTAssertFalse(steps[0].hasToolCalls)

        XCTAssertEqual(steps[1].index, 1)
        XCTAssertEqual(steps[1].source, "MODEL")
        XCTAssertEqual(steps[1].type, "PLANNER_RESPONSE")
        XCTAssertEqual(steps[1].content, "pong")
        XCTAssertFalse(steps[1].hasToolCalls)

        // Skipped step 2; step 3 has tool calls
        XCTAssertEqual(steps[2].index, 3)
        XCTAssertTrue(steps[2].hasToolCalls)
        XCTAssertEqual(steps[2].content, "")

        XCTAssertEqual(steps[3].index, 4)
        XCTAssertEqual(steps[3].type, "GENERIC")

        XCTAssertEqual(AgyTranscript.cursor(steps), 4)
    }

    func testTranscriptCursor() {
        XCTAssertEqual(AgyTranscript.cursor([]), -1)

        let steps = [
            AgyStep(index: 2, source: "USER_EXPLICIT", type: "USER_INPUT", status: "DONE"),
            AgyStep(index: 10, source: "MODEL", type: "PLANNER_RESPONSE", status: "DONE"),
            AgyStep(index: 5, source: "MODEL", type: "GENERIC", status: "DONE"),
        ]
        XCTAssertEqual(AgyTranscript.cursor(steps), 10)
    }

    func testReplyAfterPicksFinalAnswerNotToolCall() {
        let steps = [
            AgyStep(index: 0, source: "USER_EXPLICIT", type: "USER_INPUT", status: "DONE"),
            AgyStep(index: 1, source: "MODEL", type: "PLANNER_RESPONSE", status: "DONE", content: "calling tool", hasToolCalls: true),
            AgyStep(index: 2, source: "MODEL", type: "GENERIC", status: "DONE", content: "tool output"),
            AgyStep(index: 3, source: "MODEL", type: "PLANNER_RESPONSE", status: "DONE", content: "calling another tool", hasToolCalls: true),
            AgyStep(index: 4, source: "MODEL", type: "GENERIC", status: "DONE", content: "tool output 2"),
            AgyStep(index: 5, source: "MODEL", type: "PLANNER_RESPONSE", status: "DONE", content: "Final pong answer", hasToolCalls: false),
        ]

        let reply = AgyTranscript.reply(after: -1, in: steps)
        XCTAssertNotNil(reply)
        XCTAssertEqual(reply?.text, "Final pong answer")
        XCTAssertEqual(reply?.step, 5)
    }

    func testReplyAfterReturnsNilWhileTurnHasOnlyToolCalls() {
        let steps = [
            AgyStep(index: 0, source: "USER_EXPLICIT", type: "USER_INPUT", status: "DONE"),
            AgyStep(index: 1, source: "MODEL", type: "PLANNER_RESPONSE", status: "DONE", content: "tool call", hasToolCalls: true),
            AgyStep(index: 2, source: "MODEL", type: "GENERIC", status: "DONE", content: "output"),
        ]

        let reply = AgyTranscript.reply(after: -1, in: steps)
        XCTAssertNil(reply)
    }

    func testReplyIgnoresTurnsBeforeCursor() {
        let steps = [
            AgyStep(index: 0, source: "USER_EXPLICIT", type: "USER_INPUT", status: "DONE"),
            AgyStep(index: 1, source: "MODEL", type: "PLANNER_RESPONSE", status: "DONE", content: "old answer", hasToolCalls: false),
            AgyStep(index: 2, source: "USER_EXPLICIT", type: "USER_INPUT", status: "DONE"),
            AgyStep(index: 3, source: "MODEL", type: "PLANNER_RESPONSE", status: "DONE", content: "new answer", hasToolCalls: false),
        ]

        let reply = AgyTranscript.reply(after: 1, in: steps)
        XCTAssertNotNil(reply)
        XCTAssertEqual(reply?.text, "new answer")
        XCTAssertEqual(reply?.step, 3)
    }

    func testReplySince() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let tOld = t0.addingTimeInterval(-10) // 10s before since -> excluded
        let tTurn1 = t0.addingTimeInterval(-1) // 1s before since -> within 2s skew -> included!

        let steps = [
            AgyStep(index: 0, source: "USER_EXPLICIT", type: "USER_INPUT", status: "DONE", createdAt: tOld),
            AgyStep(index: 1, source: "MODEL", type: "PLANNER_RESPONSE", status: "DONE", createdAt: tOld.addingTimeInterval(2), content: "ancient answer"),
            AgyStep(index: 2, source: "USER_EXPLICIT", type: "USER_INPUT", status: "DONE", createdAt: tTurn1),
            AgyStep(index: 3, source: "MODEL", type: "PLANNER_RESPONSE", status: "DONE", createdAt: tTurn1.addingTimeInterval(2), content: "recent answer"),
        ]

        let reply = AgyTranscript.reply(since: t0, in: steps)
        XCTAssertNotNil(reply)
        XCTAssertEqual(reply?.text, "recent answer")
        XCTAssertEqual(reply?.step, 3)

        // If since is far in future, returns nil
        let futureReply = AgyTranscript.reply(since: t0.addingTimeInterval(100), in: steps)
        XCTAssertNil(futureReply)
    }

    func testUserText() {
        let wrapped = """
        <USER_REQUEST>
        Reply with exactly: pong
        </USER_REQUEST>
        <ADDITIONAL_METADATA>
        {"key": "value"}
        </ADDITIONAL_METADATA>
        """
        XCTAssertEqual(AgyTranscript.userText(wrapped), "Reply with exactly: pong")
        XCTAssertEqual(AgyTranscript.userText("plain text prompt"), "plain text prompt")
    }

    func testTranscriptPathAndLoad() throws {
        let appData = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = AgyTranscript.path(conversationID: "conv-123", appData: appData)
        XCTAssertTrue(path.path.contains("conv-123"))
        XCTAssertTrue(path.path.hasSuffix(".system_generated/logs/transcript.jsonl"))

        // Missing file returns []
        XCTAssertEqual(AgyTranscript.load(path), [])

        // Existing file parses
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sample = "{\"step_index\":0,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"status\":\"DONE\"}\n"
        try sample.write(to: path, atomically: true, encoding: .utf8)
        tempFiles.append(appData)

        let loaded = AgyTranscript.load(path)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].index, 0)
    }

    // MARK: - AgyPane Tests

    func testPaneClassifyIdleAndBusy() {
        let idlePane = """
        Some previous log lines
        > Hello
        Here is the output
        ? for shortcuts      accept-edits · Gemini 3.8 Flash · high
        """
        XCTAssertEqual(AgyPane.classify(idlePane), .idle)

        let busyPane = """
        Running task...
        esc to cancel     accept-edits · Gemini 3.8 Flash · high
        """
        XCTAssertEqual(AgyPane.classify(busyPane), .busy)
    }

    func testPaneClassifyPermissionAndTrust() {
        let permPane = """
        Requesting permission for:
           swift test --filter PharosLightTests
        Run this command?
        > 1. Yes, run command
          2. Yes, and always allow
          3. No, cancel
        """
        XCTAssertEqual(
            AgyPane.classify(permPane),
            .needsHuman(what: "swift test --filter PharosLightTests")
        )

        let trustPane = """
        Accessing workspace:
        /Users/x/dir
        Do you trust the contents of this project?
        > Yes, I trust this folder
          No, exit
        """
        XCTAssertEqual(AgyPane.classify(trustPane), .needsHuman(what: "trust folder"))
    }

    func testPaneClassifyUpdatePrompt() {
        let updatePane = """
        Update available · 0.162.1 → 0.166.0
        › 1. Update now (runs `brew upgrade --cask codex`)
          2. Skip
          3. Skip until next version
        """
        XCTAssertEqual(
            AgyPane.classify(updatePane),
            .needsHuman(what: "agy update prompt: choose Skip in tmux session")
        )

        let upgradePane = """
        Upgrade available · 1.0 → 2.0
        1. Upgrade now
        2. Skip
        """
        XCTAssertEqual(
            AgyPane.classify(upgradePane),
            .needsHuman(what: "agy update prompt: choose Skip in tmux session")
        )
    }

    func testPaneClassifyQuota() {
        let quotaPane = """
        > Reply with exactly: hi
        ⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 27h13m14s.
        Error ID: 364f1127-6067-4adc-b436-d5f18d60d4c5-1
        ────────
        >
        ────────
        ? for shortcuts                                         Gemini 4 Argon · low
        """
        let state = AgyPane.classify(quotaPane)
        if case .quota(let resetsIn) = state {
            XCTAssertEqual(resetsIn, 27 * 3600 + 13 * 60 + 14)
        } else {
            XCTFail("Expected .quota but got \(state)")
        }
    }

    func testPaneClassifyQuotaAbovePromptEchoIsNotQuota() {
        let paneWithOldQuota = """
        ⚠ Individual quota reached. Resets in 1h.
        > New prompt echo
        esc to cancel
        """
        // The quota line is ABOVE the last "> " prompt echo line, so it belongs to a past turn
        XCTAssertEqual(AgyPane.classify(paneWithOldQuota), .busy)
    }

    func testParseDuration() {
        XCTAssertEqual(AgyPane.parseDuration("27h59m2s"), 27 * 3600 + 59 * 60 + 2)
        XCTAssertEqual(AgyPane.parseDuration("5m"), 300)
        XCTAssertEqual(AgyPane.parseDuration("45s"), 45)
        XCTAssertEqual(AgyPane.parseDuration("1h"), 3600)
        XCTAssertEqual(AgyPane.parseDuration("27h13m14s."), 27 * 3600 + 13 * 60 + 14)
        XCTAssertNil(AgyPane.parseDuration("invalid"))
        XCTAssertNil(AgyPane.parseDuration(""))
        XCTAssertNil(AgyPane.parseDuration("123"))
    }

    // MARK: - CLIModelChain Tests

    func testQuotaBookMarkExpirePickEarliestResetAndPersist() {
        let storeURL = tempStoreURL()
        let clock = TestClock()

        let book = CLIQuotaBook(store: storeURL, now: { clock.now() })
        let chain = ["Gemini 3.8 Flash (High)", "Gemini 3.8 Flash (Medium)", "Gemini 3.8 Flash (Low)"]

        // Initially nothing is exhausted
        XCTAssertEqual(book.pick(app: "agy", chain: chain), "Gemini 3.8 Flash (High)")
        XCTAssertNil(book.earliestReset(app: "agy", chain: chain))

        // Mark High for 1 hour
        let resetHigh = clock.now().addingTimeInterval(3600)
        book.mark(app: "agy", model: "Gemini 3.8 Flash (High)", until: resetHigh)
        XCTAssertEqual(book.exhausted(app: "agy", model: "Gemini 3.8 Flash (High)"), resetHigh)

        // Now pick falls back to Medium
        XCTAssertEqual(book.pick(app: "agy", chain: chain), "Gemini 3.8 Flash (Medium)")
        XCTAssertEqual(book.earliestReset(app: "agy", chain: chain), resetHigh)

        // Mark Medium for 2 hours
        let resetMedium = clock.now().addingTimeInterval(7200)
        book.mark(app: "agy", model: "Gemini 3.8 Flash (Medium)", until: resetMedium)
        XCTAssertEqual(book.pick(app: "agy", chain: chain), "Gemini 3.8 Flash (Low)")
        XCTAssertEqual(book.earliestReset(app: "agy", chain: chain), resetHigh)

        // Mark Low for 3 hours -> all exhausted -> pick returns nil
        let resetLow = clock.now().addingTimeInterval(10800)
        book.mark(app: "agy", model: "Gemini 3.8 Flash (Low)", until: resetLow)
        XCTAssertNil(book.pick(app: "agy", chain: chain))
        XCTAssertEqual(book.earliestReset(app: "agy", chain: chain), resetHigh)

        // Verify persistence by loading from disk in a fresh instance
        let loadedBook = CLIQuotaBook(store: storeURL, now: { clock.now() })
        XCTAssertNil(loadedBook.pick(app: "agy", chain: chain))
        XCTAssertEqual(loadedBook.earliestReset(app: "agy", chain: chain), resetHigh)

        // Advance time past High's expiration (3601 seconds)
        clock.advance(3601)

        // High is no longer exhausted; Medium and Low still are
        XCTAssertNil(loadedBook.exhausted(app: "agy", model: "Gemini 3.8 Flash (High)"))
        XCTAssertNotNil(loadedBook.exhausted(app: "agy", model: "Gemini 3.8 Flash (Medium)"))
        XCTAssertEqual(loadedBook.pick(app: "agy", chain: chain), "Gemini 3.8 Flash (High)")
        XCTAssertEqual(loadedBook.earliestReset(app: "agy", chain: chain), resetMedium)
    }

    func testCLIModelChainsEnvOverride() {
        XCTAssertEqual(
            CLIModelChains.agyDefaultChain,
            ["Gemini 3.8 Flash (High)", "Gemini 3.8 Flash (Medium)", "Gemini 3.8 Flash (Low)"]
        )

        // Default when env is empty
        XCTAssertEqual(CLIModelChains.agy(env: [:]), CLIModelChains.agyDefaultChain)
        XCTAssertEqual(CLIModelChains.agy(env: ["PHAROS_AGY_MODELS": ""]), CLIModelChains.agyDefaultChain)

        // Overridden by env
        let custom = CLIModelChains.agy(env: ["PHAROS_AGY_MODELS": "custom-1, custom-2 ,custom-3"])
        XCTAssertEqual(custom, ["custom-1", "custom-2", "custom-3"])
    }
}
