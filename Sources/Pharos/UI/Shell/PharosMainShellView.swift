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
    @State private var sessionMember: (sessionID: String, detail: ClientMemberDetail)?
    @State private var rosterMembers: [String: ClientMemberDetail] = [:]
    @AppStorage("pharos.workspaceAvatarOverrides", store: PharosPrefs.shared) private var avatarOverrides = Data()
    @State private var actionError: String?
    @State private var submissionResults: [String: WorkspaceWebState.SubmissionResult] = [:]
    @State private var canBindThreadSession = false
    @State private var threadBindingInFlight = false
    @State private var threadBindingCandidates: [ClientSessionSummary] = []

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
                        threadBindingCandidates = await clientService.threadSessionBindingCandidates()
                    } catch { threadBindingCandidates = []; actionError = describe(error) }
                    canBindThreadSession = await clientService.supportsThreadSessionBinding()
                    inventoryIssues = await clientService.fetchSessionInventoryIssues()
                    if selectedSessionId == nil { selectedSessionId = sessions.first?.id }
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .task {
                while !Task.isCancelled {
                    do { threads = try await clientService.fetchThreads() }
                    catch { actionError = describe(error) }
                    if selectedThreadId == nil { selectedThreadId = threads.first?.id }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .task {
                while !Task.isCancelled {
                    do { projects = try await clientService.fetchProjects() }
                    catch { actionError = describe(error) }
                    if selectedProjectId == nil { selectedProjectId = projects.first?.id }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
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
        func row(id: String, title: String, subtitle: String, seed: String, legacyID: String? = nil) -> WorkspaceWebState.Row {
            let identity = overrides[avatarKey(id: id)] ?? legacyID.flatMap { overrides[avatarKey(id: $0)] } ?? .init(seed: seed)
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
                    return WorkspaceWebState.RosterAvatar(id: id, name: member?.name ?? id,
                                                          identity: .init(seed: member?.avatarSeed ?? id))
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

    private var activeSession: ClientSessionSummary? { sessions.first { $0.id == selectedSessionId } }

    private var rosterMemberIDs: [String] {
        guard selectedTab == .threads else { return [] }
        return Set(threads.flatMap { ThreadConversationViewModel.visibleAgentIDs(in: $0) }).sorted()
    }

    private func loadRosterMembers() async {
        var loaded = rosterMembers
        for id in rosterMemberIDs where loaded[id] == nil {
            guard !Task.isCancelled else { return }
            loaded[id] = try? await clientService.fetchMemberDetail(name: id)
        }
        if !Task.isCancelled { rosterMembers = loaded }
    }

    private var details: WorkspaceWebState.Details? {
        if selectedTab == .projects, let project = projects.first(where: { $0.id == selectedProjectId }) {
            return .init(workspace: project.projectPath.hasPrefix("/") ? project.projectPath : "")
        }
        guard selectedTab == .sessions, let activeSession else { return nil }
        let member = sessionMember?.sessionID == activeSession.id ? sessionMember?.detail : nil
        let models = member.map { _ in ConversationDetailsView(agentKind: activeSession.agentType).availableModels } ?? []
        let model = member?.model ?? ""
        return .init(sessionID: activeSession.id, agent: activeSession.agentType,
                     host: activeSession.machineId, status: member?.status ?? activeSession.status.rawValue,
                     workspace: activeSession.workspacePath,
                     model: model, mode: member?.mode ?? "",
                     models: model.isEmpty || models.contains(model) ? models : [model] + models)
    }

    private var webState: WorkspaceWebState {
        let rows = rows
        let row = rows.first { $0.id == selection }
        let activeSession = selectedTab == .sessions && session?.sessionId == selection ? session : nil
        let activeThread = selectedTab == .threads && thread?.threadId == selection ? thread : nil
        let selectedProject = selectedTab == .projects ? projects.first(where: { $0.id == selection }) : nil
        let projectSessionIDs = Set(selectedProject?.relatedSessionIds ?? [])
        let activity = switch (activeSession?.activeApproval != nil, activeSession?.isTurnInProgress == true) {
        case (true, _): "waiting"
        case (_, true): "working"
        default: "idle"
        }
        return WorkspaceWebState(
            tab: tabID, selection: selection, title: row?.title ?? selectedTab.rawValue,
            theme: colorScheme == .dark ? "dark" : "light", rows: rows,
            identity: row?.identity ?? .init(shape: "sphere", color: "black"), activity: activity,
            canSend: selectedTab == .sessions ? (activeSession != nil && activeSession?.isLoadingHistory == false) : (selectedTab == .threads && activeThread != nil), detail: details,
            turns: activeSession?.turns ?? [], streamingText: activeSession?.liveStreamingText ?? "",
            reasoningText: activeSession?.liveReasoningText ?? "", tools: activeSession?.liveTools ?? [],
            approval: activeSession?.activeApproval, goal: activeSession?.goal, todos: activeSession?.todos ?? [],
            sessionConfiguration: activeSession?.configuration, supportsTextAttachments: activeSession?.supportsTextAttachments ?? false,
            configurationInFlight: activeSession?.configurationInFlight ?? false,
            inventoryIssues: inventoryIssues, commandResult: activeSession?.commandResult, submissionResults: submissionResults,
            projectSessions: sessions.filter { projectSessionIDs.contains($0.id) }.map(WorkspaceWebState.ProjectSession.init),
            projectInventoryLoaded: selectedProject?.relatedSessionIds != nil,
            projectHosts: selectedProject?.trackedDevices ?? [],
            projectCheckoutUnavailableHosts: selectedProject?.checkoutUnavailableHosts ?? [],
            canBindThreadSession: selectedTab == .threads && canBindThreadSession,
            threadBindingInFlight: threadBindingInFlight,
            threadBindingCandidates: threadBindingCandidates.map(WorkspaceWebState.ProjectSession.init),
            messages: activeThread?.messages ?? [],
            members: activeThread?.rosterMembers ?? [],
            // A background navigation error must not hide a failed prompt or
            // command in the conversation the user is actively working in.
            error: (activeSession?.activeError ?? activeThread?.activeError).map(describe) ?? actionError
        )
    }

    private func loadSession() async {
        sessionMember = nil
        guard let activeSession else { session = nil; return }
        let viewModel = SessionConversationViewModel(sessionId: activeSession.id, clientService: clientService)
        session = viewModel
        async let detail = try? clientService.fetchMemberDetail(name: activeSession.title)
        await viewModel.loadHistory()
        let loadedMember = await detail
        if !Task.isCancelled, selectedSessionId == activeSession.id, let loadedMember,
           matches(loadedMember, session: activeSession) {
            sessionMember = (activeSession.id, loadedMember)
        }
    }

    private func matches(_ member: ClientMemberDetail, session: ClientSessionSummary) -> Bool {
        member.machine == session.machineId
            && member.agent.caseInsensitiveCompare(session.agentType) == .orderedSame
    }

    private func loadThread() async {
        guard let selectedThreadId else { thread = nil; return }
        let viewModel = ThreadConversationViewModel(threadId: selectedThreadId, clientService: clientService)
        thread = viewModel
        await viewModel.loadThreadData()
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
                  threadBindingCandidates.contains(where: { $0.id == sessionID }),
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
        case "sessionConfig":
            guard selectedTab == .sessions, let session, session.sessionId == id,
                  let configId = payload["configId"] as? String, let value = payload["value"] as? String else { return }
            Task { await session.setConfiguration(configId: configId, value: value) }
        case "avatar", "resetAvatar":
            let key = avatarKey(id: id)
            var overrides = avatars
            if action == "resetAvatar" {
                overrides.removeValue(forKey: key)
            } else if let shape = payload["shape"] as? String, WorkspaceWebState.Avatar.shapes.contains(shape),
                      let color = payload["color"] as? String, WorkspaceWebState.Avatar.colors.contains(color) {
                overrides[key] = .init(shape: shape, color: color)
            } else { return }
            if let encoded = try? JSONEncoder().encode(overrides) { avatarOverrides = encoded }
            if selectedTab == .sessions, let activeSession, sessionMember?.sessionID == id {
                let color = overrides[key].flatMap { AvatarPaletteColor(rawValue: $0.color)?.lightHex }
                Task {
                    do {
                        try await clientService.setMemberAvatar(
                            name: activeSession.title,
                            avatar: .init(seed: activeSession.avatarSeed, colorHex: color)
                        )
                    } catch {
                        if selectedSessionId == id { actionError = describe(error) }
                    }
                }
            }
        case "model", "mode", "stop", "revive":
            guard selectedTab == .sessions, let activeSession, let details,
                  sessionMember?.sessionID == id else { return }
            let value = payload["value"] as? String ?? ""
            Task {
                do {
                    switch action {
                    case "model":
                        guard details.models.contains(value) else { return }
                        try await clientService.setMemberModel(name: activeSession.title, model: value)
                    case "mode":
                        guard ["safe", "yolo"].contains(value) else { return }
                        try await clientService.setMemberMode(name: activeSession.title, mode: value)
                    case "stop": try await clientService.stopMember(name: activeSession.title)
                    case "revive": try await clientService.reviveMember(name: activeSession.title)
                    default: return
                    }
                    let loadedMember = try await clientService.fetchMemberDetail(name: activeSession.title)
                    if selectedSessionId == id {
                        sessionMember = matches(loadedMember, session: activeSession) ? (id, loadedMember) : nil
                    }
                } catch {
                    if selectedSessionId == id { actionError = describe(error) }
                }
            }
        default: break
        }
    }

    private func describe(_ error: Error) -> String {
        switch error as? PharosClientError {
        case .backendUnreachable(let backend, let reason): "\(backend) is unavailable. \(reason)"
        case .connectionFailed(let message), .operationFailed(let message): message
        case .sessionNotFound: "Session not found."
        case .threadNotFound: "Thread not found."
        case .approvalNotFound: "This approval is no longer active."
        case nil: error.localizedDescription
        }
    }
}
