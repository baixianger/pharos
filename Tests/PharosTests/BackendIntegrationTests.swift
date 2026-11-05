import XCTest
import Foundation
import PharosClientKit
@testable import PharosRuntime

/// Integration tests against real local backend processes, strictly gated by environment variables
/// and restricted to isolated testing directories in `~/personal/pharos-msg-test/`.
///
/// SAFETY INVARIANTS:
/// 1. Default to skipped when env var is not set to "1".
/// 2. Workspace strictly restricted to `~/personal/pharos-msg-test/<subdir>`.
/// 3. STRICTLY PROHIBITED from touching port 3080, `ipc.sock`, or live user application state.
final class BackendIntegrationTests: XCTestCase {

    private let testBaseDir = ("~/personal/pharos-msg-test" as NSString).expandingTildeInPath

    // MARK: - 1. Real Codex Daemon Integration Test

    func testCodexRealDaemonIntegration() async throws {
        guard ProcessInfo.processInfo.environment["PHAROS_CODEX_INTEGRATION_TEST"] == "1" else {
            throw XCTSkip("Skipping real Codex daemon integration test. Set PHAROS_CODEX_INTEGRATION_TEST=1 to enable.")
        }

        let socketPath = CodexDaemonClient.socketPath()
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw XCTSkip("Codex daemon socket not found at \(socketPath). Start codex daemon first.")
        }

        let workspace = URL(fileURLWithPath: testBaseDir).appendingPathComponent("codex-exp1").path
        guard FileManager.default.fileExists(atPath: workspace) else {
            throw XCTSkip("Workspace \(workspace) does not exist.")
        }

        let transport = CodexDaemonUdsTransport(socketPath: socketPath)
        let adapter = CodexBackendAdapter(socketPath: socketPath, transport: transport)
        defer { transport.close() }

        let sessionId = "ses_int_test_cx_\(UUID().uuidString.prefix(6))"
        let turn = try await adapter.startSession(
            sessionId: sessionId,
            workspacePath: workspace,
            model: nil,
            mode: "prompt"
        )

        XCTAssertFalse(turn.turnId.isEmpty)
        XCTAssertEqual(turn.sessionId, sessionId)
        XCTAssertEqual(turn.turnNumber, 1)

        // Cleanly interrupt session
        try await adapter.interruptSession(sessionId: sessionId)
    }

    // MARK: - 2. Real Antigravity ACP Integration Test

    func testAgyRealAcpProcessIntegration() async throws {
        guard ProcessInfo.processInfo.environment["PHAROS_AGY_INTEGRATION_TEST"] == "1" else {
            throw XCTSkip("Skipping real Antigravity ACP integration test. Set PHAROS_AGY_INTEGRATION_TEST=1 to enable.")
        }

        let agyPath = "/opt/homebrew/bin/agy"
        guard FileManager.default.fileExists(atPath: agyPath) else {
            throw XCTSkip("agy executable not found at \(agyPath).")
        }

        let workspace = URL(fileURLWithPath: testBaseDir).appendingPathComponent("agy-exp1").path
        guard FileManager.default.fileExists(atPath: workspace) else {
            throw XCTSkip("Workspace \(workspace) does not exist.")
        }

        let transport = AgyAcpProcessTransport()
        let adapter = AgyBackendAdapter(transport: transport)
        defer { transport.close() }

        let sessionId = "ses_int_test_agy_\(UUID().uuidString.prefix(6))"
        let turn = try await adapter.startSession(
            sessionId: sessionId,
            workspacePath: workspace,
            model: "gemini-2.5-pro",
            mode: "prompt"
        )

        XCTAssertFalse(turn.turnId.isEmpty)
        XCTAssertEqual(turn.sessionId, sessionId)
        XCTAssertEqual(turn.turnNumber, 1)
    }

    // MARK: - 3. Real DeepSeek Harness Web Host Integration Test

    func testDshRealWebHostIntegration() async throws {
        guard ProcessInfo.processInfo.environment["PHAROS_DSH_INTEGRATION_TEST"] == "1" else {
            throw XCTSkip("Skipping real DeepSeek Harness web host integration test. Set PHAROS_DSH_INTEGRATION_TEST=1 to enable.")
        }

        let env = ProcessInfo.processInfo.environment
        guard let portStr = env["PHAROS_DSH_TEST_PORT"],
              let port = Int(portStr),
              let token = env["PHAROS_DSH_TEST_TOKEN"],
              !token.isEmpty else {
            throw XCTSkip("Set PHAROS_DSH_TEST_PORT and PHAROS_DSH_TEST_TOKEN for dedicated test dsh web host.")
        }

        // STRICT SAFETY CHECK: Port 3080 is NEVER allowed!
        guard port != 3080 else {
            XCTFail("STRICT SAFETY VIOLATION: Port 3080 is reserved for production dsh Host and is forbidden in tests.")
            return
        }

        let transport = DshWebHttpWsTransport()
        let adapter = DshBackendAdapter(port: port, token: token, transport: transport)
        defer { transport.close() }

        let workspace = URL(fileURLWithPath: testBaseDir).appendingPathComponent("dsh-exp1").path
        let sessionId = "ses_int_test_dsh_\(UUID().uuidString.prefix(6))"

        let turn = try await adapter.startSession(
            sessionId: sessionId,
            workspacePath: workspace,
            model: "deepseek-coder",
            mode: "prompt"
        )

        XCTAssertFalse(turn.turnId.isEmpty)
        XCTAssertEqual(turn.sessionId, sessionId)
    }
}
