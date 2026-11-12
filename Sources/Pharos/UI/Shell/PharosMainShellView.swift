import SwiftUI
import PharosClientKit

/// Native owner of workspace selection and actions. WebKit renders the view state.
public struct PharosMainShellView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings
    @State private var selectedTab: NavigationTab = .sessions
    @State private var selectedSessionId: String?
    @State private var selectedThreadId: String?
    @State private var selectedProjectId: String?

    @State private var sessions: [ClientSessionSummary] = []
    @State private var inventoryIssues: [ClientSessionInventoryIssue] = []
    @State private var threads: [ClientThreadSummary] = []
    @State private var projects: [ClientProjectSummary] = []
    @State private var session: SessionConversationViewModel?
    @State private var thread: ThreadConversationViewModel?
    @State private var rosterMembers: [String: ClientMemberDetail] = [:]
    @AppStorage("pharos.workspaceAvatarOverrides", store: PharosPrefs.shared) private var avatarOverrides = Data()
    /// Persisted human identity (`GET /api/v1/members/human`): the row-identity
    /// fallback whenever no per-row override exists.
    @State private var humanIdentity: WorkspaceWebState.Avatar?
    @State private var actionError: String?
    /// Actionable guidance for a failed background load (wrong local app on the
    /// default port, stale process, contract mismatch). Kept separate from
    /// action errors so a recovery poll cannot erase an action failure.
    @State private var backgroundError: String?
    @State private var submissionResults: [String: WorkspaceWebState.SubmissionResult] = [:]
    @State private var canBindThreadSession = false
    @State private var threadBindingInFlight = false

    public let clientService: PharosClientService
    var onAddProject: () -> Void = {}

    public init(clientService: PharosClientService = HttpPharosClientService()) {
        self.clientService = clientService
    }

    init(onAddProject: @escaping () -> Void) {
        self.init()
        self.onAddProject = onAddProject
    }

    init(clientService: PharosClientService, onAddProject: @escaping () -> Void) {
        self.init(clientService: clientService)
        self.onAddProject = onAddProject
    }

    public var body: some View {
        WorkspaceWebView(state: webState, onAction: handleAction)
            .ignoresSafeArea(.container, edges: .top)
            .frame(minWidth: PharosDesignTokens.Layout.minWindowWidth,
                   minHeight: PharosDesignTokens.Layout.minWindowHeight)
            .task {
                while !Task.isCancelled {
                    do {
                        sessions = try await clientService.fetchSessions()
                        backgroundError = nil
                    } catch { backgroundError = await backgroundErrorText(error) }
                    canBindThreadSession = await clientService.supportsThreadSessionBinding()
                    inventoryIssues = await clientService.fetchSessionInventoryIssues()
                    if selectedSessionId == nil { selectedSessionId = sessions.first?.id }
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .task {
                while !Task.isCancelled {
                    do {
                        threads = try await clientService.fetchThreads()
                        backgroundError = nil
                    } catch { backgroundError = await backgroundErrorText(error) }
                    if selectedThreadId == nil { selectedThreadId = threads.first?.id }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .task {
                while !Task.isCancelled {
                    do {
                        projects = try await clientService.fetchProjects()
                        backgroundError = nil
                    } catch { backgroundError = await backgroundErrorText(error) }
                    if selectedProjectId == nil { selectedProjectId = projects.first?.id }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .task { await loadHumanIdentity() }
            .task(id: selectedSessionId) { await loadSession() }
            .task(id: selectedThreadId) { await loadThread() }
            .task(id: rosterMemberIDs) { await loadRosterMembers() }
    }

    private var tabID: String { selectedTab.rawValue.lowercased() }

    private var selection: String? {
        switch selectedTab {
        case .sessions: selectedSessionId
        case .threads: selectedThreadId
        case .projects: selectedProjectId
        }
    }

    private func avatarKey(id: String) -> String { tabID + ":" + id }

    private var avatars: [String: WorkspaceWebState.Avatar] {
        (try? JSONDecoder().decode([String: WorkspaceWebState.Avatar].self, from: avatarOverrides)) ?? [:]
    }

    private var rows: [WorkspaceWebState.Row] {
        let overrides = avatars
        let fallbackIdentity = humanIdentity
        func row(id: String, title: String, subtitle: String, seed: String, legacyID: String? = nil) -> WorkspaceWebState.Row {
            let identity = overrides[avatarKey(id: id)]
                ?? legacyID.flatMap { overrides[avatarKey(id: $0)] }
                ?? fallbackIdentity
                ?? .init(seed: seed)
            return .init(id: id, title: title, subtitle: subtitle, identity: identity)
        }
        switch selectedTab {
        case .sessions:
            return sessions.map { session in
                let status = session.inventoryStale == true ? "Inventory unavailable · last known" : (session.latestMessagePreview ?? session.agentType)
                let subtitle = session.connectionRoute.map { "\($0.uppercased()) · \(status)" } ?? status
                return row(id: session.id, title: session.title, subtitle: subtitle, seed: session.avatarSeed)
            }
        case .threads:
            return threads.map { thread in
                let members = ThreadConversationViewModel.visibleAgentIDs(in: thread).map { id in
                    let member = rosterMembers[id]
                    return WorkspaceWebState.RosterAvatar(id: id, name: member?.displayName ?? member?.name ?? id,
                                                          identity: rosterIdentity(for: member, seed: member?.avatarSeed ?? id))
                }
                var result = row(id: thread.id, title: thread.title,
                                 subtitle: "\(members.count) \(members.count == 1 ? "member" : "members")", seed: thread.id)
                result.members = members
                return result
            }
        case .projects:
            return projects.map { row(id: $0.id, title: $0.name,
                                      subtitle: $0.relatedSessionIds.map { "\($0.count) discovered sessions" } ?? "Loading sessions…",
                                      seed: $0.id, legacyID: $0.projectPath.isEmpty ? nil : $0.projectPath) }
        }
    }

    /// Persisted member avatar settings win over the seeded identity, so a
    /// roster avatar the user customised renders the same everywhere.
    private func rosterIdentity(for member: ClientMemberDetail?, seed: String) -> WorkspaceWebState.Avatar {
        if let shape = member?.avatarShape, let color = member?.avatarColor,
           WorkspaceWebState.Avatar.shapes.contains(shape),
           WorkspaceWebState.Avatar.colors.contains(color) {
            return .init(shape: shape, color: color)
        }
        return .init(seed: seed)
    }

    private var activeSession: ClientSessionSummary? { sessions.first { $0.id == selectedSessionId } }

    private var rosterMemberIDs: [String] {
        guard selectedTab == .threads else { return [] }
        return Set(threads.flatMap { ThreadConversationViewModel.visibleAgentIDs(in: $0) }).sorted()
    }

    private func loadRosterMembers() async {
        var loaded = rosterMembers
        for id in rosterMemberIDs {
            guard !Task.isCancelled else { return }
            if let detail = try? await clientService.fetchMemberDetail(name: id) { loaded[id] = detail }
        }
        if !Task.isCancelled { rosterMembers = loaded }
    }

    private var details: WorkspaceWebState.Details? {
        if selectedTab == .projects, let project = projects.first(where: { $0.id == selectedProjectId }) {
            return .init(workspace: project.projectPath.hasPrefix("/") ? project.projectPath : "")
        }
        guard selectedTab == .sessions, let activeSession else { return nil }
        let configuration = session?.sessionId == activeSession.id ? session?.configuration : nil
        return WorkspaceWebState.details(for: activeSession, configuration: configuration)
    }

    private var webState: WorkspaceWebState {
        let rows = rows
        let row = rows.first { $0.id == selection }
        let sessionViewModel = selectedTab == .sessions && session?.sessionId == selection ? session : nil
        let activeThread = selectedTab == .threads && thread?.threadId == selection ? thread : nil
        let selectedProject = selectedTab == .projects ? projects.first(where: { $0.id == selection }) : nil
        let projectSessionIDs = Set(selectedProject?.relatedSessionIds ?? [])
        let configuration = sessionViewModel?.configuration
        let activity = switch (sessionViewModel?.activeApproval != nil, sessionViewModel?.isTurnInProgress == true) {
        case (true, _): "waiting"
        case (_, true): "working"
        default: "idle"
        }
        return WorkspaceWebState(
            tab: tabID, selection: selection, title: row?.title ?? selectedTab.rawValue,
            theme: colorScheme == .dark ? "dark" : "light", rows: rows,
            identity: row?.identity ?? humanIdentity ?? .init(shape: "sphere", color: "black"), activity: activity,
            canSend: selectedTab == .sessions ? (sessionViewModel != nil && sessionViewModel?.isLoadingHistory == false) : (selectedTab == .threads && activeThread != nil),
            detail: details,
            turns: sessionViewModel?.turns ?? [], streamingText: sessionViewModel?.liveStreamingText ?? "",
            reasoningText: sessionViewModel?.liveReasoningText ?? "", tools: sessionViewModel?.liveTools ?? [],
            approval: sessionViewModel?.activeApproval, goal: sessionViewModel?.goal, todos: sessionViewModel?.todos ?? [],
            // A notice is only honest when a Session is actually selected; an
            // empty workspace publishes no configuration controls at all.
            sessionConfiguration: selectedTab == .sessions && sessionViewModel != nil
                ? WorkspaceWebState.sessionConfigurationControls(
                    configuration: configuration,
                    configurationLoadFailed: sessionViewModel?.configurationLoadFailed ?? false)
                : [],
            capabilities: WorkspaceWebState.capabilities(from: configuration),
            supportsTextAttachments: configuration?.capabilities.attachments == true,
            configurationInFlight: sessionViewModel?.configurationInFlight ?? false,
            inventoryIssues: inventoryIssues, commandResult: sessionViewModel?.commandResult, submissionResults: submissionResults,
            projectSessions: sessions.filter { projectSessionIDs.contains($0.id) }.map(WorkspaceWebState.ProjectSession.init),
            projectInventoryLoaded: selectedProject?.relatedSessionIds != nil,
            projectHosts: selectedProject?.trackedDevices ?? [],
            projectCheckoutUnavailableHosts: selectedProject?.checkoutUnavailableHosts ?? [],
            canBindThreadSession: selectedTab == .threads && canBindThreadSession,
            threadBindingInFlight: threadBindingInFlight,
            // Every Session is a valid PUT target for a Thread binding.
            threadBindingCandidates: sessions.map(WorkspaceWebState.ProjectSession.init),
            messages: activeThread?.messages ?? [],
            members: activeThread?.rosterMembers ?? [],
            // A background navigation error must not hide a failed prompt or
            // command in the conversation the user is actively working in.
            error: (sessionViewModel?.activeError ?? activeThread?.activeError).map(describe)
                ?? actionError ?? backgroundError
        )
    }

    private func loadSession() async {
        guard let activeSession else { session = nil; return }
        let viewModel = SessionConversationViewModel(sessionId: activeSession.id, clientService: clientService)
        session = viewModel
        await viewModel.loadHistory()
    }

    private func loadThread() async {
        guard let selectedThreadId else { thread = nil; return }
        let viewModel = ThreadConversationViewModel(threadId: selectedThreadId, clientService: clientService)
        thread = viewModel
        await viewModel.loadThreadData()
    }

    private func loadHumanIdentity() async {
        guard !Task.isCancelled,
              let member = try? await clientService.fetchMemberDetail(name: "human"),
              let shape = member.avatarShape, let color = member.avatarColor,
              WorkspaceWebState.Avatar.shapes.contains(shape),
              WorkspaceWebState.Avatar.colors.contains(color) else { return }
        humanIdentity = .init(shape: shape, color: color)
    }

    private func handleAction(_ action: String, _ payload: [String: Any]) {
        switch action {
        case "settings": openSettings()
        case "addProject": onAddProject()
        case "selectTab":
            if let tab = NavigationTab.allCases.first(where: { $0.rawValue.lowercased() == payload["tab"] as? String }) {
                selectedTab = tab
                actionError = nil
            }
        case "selectRow":
            guard payload["tab"] as? String == tabID, let id = payload["id"] as? String,
                  rows.contains(where: { $0.id == id }) else { return }
            switch selectedTab {
            case .sessions: selectedSessionId = id
            case .threads: selectedThreadId = id
            case .projects: selectedProjectId = id
            }
            actionError = nil
        case "resolveApproval":
            guard selectedTab == .sessions, let session, session.sessionId == selection,
                  let request = session.activeApproval, request.sessionId == payload["sessionId"] as? String,
                  request.approvalId == payload["approvalId"] as? String,
                  let rawChoice = payload["choice"] as? String, let choice = ApprovalChoice(rawValue: rawChoice) else { return }
            let answers = payload["answers"] as? [String: [String]]
            Task { await session.resolveApproval(decision: .init(choice: choice, answers: answers)) }
        case "openProjectSession":
            guard selectedTab == .projects, let project = projects.first(where: { $0.id == selectedProjectId }),
                  let id = payload["sessionId"] as? String, project.relatedSessionIds?.contains(id) == true,
                  sessions.contains(where: { $0.id == id }) else { return }
            selectedSessionId = id
            selectedTab = .sessions
            actionError = nil
        case "bindThreadSession":
            guard selectedTab == .threads, canBindThreadSession, !threadBindingInFlight,
                  let threadID = selectedThreadId, payload["id"] as? String == threadID,
                  let sessionID = payload["sessionId"] as? String,
                  sessions.contains(where: { $0.id == sessionID }),
                  let nickname = payload["nickname"] as? String else { return }
            threadBindingInFlight = true
            Task {
                defer { threadBindingInFlight = false }
                do {
                    try await clientService.bindThreadSession(threadId: threadID, sessionId: sessionID, nickname: nickname)
                    threads = try await clientService.fetchThreads()
                    if selectedThreadId == threadID { await thread?.loadThreadData() }
                    actionError = nil
                } catch { actionError = describe(error) }
            }
        case "dismissError":
            guard payload["tab"] as? String == tabID else { return }
            actionError = nil
            backgroundError = nil
            if selectedTab == .sessions { session?.dismissError() }
            if selectedTab == .threads { thread?.dismissError() }
        default:
            guard payload["tab"] as? String == tabID, let id = payload["id"] as? String, id == selection else { return }
            handleConversationAction(action, id: id, payload: payload)
        }
    }

    private func handleConversationAction(_ action: String, id: String, payload: [String: Any]) {
        switch action {
        case "send":
            guard let text = payload["text"] as? String else { return }
            if selectedTab == .sessions, let session, session.sessionId == id {
                let requestID = payload["requestID"] as? String
                func rejectAttachment(_ message: String) {
                    actionError = message
                    if let requestID { submissionResults[id] = .init(requestID: requestID, accepted: false) }
                }
                let rawFiles = payload["files"] as? [[String: String]] ?? []
                guard rawFiles.count <= 5 else { rejectAttachment("Select at most five files"); return }
                var files: [SessionFileUpload] = []
                for file in rawFiles {
                    guard let name = file["name"], !name.isEmpty, let encoded = file["data"],
                          encoded.utf8.count <= 14_000_000, let data = Data(base64Encoded: encoded) else {
                        rejectAttachment("Unable to read attachment"); return
                    }
                    files.append(.init(name: name, data: data))
                }
                guard files.reduce(0, { $0 + $1.data.count }) <= 10_000_000 else { rejectAttachment("Attachments exceed 10 MB"); return }
                Task {
                    let accepted = await session.sendPrompt(text: text, isSteer: payload["steer"] as? Bool == true, files: files, requestId: requestID ?? UUID().uuidString)
                    if let requestID { submissionResults[id] = .init(requestID: requestID, accepted: accepted) }
                }
            } else if selectedTab == .threads, let thread, thread.threadId == id {
                Task { await thread.sendMessage(text: text) }
            }
        case "sessionConfig", "model", "mode":
            guard selectedTab == .sessions, let session, session.sessionId == id,
                  let configId = action == "sessionConfig" ? payload["configId"] as? String : action,
                  let value = payload["value"] as? String, !value.isEmpty,
                  configurationFieldWritable(configId, in: session) else { return }
            Task { await session.setConfiguration(configId: configId, value: value) }
        case "stop", "revive":
            guard selectedTab == .sessions, let session, session.sessionId == id else { return }
            Task {
                do {
                    if action == "stop" {
                        try await clientService.stopSession(sessionId: id)
                    } else {
                        try await clientService.reviveSession(sessionId: id)
                    }
                    actionError = nil
                    await session.loadHistory()
                } catch { actionError = describe(error) }
            }
        case "avatar", "resetAvatar":
            let next: WorkspaceWebState.Avatar
            if action == "resetAvatar" {
                next = .init(shape: "sphere", color: "black")
            } else if let shape = payload["shape"] as? String,
                      let color = payload["color"] as? String,
                      WorkspaceWebState.Avatar.shapes.contains(shape),
                      WorkspaceWebState.Avatar.colors.contains(color) {
                next = .init(shape: shape, color: color)
            } else { return }
            // Immediate local rendering (per-row override map) plus the persisted
            // human identity that every un-overridden row falls back to.
            let key = avatarKey(id: id)
            let previousIdentity = humanIdentity
            let previousOverrides = avatarOverrides
            var overrides = avatars
            if action == "resetAvatar" {
                overrides.removeValue(forKey: key)
            } else {
                overrides[key] = next
            }
            if let encoded = try? JSONEncoder().encode(overrides) { avatarOverrides = encoded }
            humanIdentity = next
            Task {
                do {
                    try await clientService.setMemberAvatar(
                        name: "human",
                        avatar: .init(seed: "human",
                                      colorHex: AvatarPaletteColor(rawValue: next.color)?.lightHex,
                                      shape: next.shape,
                                      color: next.color)
                    )
                    actionError = nil
                } catch {
                    // No fake persistence: roll the optimistic render back unless a
                    // newer edit already superseded it, then surface the server error.
                    if humanIdentity == next {
                        humanIdentity = previousIdentity
                        avatarOverrides = previousOverrides
                    }
                    actionError = describe(error)
                }
            }
        default: break
        }
    }

    /// Writes are only attempted when the typed configuration view says the
    /// field is writable; the server still owns the final validation.
    private func configurationFieldWritable(_ configId: String, in session: SessionConversationViewModel) -> Bool {
        guard let configuration = session.configuration,
              configuration.supported, !configuration.readonly else { return false }
        let fields = configuration.supportedFields.isEmpty ? ["model", "mode"] : configuration.supportedFields
        return fields.contains(configId)
    }

    /// Background loads surface actionable backend guidance (wrong local app on
    /// the default port, stale process, contract mismatch) instead of a bare
    /// connection error.
    @MainActor
    private func backgroundErrorText(_ error: Error) async -> String {
        let baseURL = PharosClientBackend.configuration.baseURL
        guard let healthReporting = clientService as? BackendHealthReporting else {
            return describe(error)
        }
        let probe = await healthReporting.probeBackend()
        return WorkspaceWebState.backgroundError(error, baseURL: baseURL, probe: probe)
    }

    private func describe(_ error: Error) -> String {
        WorkspaceWebState.describe(error)
    }
}
