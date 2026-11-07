import SwiftUI
import PharosClientKit

/// Navigation tab displayed in the left roster pane.
public enum NavigationTab: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case threads = "Threads"
    case projects = "Projects"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .sessions: return "person.2.wave.2"
        case .threads: return "bubble.left.and.bubble.right"
        case .projects: return "folder"
        }
    }
}

/// The left roster pane supporting full expanded mode (240-400px) and 88px compact icon rail.
public struct NavigationRosterView: View {
    @Binding public var selectedTab: NavigationTab
    public let isCompact: Bool
    public let onToggleCompact: () -> Void

    // Client summaries for rendering
    public var sessions: [ClientSessionSummary] = []
    public var threads: [ClientThreadSummary] = []
    public var projects: [ClientProjectSummary] = []

    @Binding public var selectedSessionId: String?
    @Binding public var selectedThreadId: String?
    @Binding public var selectedProjectId: String?

    public init(
        selectedTab: Binding<NavigationTab>,
        isCompact: Bool,
        onToggleCompact: @escaping () -> Void,
        sessions: [ClientSessionSummary] = [],
        threads: [ClientThreadSummary] = [],
        projects: [ClientProjectSummary] = [],
        selectedSessionId: Binding<String?> = .constant(nil),
        selectedThreadId: Binding<String?> = .constant(nil),
        selectedProjectId: Binding<String?> = .constant(nil)
    ) {
        self._selectedTab = selectedTab
        self.isCompact = isCompact
        self.onToggleCompact = onToggleCompact
        self.sessions = sessions
        self.threads = threads
        self.projects = projects
        self._selectedSessionId = selectedSessionId
        self._selectedThreadId = selectedThreadId
        self._selectedProjectId = selectedProjectId
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header / Tab Switcher
            if isCompact {
                compactTabHeader
            } else {
                expandedTabHeader
            }

            Rectangle()
                .fill(PharosDesignTokens.Colors.borderTranslucent)
                .frame(height: PharosDesignTokens.Radii.hairline)

            // Pinned Main Bot Header (Signature Grok Bot element)
            if !isCompact {
                pinnedMainBotSection
            }

            // Roster List Content
            ScrollView {
                LazyVStack(spacing: 4) {
                    switch selectedTab {
                    case .sessions:
                        sessionsList
                    case .threads:
                        threadsList
                    case .projects:
                        projectsList
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, isCompact ? 6 : 10)
            }

            Rectangle()
                .fill(PharosDesignTokens.Colors.borderTranslucent)
                .frame(height: PharosDesignTokens.Radii.hairline)

            // Bottom Workspace & Rail Controls
            bottomControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PharosDesignTokens.Colors.sidebar)
    }

    // MARK: - Headers

    private var expandedTabHeader: some View {
        HStack(spacing: 6) {
            // Custom Grok Bot Pill Tabs (.gb-tabs)
            HStack(spacing: 4) {
                ForEach(NavigationTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .medium))
                            .foregroundStyle(selectedTab == tab ? PharosDesignTokens.Colors.inkPrimary : PharosDesignTokens.Colors.inkSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(selectedTab == tab ? PharosDesignTokens.Colors.hoverNeutral : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            Button(action: onToggleCompact) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(PharosDesignTokens.Colors.hoverNeutral))
            }
            .buttonStyle(.plain)
            .help("Collapse to 88px icon rail")
        }
        .padding(.horizontal, 12)
        .frame(height: PharosDesignTokens.Layout.titlebarHeight)
    }

    private var compactTabHeader: some View {
        VStack(spacing: 6) {
            ForEach(NavigationTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Image(systemName: tab.iconName)
                        .font(.system(size: 15, weight: selectedTab == tab ? .semibold : .regular))
                        .frame(width: 44, height: 34)
                        .background(
                            selectedTab == tab
                            ? PharosDesignTokens.Colors.hoverNeutral
                            : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(selectedTab == tab ? PharosDesignTokens.Colors.accent : PharosDesignTokens.Colors.inkSecondary)
                }
                .buttonStyle(.plain)
                .help(tab.rawValue)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Pinned Main Bot

    private var pinnedMainBotSection: some View {
        VStack(spacing: 6) {
            PharosAvatarView(
                seed: "Main Bot",
                status: .working,
                size: PharosDesignTokens.Layout.mainBotAvatarSize,
                showRing: true
            )
            .padding(.top, 4)

            VStack(spacing: 1) {
                Text("Main Bot")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)

                Text("Active Mesh Orchestrator")
                    .font(.system(size: 11))
                    .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    // MARK: - Item Lists

    private var sessionsList: some View {
        ForEach(sessions) { session in
            Button {
                selectedSessionId = session.id
            } label: {
                if isCompact {
                    compactRow(
                        title: session.title,
                        subtitle: session.agentType,
                        status: session.status.rawValue,
                        isSelected: selectedSessionId == session.id
                    )
                } else {
                    expandedSessionRow(session, isSelected: selectedSessionId == session.id)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var threadsList: some View {
        ForEach(threads) { thread in
            Button {
                selectedThreadId = thread.id
            } label: {
                if isCompact {
                    compactRow(
                        title: thread.title,
                        subtitle: "\(thread.memberIds.count) members",
                        status: "active",
                        isSelected: selectedThreadId == thread.id
                    )
                } else {
                    expandedThreadRow(thread, isSelected: selectedThreadId == thread.id)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var projectsList: some View {
        ForEach(projects) { project in
            Button {
                selectedProjectId = project.id
            } label: {
                if isCompact {
                    compactRow(
                        title: project.name,
                        subtitle: "\(project.activeSessionsCount)",
                        status: "active",
                        isSelected: selectedProjectId == project.id
                    )
                } else {
                    expandedProjectRow(project, isSelected: selectedProjectId == project.id)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Row Components

    private func compactRow(title: String, subtitle: String, status: String, isSelected: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            PharosAvatarView(
                seed: title,
                status: avatarStatus(from: status),
                size: 40,
                showRing: isSelected
            )

            // Status indicator dot
            Circle()
                .fill(statusColor(for: status))
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
        }
        .frame(height: PharosDesignTokens.Layout.sidebarRowHeight)
        .help("\(title) • \(subtitle)")
    }

    private func expandedSessionRow(_ session: ClientSessionSummary, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                PharosAvatarView(
                    seed: session.title,
                    status: avatarStatus(from: session.status.rawValue),
                    size: PharosDesignTokens.Layout.sidebarAvatarSize,
                    showRing: isSelected
                )

                Circle()
                    .fill(statusColor(for: session.status.rawValue))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(PharosDesignTokens.Colors.sidebar, lineWidth: 1.5))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(session.agentType.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(PharosDesignTokens.Colors.hoverNeutral)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                }

                if let preview = session.latestMessagePreview {
                    Text(preview)
                        .font(.system(size: 11))
                        .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: PharosDesignTokens.Layout.sidebarRowHeight)
        .background(
            isSelected
            ? PharosDesignTokens.Colors.selectedNeutral
            : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: PharosDesignTokens.Radii.xl))
    }

    private func expandedThreadRow(_ thread: ClientThreadSummary, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            PharosAvatarView(
                seed: thread.title,
                status: .idle,
                size: PharosDesignTokens.Layout.sidebarAvatarSize,
                showRing: isSelected
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(thread.memberIds.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                }

                Text("Multi-agent collaborative thread")
                    .font(.system(size: 11))
                    .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: PharosDesignTokens.Layout.sidebarRowHeight)
        .background(
            isSelected
            ? PharosDesignTokens.Colors.selectedNeutral
            : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: PharosDesignTokens.Radii.xl))
    }

    private func avatarStatus(from str: String) -> AvatarActivityStatus {
        switch str.lowercased() {
        case "working", "busy", "active": return .working
        case "needs_human", "waiting", "waiting_approval": return .needsHuman
        case "stopped", "dead", "cancelled": return .stopped
        default: return .idle
        }
    }

    private func expandedProjectRow(_ project: ClientProjectSummary, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(PharosDesignTokens.Colors.hoverNeutral)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "folder")
                        .font(.system(size: 14))
                        .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(project.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(project.activeSessionsCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                }

                Text(project.projectPath)
                    .font(.system(size: 10))
                    .foregroundStyle(PharosDesignTokens.Colors.inkTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: PharosDesignTokens.Layout.sidebarRowHeight)
        .background(
            isSelected
            ? PharosDesignTokens.Colors.selectedNeutral
            : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: PharosDesignTokens.Radii.xl))
    }

    private var bottomControls: some View {
        HStack(spacing: 8) {
            if isCompact {
                VStack(spacing: 8) {
                    Circle()
                        .fill(PharosDesignTokens.Colors.hoverNeutral)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Text("P")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)
                        )

                    Button(action: onToggleCompact) {
                        Image(systemName: "arrow.right.to.line")
                            .font(.system(size: 12))
                            .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Expand sidebar")
                }
                .padding(.vertical, 8)
            } else {
                // Monogram User / Workspace Card (.gb-user)
                Circle()
                    .fill(PharosDesignTokens.Colors.hoverNeutral)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Text("P")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("Pai's Workspace")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)

                    Text("Local mesh active")
                        .font(.system(size: 10))
                        .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                }

                Spacer()

                Button(action: onToggleCompact) {
                    Image(systemName: "arrow.left.to.line")
                        .font(.system(size: 12))
                        .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(PharosDesignTokens.Colors.hoverNeutral))
                }
                .buttonStyle(.plain)
                .help("Collapse sidebar")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private func statusColor(for status: String) -> Color {
        switch status.lowercased() {
        case "working", "busy": return PharosDesignTokens.Colors.statusWorking
        case "needs_human", "needshuman", "attention": return PharosDesignTokens.Colors.statusAttention
        case "error", "dead": return PharosDesignTokens.Colors.statusDanger
        default: return Color.secondary.opacity(0.6)
        }
    }
}
