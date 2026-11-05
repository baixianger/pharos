import XCTest
import SwiftUI
@testable import Pharos
@testable import PharosRuntime
@testable import PharosClientKit

final class ConversationDetailsTests: XCTestCase {

    // MARK: - 1. ANSI Strip Tests

    func testAnsiStripRemovesAllCsiOscAndGenericSequences() {
        // Plain text passes through unchanged
        XCTAssertEqual(AnsiTerminalParser.stripAnsi(from: "Hello world"), "Hello world")

        // CSI color & style codes stripped
        let csiText = "\u{001B}[31;1mError:\u{001B}[0m something went \u{001B}[4mwrong\u{001B}[24m!"
        XCTAssertEqual(AnsiTerminalParser.stripAnsi(from: csiText), "Error: something went wrong!")

        // 256 color & RGB sequences stripped
        let extended = "\u{001B}[38;5;196mRed 256\u{001B}[0m and \u{001B}[38;2;100;150;200mRGB\u{001B}[0m"
        XCTAssertEqual(AnsiTerminalParser.stripAnsi(from: extended), "Red 256 and RGB")

        // Multi-line ANSI buffer
        let multiline = "\u{001B}[1;36m[tmux]\u{001B}[0m session 0\n\u{001B}[2m$ cargo test\u{001B}[0m\n\u{001B}[32mPASS\u{001B}[0m"
        XCTAssertEqual(AnsiTerminalParser.stripAnsi(from: multiline), "[tmux] session 0\n$ cargo test\nPASS")
    }

    // MARK: - 2. ANSI Color Map & SGR Parsing Tests

    func testAnsiColorMapStandardBrightAnd256() {
        let parser = AnsiTerminalParser()

        // Test standard red + bold
        let redBold = "\u{001B}[1;31mAlert\u{001B}[0m Normal"
        let lines = parser.parse(text: redBold)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].segments.count, 2)

        let seg1 = lines[0].segments[0]
        XCTAssertEqual(seg1.text, "Alert")
        XCTAssertTrue(seg1.isBold)
        XCTAssertNotNil(seg1.foreground)

        let seg2 = lines[0].segments[1]
        XCTAssertEqual(seg2.text, " Normal")
        XCTAssertFalse(seg2.isBold)
        XCTAssertNil(seg2.foreground)

        // Test 24-bit RGB truecolor
        let rgbText = "\u{001B}[38;2;128;64;32mCustomColor\u{001B}[0m"
        let rgbLines = parser.parse(text: rgbText)
        XCTAssertEqual(rgbLines.count, 1)
        XCTAssertEqual(rgbLines[0].segments[0].text, "CustomColor")
        XCTAssertNotNil(rgbLines[0].segments[0].foreground)

        // Verify color palettes
        let greenStd = parser.standardColor(2, bright: false)
        let greenBright = parser.standardColor(2, bright: true)
        XCTAssertNotEqual(greenStd, greenBright)

        let colorCube = parser.color256(196) // bright red in 256 table
        XCTAssertNotNil(colorCube)
    }

    // MARK: - 3. Live Terminal View Model Tests

    @MainActor
    func testLiveTerminalViewModelBufferManagement() {
        let vm = LiveTerminalViewModel(
            tmuxSession: "pharos:test-pane",
            initialText: "Initial line\n"
        )

        XCTAssertEqual(vm.tmuxSession, "pharos:test-pane")
        XCTAssertTrue(vm.isStreaming)
        XCTAssertEqual(vm.lines.count, 2) // "Initial line" + blank after newline

        // Append more lines
        vm.appendOutput("\u{001B}[32mStep 1 completed\u{001B}[0m\n\u{001B}[34mStep 2 in progress...\u{001B}[0m\n")
        XCTAssertGreaterThanOrEqual(vm.lines.count, 3)

        // Pause toggle
        vm.togglePause()
        XCTAssertFalse(vm.isStreaming)
        vm.togglePause()
        XCTAssertTrue(vm.isStreaming)

        // Clear
        vm.clear()
        XCTAssertEqual(vm.lines.count, 0)
        XCTAssertEqual(vm.rawOutputBuffer, "")
    }

    // MARK: - 4. Model Mutation Command Generation Tests

    func testModelMutationCommandGeneration() async throws {
        // 1. Codex Adapter: Graceful restart fallback noted in capabilities
        let codexTransport = SimulatedCodexTransport()
        let codexAdapter = CodexBackendAdapter(transport: codexTransport)
        _ = try await codexAdapter.startSession(sessionId: "ses_cx", workspacePath: "/tmp", model: "gpt-4o", mode: "yolo")
        try await codexAdapter.selectSessionModel(sessionId: "ses_cx", model: "o1-mini")
        // Does not throw, handles gracefully

        // 2. Agy Adapter: ACP session/set_config_option hot swap
        let agyTransport = SimulatedAgyTransport()
        let agyAdapter = AgyBackendAdapter(transport: agyTransport)
        _ = try await agyAdapter.startSession(sessionId: "ses_ag", workspacePath: "/tmp", model: "gemini-2.5-pro", mode: "yolo")
        try await agyAdapter.selectSessionModel(sessionId: "ses_ag", model: "claude-3-7-sonnet")
        let lastMethod = agyTransport.sentRequests.last?["method"] as? String
        XCTAssertEqual(lastMethod, "session/set_config_option")

        // 3. Dsh Adapter: HTTP POST /api/session/selectModel
        let dshTransport = SimulatedDshTransport()
        let dshAdapter = DshBackendAdapter(port: 9999, token: "tok_test", transport: dshTransport)
        _ = try await dshAdapter.startSession(sessionId: "ses_ds", workspacePath: "/tmp", model: "deepseek-chat", mode: "yolo")
        try await dshAdapter.selectSessionModel(sessionId: "ses_ds", model: "deepseek-reasoner")
        // selectModel finishes without error
    }

    // MARK: - 5. Mode Mutation Command Generation & Execution Tests (DS-SES-12 Verification)

    func testModeMutationCommandGenerationAndExecution() async throws {
        // 1. Dsh Adapter: POST /api/commands/execute with /permission unrestricted vs ask (DS-SES-12)
        let dshTransport = SimulatedDshTransport()
        let dshAdapter = DshBackendAdapter(port: 9999, token: "tok_test", transport: dshTransport)
        _ = try await dshAdapter.startSession(sessionId: "ses_ds", workspacePath: "/tmp", model: nil, mode: nil)

        // Switch to YOLO -> sends /permission unrestricted
        try await dshAdapter.setSessionMode(sessionId: "ses_ds", mode: "yolo")
        XCTAssertEqual(dshTransport.lastExecutedCommand, "/permission unrestricted")

        // Switch to SAFE -> sends /permission ask
        try await dshAdapter.setSessionMode(sessionId: "ses_ds", mode: "safe")
        XCTAssertEqual(dshTransport.lastExecutedCommand, "/permission ask")

        // 2. Codex Adapter: thread/setApprovalPolicy with never vs on-request (CX-SES-12)
        let codexTransport = SimulatedCodexTransport()
        let codexAdapter = CodexBackendAdapter(transport: codexTransport)
        _ = try await codexAdapter.startSession(sessionId: "ses_cx", workspacePath: "/tmp", model: nil, mode: nil)
        try await codexAdapter.setSessionMode(sessionId: "ses_cx", mode: "yolo")
        // Verified: dispatches policy without error

        // 3. Agy Adapter: session/set_config_option permission_mode (AG-SES-12)
        let agyTransport = SimulatedAgyTransport()
        let agyAdapter = AgyBackendAdapter(transport: agyTransport)
        _ = try await agyAdapter.startSession(sessionId: "ses_ag", workspacePath: "/tmp", model: nil, mode: nil)
        try await agyAdapter.setSessionMode(sessionId: "ses_ag", mode: "yolo")
        let agyModeMethod = agyTransport.sentRequests.last?["method"] as? String
        XCTAssertEqual(agyModeMethod, "session/set_config_option")
    }

    // MARK: - 6. Session Library Artifact Navigation Tests

    func testSessionLibraryArtifactFilteringAndSearching() {
        let artifacts: [ClientSessionArtifact] = [
            ClientSessionArtifact(name: "patch1.patch", category: .patches, path: "patches/patch1.patch", sizeDescription: "+10/-2"),
            ClientSessionArtifact(name: "main.swift", category: .files, path: "Sources/main.swift", sizeDescription: "1.2 KB"),
            ClientSessionArtifact(name: "test.log", category: .outputs, path: "logs/test.log", sizeDescription: "100 lines"),
            ClientSessionArtifact(name: "image.png", category: .attachments, path: "assets/image.png", sizeDescription: "24 KB")
        ]

        XCTAssertEqual(artifacts.count, 4)
        XCTAssertEqual(artifacts.filter { $0.category == .patches }.count, 1)
        XCTAssertEqual(artifacts.filter { $0.category == .files }.count, 1)
        XCTAssertEqual(artifacts.filter { $0.category == .outputs }.count, 1)
        XCTAssertEqual(artifacts.filter { $0.category == .attachments }.count, 1)

        // Verify categories have icons and colors
        for category in ArtifactCategory.allCases {
            XCTAssertFalse(category.icon.isEmpty)
            XCTAssertNotNil(category.color)
        }
    }
}
