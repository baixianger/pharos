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

            Divider()
                .overlay(Color.primary.opacity(0.08))

            // Roster List Content
            ScrollView {
                LazyVStack(spacing: 2) {
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
                .padding(.horizontal, isCompact ? 6 : 8)
            }

            Divider()
                .overlay(Color.primary.opacity(0.08))

            // Bottom Rail Controls
            bottomControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(nsColor: .windowBackgroundColor)
        )
    }

    // MARK: - Headers

    private var expandedTabHeader: some View {
        HStack(spacing: 6) {
            Picker("Navigation", selection: $selectedTab) {
                ForEach(NavigationTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button(action: onToggleCompact) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
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
                        .frame(width: 40, height: 32)
                        .background(
                            selectedTab == tab
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(tab.rawValue)
            }
        }
        .padding(.vertical, 8)
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
                    size: 34,
                    showRing: isSelected
                )

                Circle()
                    .fill(statusColor(for: session.status.rawValue))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(session.agentType.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                if let preview = session.latestMessagePreview {
                    Text(preview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PharosDesignTokens.Layout.sidebarRowHeight)
        .background(
            isSelected
            ? Color.accentColor.opacity(0.12)
            : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func expandedThreadRow(_ thread: ClientThreadSummary, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            PharosAvatarView(
                seed: thread.title,
                status: .idle,
                size: 34,
                showRing: isSelected
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text("\(thread.memberIds.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PharosDesignTokens.Layout.sidebarRowHeight)
        .background(
            isSelected
            ? Color.accentColor.opacity(0.12)
            : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "folder")
                        .font(.system(size: 14))
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(project.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text("\(project.activeSessionsCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Text(project.projectPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PharosDesignTokens.Layout.sidebarRowHeight)
        .background(
            isSelected
            ? Color.accentColor.opacity(0.12)
            : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var bottomControls: some View {
        HStack {
            if isCompact {
                Button(action: onToggleCompact) {
                    Image(systemName: "arrow.right.to.line")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Expand sidebar")
            } else {
                Button(action: onToggleCompact) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.to.line")
                        Text("Collapse")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
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
