import Foundation
import PharosClientKit
import PharosMeshCore

/// Host-owned adapters for local CLI sessions. The desktop's SSH and peer
/// routing are intentionally absent from this service.
public actor HostLocalSessionService: PharosClientService, HostProjectCheckoutReporting {
    public typealias Inventory = @Sendable (String) async throws -> [LightSessionEntry]
    private let codex: LivePharosClientService
    private let dsh: DshLiveSessionService
    private let agy: AgyLiveSessionService
    private let inventory: Inventory
    private let projectCheckouts: @Sendable () async throws -> [UUID: String]
    private let machineID: String
    private var providerSessions: [String: [ClientSessionSummary]] = [:]
    private var inventoryIssues: [ClientSessionInventoryIssue] = []

    public init(codex: LivePharosClientService = .init(),
                dshHost: any DshSessionHosting = DshWebHost(),
                agyFactory: @escaping @Sendable () -> AgyAcpProcessTransport = { AgyAcpProcessTransport() },
                machineID: String = ProcessInfo.processInfo.hostName,
                projectCheckouts: @escaping @Sendable () async throws -> [UUID: String] = { try HostProjectCheckoutProvider.read() },
                inventory: @escaping Inventory = { kind in
                    try await Task.detached {
                        if kind == "dsh" {
                            return try SessionInventoryCollector.queryACP(bin: "/opt/homebrew/bin/dsh", timeout: 20,
                                                                           arguments: ["--profile", "acp"], app: "dsh")
                        }
                        return try SessionInventoryCollector.queryACP(bin: "/opt/homebrew/bin/agy", timeout: 15)
                    }.value
                }) {
        self.codex = codex
        self.machineID = machineID
        self.inventory = inventory
        self.projectCheckouts = projectCheckouts
        self.dsh = DshLiveSessionService(host: dshHost) { await codex.publishExternalEvent($0) }
        self.agy = AgyLiveSessionService(factory: agyFactory) { await codex.publishExternalEvent($0) }
    }

    public nonisolated func events() -> AsyncStream<PharosClientEvent> { codex.events() }

    public func fetchSessions() async throws -> [ClientSessionSummary] {
        try await fetchHostSessionInventorySnapshot().sessions
    }

    public func fetchHostSessionInventorySnapshot() async throws -> HostSessionInventorySnapshot {
        async let codexResult = Self.capture { try await self.codex.fetchSessions() }
        async let dshResult = Self.capture { try await self.inventory("dsh") }
        async let agyResult = Self.capture { try await self.inventory("agy") }
        let (codexValue, dshValue, agyValue) = await (codexResult, dshResult, agyResult)
        var issues: [ClientSessionInventoryIssue] = []
        var available = false
        var output: [ClientSessionSummary] = []
        switch codexValue {
        case .success(let entries): available = true; output += entries
        case .failure: issues.append(.init(host: machineID, agent: "Codex"))
        }
        for (kind, result) in [("dsh", dshValue), ("agy", agyValue)] {
            switch result {
            case .success(let entries):
                available = true
                let summaries = entries.map { entry in
                    let id = kind + ":" + entry.id
                    return ClientSessionSummary(sessionId: id, machineId: machineID, agentType: kind,
                        workspacePath: entry.cwd ?? "", title: entry.title ?? (kind == "dsh" ? "DeepSeek Harness" : "Antigravity"),
                        status: .unknown, updatedAt: entry.lastActive ?? .distantPast, avatarSeed: id)
                }
                providerSessions[kind] = summaries
                output += summaries
            case .failure:
                issues.append(.init(host: machineID, agent: kind == "dsh" ? "DSH" : "Antigravity"))
                output += (providerSessions[kind] ?? []).map { s in
                    ClientSessionSummary(sessionId: s.sessionId, machineId: s.machineId, agentType: s.agentType,
                        workspacePath: s.workspacePath, title: s.title, status: .unknown,
                        latestMessagePreview: s.latestMessagePreview, updatedAt: s.updatedAt,
                        avatarSeed: s.avatarSeed, rawVendorPayload: s.rawVendorPayload, inventoryStale: true)
                }
            }
        }
        inventoryIssues = issues
        guard available else { throw PharosClientError.backendUnreachable(backend: "host", reason: "All local agent inventories are unavailable") }
        return HostSessionInventorySnapshot(sessions: output.sorted { $0.updatedAt > $1.updatedAt }, status: inventoryStatus())
    }

    private static func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    public func fetchSessionInventoryIssues() async -> [ClientSessionInventoryIssue] { inventoryIssues }

    public func fetchHostProjectCheckouts() async throws -> [UUID: String] { try await projectCheckouts() }

    public func inventoryStatus() -> HostSessionInventoryStatus {
        HostSessionInventoryStatus(supportedAgents: ["codex", "dsh", "agy"],
            unavailableAgents: inventoryIssues.map { issue in
                switch issue.agent { case "Codex": "codex"; case "DSH": "dsh"; default: "agy" }
            })
    }

    private func agyID(_ sessionID: String) -> String? {
        sessionID.hasPrefix("agy:") ? String(sessionID.dropFirst(4)) : nil
    }
    private func dshID(_ sessionID: String) -> String? {
        sessionID.hasPrefix("dsh:") ? String(sessionID.dropFirst(4)) : nil
    }

    private func ensureAgy(_ sessionID: String, raw: String) async throws {
        if await agy.capabilities(sessionId: raw) != nil { return }
        guard let entry = providerSessions["agy"]?.first(where: { $0.id == sessionID }),
              !entry.workspacePath.isEmpty else {
            throw PharosClientError.operationFailed("Antigravity session workspace is unavailable")
        }
        _ = try await agy.load(sessionId: raw, workspace: entry.workspacePath)
    }

    public func fetchSessionHistory(sessionId: String) async throws -> [CanonicalTurn] {
        if let id = dshID(sessionId) { return try await dsh.history(sessionId: id) }
        if let id = agyID(sessionId) {
            guard let entry = providerSessions["agy"]?.first(where: { $0.id == sessionId }), !entry.workspacePath.isEmpty else {
                throw PharosClientError.operationFailed("Antigravity session workspace is unavailable")
            }
            return try await agy.load(sessionId: id, workspace: entry.workspacePath)
        }
        return try await codex.fetchSessionHistory(sessionId: sessionId)
    }

    public func fetchSessionProgress(sessionId: String) async throws -> CanonicalSessionProgress? {
        if let id = dshID(sessionId) { return await dsh.progress(sessionId: id) }
        if let id = agyID(sessionId) { return await agy.progress(sessionId: id) }
        return try await codex.fetchSessionProgress(sessionId: sessionId)
    }

    public func fetchSessionApproval(sessionId: String) async throws -> CanonicalApprovalRequest? {
        if let id = dshID(sessionId) { return await dsh.pendingApproval(sessionId: id) }
        if let id = agyID(sessionId) { return await agy.pendingApproval(sessionId: id) }
        return try await codex.fetchSessionApproval(sessionId: sessionId)
    }

    public func fetchSessionConfiguration(sessionId: String) async throws -> [JSONValue]? {
        if let id = dshID(sessionId) { return try await dsh.configuration(sessionId: id) }
        if let id = agyID(sessionId) {
            try await ensureAgy(sessionId, raw: id)
            return await agy.capabilities(sessionId: id)?.session["configOptions"]?.arrayValue
        }
        return try await codex.fetchSessionConfiguration(sessionId: sessionId)
    }

    public func supportsSessionTextAttachments(sessionId: String) async -> Bool {
        if let id = agyID(sessionId) { return await agy.supportsEmbeddedText(sessionId: id) }
        return false
    }

    public func setSessionConfiguration(sessionId: String, configId: String, value: String) async throws -> [JSONValue] {
        if let id = dshID(sessionId) {
            if configId == "dsh-permission" { return try await dsh.setPermissionConfiguration(sessionId: id, value: value) }
            if configId == "dsh-model" {
                _ = try await dsh.setModelConfiguration(sessionId: id, value: value)
                return try await dsh.configuration(sessionId: id) ?? []
            }
            throw PharosClientError.operationFailed("DSH configuration option is unavailable")
        }
        if let id = agyID(sessionId) {
            try await ensureAgy(sessionId, raw: id)
            let result = try await agy.setConfiguration(sessionId: id, configId: configId, value: value)
            guard let options = result.session["configOptions"]?.arrayValue else {
                throw PharosClientError.operationFailed("Antigravity did not return Session configuration")
            }
            return options
        }
        return try await codex.setSessionConfiguration(sessionId: sessionId, configId: configId, value: value)
    }

    public func executeSessionCommand(sessionId: String, line: String) async throws -> SessionCommandResult? {
        if let id = dshID(sessionId) { return try await dsh.executeCommand(sessionId: id, line: line) }
        if agyID(sessionId) != nil { return nil }
        return try await codex.executeSessionCommand(sessionId: sessionId, line: line)
    }

    public func sendSessionMessage(sessionId: String, text: String) async throws -> CanonicalTurn {
        try await sendSessionMessage(sessionId: sessionId, text: text, files: [], requestId: UUID().uuidString)
    }

    public func sendSessionMessage(sessionId: String, text: String, files: [SessionFileUpload], requestId: String) async throws -> CanonicalTurn {
        if let id = dshID(sessionId) {
            var staged: [DshStagedFile] = []
            for file in files { staged.append(try await dsh.stageFile(sessionId: id, data: file.data, name: file.name)) }
            return try await dsh.send(sessionId: id, text: text, files: staged, requestId: requestId)
        }
        if let id = agyID(sessionId) {
            try await ensureAgy(sessionId, raw: id)
            // ACP responds only when a turn finishes. Holding the peer RPC
            // open prevents later approval requests on currently serial MeshKit
            // streams, so text returns an in-progress turn immediately.
            if !files.isEmpty { return try await agy.beginEmbeddedText(sessionId: id, text: text, files: files, turnID: requestId) }
            return try await agy.send(sessionId: id, text: text, turnID: requestId)
        }
        return try await codex.sendSessionMessage(sessionId: sessionId, text: text, files: files, requestId: requestId)
    }

    public func steerSession(sessionId: String, text: String) async throws {
        if let id = dshID(sessionId) { try await dsh.steer(sessionId: id, text: text); return }
        guard agyID(sessionId) == nil else { throw PharosClientError.operationFailed("Antigravity session steering is not connected") }
        try await codex.steerSession(sessionId: sessionId, text: text)
    }

    public func resolveSessionApproval(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws {
        if let id = dshID(sessionId) { try await dsh.resolve(sessionId: id, approvalId: approvalId, decision: decision); return }
        if let id = agyID(sessionId) { try await agy.resolve(sessionId: id, approvalId: approvalId, decision: decision); return }
        try await codex.resolveSessionApproval(sessionId: sessionId, approvalId: approvalId, decision: decision)
    }

    public func fetchThreads() async throws -> [ClientThreadSummary] { [] }
    public func fetchProjects() async throws -> [ClientProjectSummary] { [] }
    public func fetchThreadMessages(threadId: String) async throws -> [ClientThreadMessage] { throw PharosClientError.threadNotFound(threadId) }
    public func fetchMemberDetail(name: String) async throws -> ClientMemberDetail { throw PharosClientError.operationFailed("Member details unavailable") }
    public func sendThreadMessage(threadId: String, text: String) async throws -> ClientThreadMessage { throw PharosClientError.threadNotFound(threadId) }
    public func setMemberMode(name: String, mode: String) async throws { throw PharosClientError.operationFailed("Member controls unavailable") }
    public func setMemberModel(name: String, model: String) async throws { throw PharosClientError.operationFailed("Member controls unavailable") }
    public func setMemberAvatar(name: String, avatar: ClientAvatarInfo) async throws { throw PharosClientError.operationFailed("Member controls unavailable") }
    public func stopMember(name: String) async throws { throw PharosClientError.operationFailed("Member controls unavailable") }
    public func reviveMember(name: String) async throws { throw PharosClientError.operationFailed("Member controls unavailable") }
}
