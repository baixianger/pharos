import XCTest
import Foundation
import PharosClientKit
@testable import Pharos

/// Pure mappings from the ClientKit wave-2 views to the `WorkspaceWebState`
/// contract rendered by `webui/workspace.js`.
final class WorkspaceStateMappingTests: XCTestCase {
    private func configuration(
        supportedFields: [String] = ["model", "mode"],
        model: String? = "gpt-5",
        mode: String? = "safe",
        models: [String] = ["gpt-5", "gpt-6"],
        modes: [ClientSessionConfiguration.Mode] = [
            .init(value: "safe", name: "Safe"),
            .init(value: "yolo", name: "YOLO"),
        ],
        capabilities: ClientSessionConfiguration.Capabilities = .init(
            attachments: true, commands: false, stop: true, revive: false
        ),
        readonly: Bool = false
    ) -> ClientSessionConfiguration {
        ClientSessionConfiguration(
            sessionId: "s1",
            supported: true,
            supportedFields: supportedFields,
            model: model,
            mode: mode,
            models: models,
            modes: modes,
            capabilities: capabilities,
            readonly: readonly
        )
    }

    // MARK: - Configuration -> composer controls

    func testSupportedConfigurationMapsToModelAndModeSelects() {
        let controls = WorkspaceWebState.sessionConfigurationControls(configuration: configuration())
        XCTAssertEqual(controls, [
            .select(
                id: "model", name: "Model", currentValue: "gpt-5",
                options: [
                    .init(value: "gpt-5", name: "gpt-5"),
                    .init(value: "gpt-6", name: "gpt-6"),
                ],
                readOnly: false
            ),
            .select(
                id: "mode", name: "Mode", currentValue: "safe",
                options: [
                    .init(value: "safe", name: "Safe"),
                    .init(value: "yolo", name: "YOLO"),
                ],
                readOnly: false
            ),
        ])
    }

    func testUnsupportedConfigurationReportsTheHonestNotice() {
        let unsupported = ClientSessionConfiguration(sessionId: "s1", supported: false)
        XCTAssertEqual(
            WorkspaceWebState.sessionConfigurationControls(configuration: unsupported),
            [.status(name: "Configuration unavailable")]
        )
    }

    func testNoConfigurationAndNoFailurePublishesNoNotice() {
        XCTAssertEqual(
            WorkspaceWebState.sessionConfigurationControls(configuration: nil),
            [],
            "nothing selected / not loaded yet must not claim the configuration is unavailable"
        )
    }

    func testFailedConfigurationFetchReportsTheHonestNotice() {
        XCTAssertEqual(
            WorkspaceWebState.sessionConfigurationControls(configuration: nil, configurationLoadFailed: true),
            [.status(name: "Configuration unavailable")]
        )
    }

    func testReadOnlyAndUnsupportedFieldsDisableTheSelects() {
        let partial = configuration(supportedFields: ["model"], readonly: false)
        let controls = WorkspaceWebState.sessionConfigurationControls(configuration: partial)
        guard case let .select(modelId, _, _, _, modelReadOnly) = controls[0],
              case let .select(modeId, _, _, _, modeReadOnly) = controls[1] else {
            return XCTFail("expected two selects, got \(controls)")
        }
        XCTAssertEqual(modelId, "model")
        XCTAssertFalse(modelReadOnly, "a supported field without the readonly flag stays editable")
        XCTAssertEqual(modeId, "mode")
        XCTAssertTrue(modeReadOnly, "a field outside supportedFields is view-only")

        let readonly = WorkspaceWebState.sessionConfigurationControls(
            configuration: configuration(readonly: true)
        )
        XCTAssertEqual(readonly.count, 2)
        for control in readonly {
            guard case let .select(_, _, _, _, isReadOnly) = control else {
                return XCTFail("expected selects, got \(control)")
            }
            XCTAssertTrue(isReadOnly)
        }
    }

    func testControlsEncodeTheJavaScriptContract() throws {
        let controls = WorkspaceWebState.sessionConfigurationControls(configuration: configuration())
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(controls))
        let rows = try XCTUnwrap(encoded as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)

        XCTAssertEqual(rows[0]["type"] as? String, "select")
        XCTAssertEqual(rows[0]["id"] as? String, "model")
        XCTAssertEqual(rows[0]["name"] as? String, "Model")
        XCTAssertEqual(rows[0]["currentValue"] as? String, "gpt-5")
        XCTAssertEqual(rows[0]["readOnly"] as? Bool, false)
        let options = try XCTUnwrap(rows[0]["options"] as? [[String: Any]])
        XCTAssertEqual(options.map { $0["value"] as? String }, ["gpt-5", "gpt-6"])
        XCTAssertEqual(options.map { $0["name"] as? String }, ["gpt-5", "gpt-6"])

        XCTAssertEqual(rows[1]["id"] as? String, "mode")
        let modeOptions = try XCTUnwrap(rows[1]["options"] as? [[String: Any]])
        XCTAssertEqual(modeOptions.map { $0["value"] as? String }, ["safe", "yolo"])
        XCTAssertEqual(modeOptions.map { $0["name"] as? String }, ["Safe", "YOLO"])

        let status = WorkspaceWebState.sessionConfigurationControls(
            configuration: ClientSessionConfiguration(sessionId: "s1", supported: false)
        )
        let statusRows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [[String: Any]]
        )
        XCTAssertEqual(statusRows.count, 1)
        XCTAssertEqual(statusRows[0]["type"] as? String, "status")
        XCTAssertEqual(statusRows[0]["name"] as? String, "Configuration unavailable")
        XCTAssertEqual(Set(statusRows[0].keys), ["type", "name"], "status controls carry no select fields")
    }

    // MARK: - Configuration -> capability gates

    func testCapabilitiesComeFromTheConfigurationView() {
        let capabilities = WorkspaceWebState.capabilities(from: configuration())
        XCTAssertEqual(capabilities, [
            "attachments": true,
            "commands": false,
            "stop": true,
            "revive": false,
        ])
    }

    func testUnknownCapabilitiesAreTheEmptyMap() {
        XCTAssertEqual(
            WorkspaceWebState.capabilities(from: nil),
            [:],
            "unknown capabilities must disable gated controls, not enable them"
        )
    }

    // MARK: - Session details

    func testDetailsMapConfigurationAndSessionSummary() {
        let session = ClientSessionSummary(
            sessionId: "s1",
            machineId: "mini",
            agentType: "codex",
            workspacePath: "/tmp/project",
            title: "Fix the parser",
            status: .working,
            avatarSeed: "s1"
        )
        let details = WorkspaceWebState.details(for: session, configuration: configuration())
        XCTAssertEqual(details.sessionID, "s1")
        XCTAssertEqual(details.agent, "codex")
        XCTAssertEqual(details.host, "mini")
        XCTAssertEqual(details.status, "working")
        XCTAssertEqual(details.workspace, "/tmp/project")
        XCTAssertEqual(details.model, "gpt-5")
        XCTAssertEqual(details.mode, "safe")
        XCTAssertEqual(details.models, ["gpt-5", "gpt-6"])
    }

    func testDetailsWithoutConfigurationNeverInventModelOrMode() {
        let session = ClientSessionSummary(
            sessionId: "s2",
            machineId: "air",
            agentType: "dsh",
            workspacePath: "/tmp/other",
            title: "Other",
            status: .idle,
            avatarSeed: "s2"
        )
        let details = WorkspaceWebState.details(for: session, configuration: nil)
        XCTAssertEqual(details.model, "")
        XCTAssertEqual(details.mode, "")
        XCTAssertEqual(details.models, [])
        XCTAssertEqual(details.status, "idle")
    }

    // MARK: - Backend health guidance

    func testBackgroundErrorPrefersWrongServiceGuidance() {
        let baseURL = URL(string: "http://127.0.0.1:8787")!
        let message = WorkspaceWebState.backgroundError(
            PharosClientError.connectionFailed("Could not connect to the server."),
            baseURL: baseURL,
            probe: .reachable(
                BackendHealth(ok: true, contractsVersion: "0.1.0", service: "linked-demo")
            )
        )
        XCTAssertTrue(message.contains("http://127.0.0.1:8787"), "the tried URL is named")
        XCTAssertTrue(message.contains("linked-demo"), "the wrong service is named")
        XCTAssertTrue(message.contains("not Pharos"), "the diagnosis is explicit")
        XCTAssertTrue(message.contains("PHAROS_API_BASE_URL"), "the override is suggested")
    }

    func testBackgroundErrorNamesUnreachableEndpointAndOverride() {
        let baseURL = URL(string: "http://127.0.0.1:8787")!
        let message = WorkspaceWebState.backgroundError(
            PharosClientError.connectionFailed("Could not connect to the server."),
            baseURL: baseURL,
            probe: .unreachable(reason: "Connection refused")
        )
        XCTAssertTrue(message.contains("No Pharos backend answered"))
        XCTAssertTrue(message.contains("http://127.0.0.1:8787"))
        XCTAssertTrue(message.contains("PHAROS_API_BASE_URL"))
    }

    func testBackgroundErrorFallsBackToThePlainErrorWhenTheBackendIsHealthy() {
        let baseURL = URL(string: "http://127.0.0.1:8787")!
        let message = WorkspaceWebState.backgroundError(
            PharosClientError.connectionFailed("Could not connect to the server."),
            baseURL: baseURL,
            probe: .reachable(
                BackendHealth(
                    ok: true,
                    contractsVersion: PharosAPIConfiguration.contractsVersion,
                    service: "pharos-web"
                )
            )
        )
        XCTAssertEqual(message, "Could not connect to the server.")
        XCTAssertFalse(message.contains("PHAROS_API_BASE_URL"))
    }

    func testErrorDescriptionMapping() {
        XCTAssertEqual(
            WorkspaceWebState.describe(PharosClientError.backendUnreachable(backend: "pharos-web", reason: "restarted")),
            "pharos-web is unavailable. restarted"
        )
        XCTAssertEqual(
            WorkspaceWebState.describe(PharosClientError.operationFailed("Adapter cannot change mode")),
            "Adapter cannot change mode"
        )
        XCTAssertEqual(WorkspaceWebState.describe(PharosClientError.sessionNotFound("s1")), "Session not found.")
        XCTAssertEqual(WorkspaceWebState.describe(PharosClientError.threadNotFound("t1")), "Thread not found.")
        XCTAssertEqual(
            WorkspaceWebState.describe(PharosClientError.approvalNotFound("a1")),
            "This approval is no longer active."
        )
    }
}

/// A backend without `GET /threads/{id}/members` (older Rust daemon) must keep
/// the roster working through the per-member settings fallback.
@MainActor
final class ThreadRosterFallbackTests: XCTestCase {
    private struct ThreadMembersUnavailableService: PharosClientService {
        let base: MockPharosClientService

        func fetchSessions() async throws -> [ClientSessionSummary] { try await base.fetchSessions() }
        func fetchThreads() async throws -> [ClientThreadSummary] { try await base.fetchThreads() }
        func fetchProjects() async throws -> [ClientProjectSummary] { try await base.fetchProjects() }
        func fetchSessionHistory(sessionId: String) async throws -> [CanonicalTurn] {
            try await base.fetchSessionHistory(sessionId: sessionId)
        }
        func fetchThreadMessages(threadId: String) async throws -> [ClientThreadMessage] {
            try await base.fetchThreadMessages(threadId: threadId)
        }
        func fetchMemberDetail(name: String) async throws -> ClientMemberDetail {
            try await base.fetchMemberDetail(name: name)
        }
        func fetchThreadMembers(threadId: String) async throws -> [ClientMemberDetail] {
            throw PharosClientError.operationFailed("Thread members are unavailable")
        }
        func sendSessionMessage(sessionId: String, text: String) async throws -> CanonicalTurn {
            try await base.sendSessionMessage(sessionId: sessionId, text: text)
        }
        func steerSession(sessionId: String, text: String) async throws {
            try await base.steerSession(sessionId: sessionId, text: text)
        }
        func resolveSessionApproval(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws {
            try await base.resolveSessionApproval(sessionId: sessionId, approvalId: approvalId, decision: decision)
        }
        func sendThreadMessage(threadId: String, text: String) async throws -> ClientThreadMessage {
            try await base.sendThreadMessage(threadId: threadId, text: text)
        }
        func setMemberMode(name: String, mode: String) async throws {
            try await base.setMemberMode(name: name, mode: mode)
        }
        func setMemberModel(name: String, model: String) async throws {
            try await base.setMemberModel(name: name, model: model)
        }
        func setMemberAvatar(name: String, avatar: ClientAvatarInfo) async throws {
            try await base.setMemberAvatar(name: name, avatar: avatar)
        }
        func stopMember(name: String) async throws { try await base.stopMember(name: name) }
        func reviveMember(name: String) async throws { try await base.reviveMember(name: name) }
        nonisolated func events() -> AsyncStream<PharosClientEvent> { base.events() }
    }

    func testRosterFallsBackWhenTheThreadMembersRouteIsUnavailable() async {
        let thread = ClientThreadSummary(threadId: "room_fallback", title: "Fallback", memberIds: ["bot"])
        let member = ClientMemberDetail(
            name: "bot", agent: "codex", machine: "mini", model: "", mode: "",
            status: "idle", avatarSeed: "bot_seed"
        )
        let service = ThreadMembersUnavailableService(
            base: MockPharosClientService(threads: [thread], members: ["bot": member])
        )
        let viewModel = ThreadConversationViewModel(threadId: "room_fallback", clientService: service)

        await viewModel.loadThreadData()

        XCTAssertEqual(viewModel.rosterMembers.map(\.name), ["bot"], "fallback roster keeps the member")
        XCTAssertEqual(viewModel.rosterMembers.first?.agent, "codex")
        XCTAssertEqual(viewModel.rosterMembers.first?.machine, "mini")
        XCTAssertNil(viewModel.activeError, "the missing route degrades gracefully, it is not a user-facing failure")
    }
}
