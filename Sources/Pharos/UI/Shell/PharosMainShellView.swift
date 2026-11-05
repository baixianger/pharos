import SwiftUI
import PharosClientKit

/// The unified 3-pane native desktop client shell for Pharos.
/// Implements responsive Grok Bot desktop geometry, compact 88px icon rail collapsing,
/// docked vs overlay details inspector, and strict client/backend decoupling via `PharosClientService`.
public struct PharosMainShellView: View {
    @State public var layoutState = ShellLayoutState()

    // Client service providing data
    public let clientService: PharosClientService

    // Navigation and selection state
    @State private var selectedTab: NavigationTab = .sessions
    @State private var selectedSessionId: String?
    @State private var selectedThreadId: String?
    @State private var selectedProjectId: String?

    // Mock/loaded summaries
    @State private var sessions: [ClientSessionSummary] = []
    @State private var threads: [ClientThreadSummary] = []
    @State private var projects: [ClientProjectSummary] = []

    // 1:1 Direct Agent Session View Model
    @State private var sessionViewModel: SessionConversationViewModel?

    // Active session metadata & composer state
    @State private var composerText: String = ""
    @State private var isSteeringMode: Bool = false

    public init(clientService: PharosClientService = MockPharosClientService()) {
        self.clientService = clientService
    }

    public var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                // Left Pane: Navigation & Roster
                leftPane
                    .frame(width: layoutState.effectiveSidebarWidth)

                // Drag handle for sidebar
                sidebarResizeHandle

                // Middle & Right: Canvas + Inspector Container
                ZStack(alignment: .trailing) {
                    HStack(spacing: 0) {
                        // Middle Pane: Conversation Canvas
                        middleCanvasPane

                        // Right Pane: Docked Inspector (when space permits)
                        if layoutState.isDetailsDocked {
                            Divider()
                                .overlay(Color.primary.opacity(0.08))

                            rightDetailsPane
                                .frame(width: layoutState.effectiveDetailsWidth)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }

                    // Right Pane: Overlay Drawer (when window width is constrained)
                    if layoutState.isDetailsOverlay {
                        // Subtle scrim behind drawer
                        Color.black.opacity(0.15)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(PharosDesignTokens.Springs.detailsDrawer) {
                                    layoutState.isDetailsVisible = false
                                }
                            }

                        rightDetailsPane
                            .frame(width: layoutState.effectiveDetailsWidth)
                            .shadow(color: Color.black.opacity(0.15), radius: 12, x: -4, y: 0)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
            .onAppear {
                layoutState.windowWidth = proxy.size.width
                layoutState.windowHeight = proxy.size.height
                loadInitialData()
            }
            .onChange(of: proxy.size) { _, newSize in
                layoutState.windowWidth = newSize.width
                layoutState.windowHeight = newSize.height
            }
            .onChange(of: selectedSessionId) { _, newId in
                if let id = newId {
                    let vm = SessionConversationViewModel(sessionId: id, clientService: clientService)
                    self.sessionViewModel = vm
                    Task { await vm.loadHistory() }
                } else {
                    self.sessionViewModel = nil
                }
            }
        }
        .frame(
            minWidth: PharosDesignTokens.Layout.minWindowWidth,
            minHeight: PharosDesignTokens.Layout.minWindowHeight
        )
        .animation(PharosDesignTokens.Springs.panelExpand, value: layoutState.isSidebarCompact)
        .animation(PharosDesignTokens.Springs.detailsDrawer, value: layoutState.isDetailsVisible)
        .animation(PharosDesignTokens.Springs.detailsDrawer, value: layoutState.isDetailsDocked)
    }

    // MARK: - Left Pane

    private var leftPane: some View {
        NavigationRosterView(
            selectedTab: $selectedTab,
            isCompact: layoutState.isSidebarCompact,
            onToggleCompact: {
                withAnimation(PharosDesignTokens.Springs.panelExpand) {
                    layoutState.toggleSidebarCompact()
                }
            },
            sessions: sessions,
            threads: threads,
            projects: projects,
            selectedSessionId: $selectedSessionId,
            selectedThreadId: $selectedThreadId,
            selectedProjectId: $selectedProjectId
        )
    }

    private var sidebarResizeHandle: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                layoutState.updateSidebarDrag(width: gesture.location.x)
                            }
                    )
            )
    }

    // MARK: - Middle Canvas Pane

    private var middleCanvasPane: some View {
        ConversationCanvasView(
            title: activeTitle,
            subtitle: activeSubtitle,
            agentKind: activeAgentKind,
            machineName: activeMachineName,
            status: "active",
            isDetailsOpen: layoutState.isDetailsVisible,
            onToggleDetails: {
                withAnimation(PharosDesignTokens.Springs.detailsDrawer) {
                    layoutState.toggleDetails()
                }
            },
            composerText: $composerText,
            isSteeringMode: isSteeringMode,
            onToggleSteering: {
                isSteeringMode.toggle()
            },
            onSendMessage: { message in
                handleSendMessage(message)
            },
            turns: sessionViewModel?.turns ?? [],
            activeApproval: sessionViewModel?.activeApproval,
            activeError: sessionViewModel?.activeError,
            liveStreamingText: sessionViewModel?.liveStreamingText ?? "",
            liveReasoningText: sessionViewModel?.liveReasoningText ?? "",
            isTurnInProgress: sessionViewModel?.isTurnInProgress ?? false,
            onResolveApproval: { decision in
                Task { await sessionViewModel?.resolveApproval(decision: decision) }
            },
            onDismissError: {
                sessionViewModel?.dismissError()
            }
        )
    }

    // MARK: - Right Details Pane

    private var rightDetailsPane: some View {
        ConversationDetailsView(
            isOverlay: layoutState.isDetailsOverlay,
            onClose: {
                withAnimation(PharosDesignTokens.Springs.detailsDrawer) {
                    layoutState.isDetailsVisible = false
                }
            },
            memberName: activeTitle,
            agentKind: activeAgentKind ?? "codex",
            machineName: activeMachineName ?? "local",
            currentModel: "gpt-4o",
            currentMode: "yolo",
            workspacePath: "~/personal/pharos",
            onModelChange: { _ in },
            onModeToggle: {},
            onStop: {},
            onRevive: {}
        )
    }

    // MARK: - Helpers

    private var activeTitle: String {
        switch selectedTab {
        case .sessions:
            if let id = selectedSessionId, let s = sessions.first(where: { $0.id == id }) {
                return s.title
            }
            return "Session"
        case .threads:
            if let id = selectedThreadId, let t = threads.first(where: { $0.id == id }) {
                return t.title
            }
            return "Thread Roster"
        case .projects:
            if let id = selectedProjectId, let p = projects.first(where: { $0.id == id }) {
                return p.name
            }
            return "Project"
        }
    }

    private var activeSubtitle: String? {
        switch selectedTab {
        case .sessions: return "1:1 Session • Direct Agent Connection"
        case .threads: return "Collaborative Thread • Multi-Agent Roster"
        case .projects: return "Local Codebase Workspace"
        }
    }

    private var activeAgentKind: String? {
        if selectedTab == .sessions, let id = selectedSessionId {
            return sessions.first(where: { $0.id == id })?.agentType
        }
        return nil
    }

    private var activeMachineName: String? {
        if selectedTab == .sessions, let id = selectedSessionId {
            return sessions.first(where: { $0.id == id })?.machineId
        }
        return nil
    }

    private func loadInitialData() {
        Task {
            if let s = try? await clientService.fetchSessions() {
                self.sessions = s
                if selectedSessionId == nil { selectedSessionId = s.first?.id }
            }
            if let t = try? await clientService.fetchThreads() {
                self.threads = t
                if selectedThreadId == nil { selectedThreadId = t.first?.id }
            }
            if let p = try? await clientService.fetchProjects() {
                self.projects = p
                if selectedProjectId == nil { selectedProjectId = p.first?.id }
            }
        }
    }

    private func handleSendMessage(_ message: String) {
        Task {
            if selectedTab == .sessions {
                await sessionViewModel?.sendPrompt(text: message, isSteer: isSteeringMode)
            } else if selectedTab == .threads, let tId = selectedThreadId {
                _ = try? await clientService.sendThreadMessage(threadId: tId, text: message)
            }
        }
    }
}
