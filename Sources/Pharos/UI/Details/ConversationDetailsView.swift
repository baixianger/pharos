import SwiftUI
import AppKit
import PharosClientKit

/// Sub-tabs within the conversation details inspector.
public enum DetailsSubTab: String, CaseIterable, Identifiable {
    case details = "Details"
    case library = "Library"
    case computer = "Computer"

    public var id: String { rawValue }
}

/// The right details & diagnostics inspector pane (280–320px).
public struct ConversationDetailsView: View {
    @State private var selectedSubTab: DetailsSubTab = .details
    public let isOverlay: Bool
    public let onClose: () -> Void

    // Member metadata
    public var memberName: String
    public var agentKind: String
    public var machineName: String
    public var currentModel: String
    public var currentMode: String
    public var workspacePath: String
    public var sessionId: String

    // Avatar Customization State
    @State private var selectedShape: AvatarShape = .blob
    @State private var selectedColor: AvatarPaletteColor = .blue

    // Live Terminal State for Computer Tab
    @State private var terminalViewModel: LiveTerminalViewModel

    public let onModelChange: (String) -> Void
    public let onModeToggle: () -> Void
    public let onStop: () -> Void
    public let onRevive: () -> Void
    public let onAvatarChange: (AvatarShape, AvatarPaletteColor) -> Void

    public init(
        isOverlay: Bool = false,
        onClose: @escaping () -> Void = {},
        memberName: String = "agent",
        agentKind: String = "codex",
        machineName: String = "mini",
        currentModel: String = "gpt-4o",
        currentMode: String = "yolo",
        workspacePath: String = "~/workspace",
        sessionId: String = "ses_main_01",
        onModelChange: @escaping (String) -> Void = { _ in },
        onModeToggle: @escaping () -> Void = {},
        onStop: @escaping () -> Void = {},
        onRevive: @escaping () -> Void = {},
        onAvatarChange: @escaping (AvatarShape, AvatarPaletteColor) -> Void = { _, _ in }
    ) {
        self.isOverlay = isOverlay
        self.onClose = onClose
        self.memberName = memberName
        self.agentKind = agentKind
        self.machineName = machineName
        self.currentModel = currentModel
        self.currentMode = currentMode
        self.workspacePath = workspacePath
        self.sessionId = sessionId
        self.onModelChange = onModelChange
        self.onModeToggle = onModeToggle
        self.onStop = onStop
        self.onRevive = onRevive
        self.onAvatarChange = onAvatarChange
        self._terminalViewModel = State(initialValue: LiveTerminalViewModel(
            tmuxSession: "pharos:\(memberName)"
        ))
    }

    public var availableModels: [String] {
        switch agentKind.lowercased() {
        case "codex":
            return ["gpt-4o", "gpt-4o-mini", "o1", "o1-mini", "claude-3-5-sonnet"]
        case "agy":
            return ["gemini-2.5-pro", "gemini-2.5-flash", "claude-3-7-sonnet"]
        case "dsh":
            return ["deepseek-chat", "deepseek-reasoner"]
        default:
            return ["default", "gpt-4o", "gemini-2.5-pro"]
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header with sub-tabs & close button
            inspectorHeader

            Rectangle()
                .fill(PharosDesignTokens.Colors.borderTranslucent)
                .frame(height: PharosDesignTokens.Radii.hairline)

            // Sub-tab content
            ScrollView {
                VStack(spacing: 16) {
                    switch selectedSubTab {
                    case .details:
                        detailsSection
                    case .library:
                        librarySection
                    case .computer:
                        computerSection
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: PharosDesignTokens.Layout.detailsMinWidth)
        .background(PharosDesignTokens.Colors.pane)
    }

    // MARK: - Header

    private var inspectorHeader: some View {
        HStack(spacing: 8) {
            // Pill tabs (.gb-profile-tabs)
            HStack(spacing: 4) {
                ForEach(DetailsSubTab.allCases) { tab in
                    Button {
                        selectedSubTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: selectedSubTab == tab ? .semibold : .medium))
                            .foregroundStyle(selectedSubTab == tab ? PharosDesignTokens.Colors.inkPrimary : PharosDesignTokens.Colors.inkSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(selectedSubTab == tab ? PharosDesignTokens.Colors.hoverNeutral : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(PharosDesignTokens.Colors.hoverNeutral))
            }
            .buttonStyle(.plain)
            .help("Close Inspector")
        }
        .padding(.horizontal, 14)
        .frame(height: PharosDesignTokens.Layout.titlebarHeight)
    }

    // MARK: - Details Tab

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Centered Profile Card (.gb-profile)
            VStack(spacing: 8) {
                PharosAvatarView(
                    seed: memberName,
                    customShape: selectedShape,
                    customColor: selectedColor,
                    status: .working,
                    size: PharosDesignTokens.Layout.detailsAvatarSize,
                    showRing: true
                )
                .shadow(color: PharosDesignTokens.Colors.accent.opacity(0.18), radius: 10, x: 0, y: 3)

                VStack(spacing: 2) {
                    Text(memberName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)

                    Text("\(agentKind.uppercased()) • \(machineName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            // Settings Group: Identity & Model
            VStack(alignment: .leading, spacing: 6) {
                Text("CONFIGURATION")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(PharosDesignTokens.Colors.inkTertiary)
                    .padding(.leading, 4)

                VStack(spacing: 0) {
                    // Model Row
                    HStack {
                        Text("Model")
                            .font(.system(size: 13))
                            .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { currentModel },
                            set: { onModelChange($0) }
                        )) {
                            ForEach(availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 140)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Rectangle()
                        .fill(PharosDesignTokens.Colors.borderTranslucent)
                        .frame(height: PharosDesignTokens.Radii.hairline)

                    // Autonomy Mode Row with Custom Toggle
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("YOLO Autonomous")
                                .font(.system(size: 13))
                                .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)
                            Text("Bypass confirmation prompt")
                                .font(.system(size: 10))
                                .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { currentMode.lowercased() == "yolo" },
                            set: { _ in onModeToggle() }
                        ))
                        .toggleStyle(GbToggleStyle())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(PharosDesignTokens.Colors.elevated)
                .overlay(
                    RoundedRectangle(cornerRadius: PharosDesignTokens.Radii.xl)
                        .stroke(PharosDesignTokens.Colors.borderTranslucent, lineWidth: PharosDesignTokens.Radii.hairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: PharosDesignTokens.Radii.xl))
            }

            // Avatar Customization Swatches
            avatarCustomizerGroup

            // Workspace & Lifecycle Operations
            lifecycleCard
        }
    }

    private var avatarCustomizerGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AVATAR STYLE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(PharosDesignTokens.Colors.inkTertiary)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Shape")
                        .font(.system(size: 13))
                        .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)
                    Spacer()
                    Picker("", selection: $selectedShape) {
                        ForEach(AvatarShape.allCases) { shape in
                            Text(shape.displayName).tag(shape)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 130)
                    .onChange(of: selectedShape) { _, newShape in
                        onAvatarChange(newShape, selectedColor)
                    }
                }

                Rectangle()
                    .fill(PharosDesignTokens.Colors.borderTranslucent)
                    .frame(height: PharosDesignTokens.Radii.hairline)

                // Color Swatches
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AvatarPaletteColor.allCases.filter { $0 != .black }) { color in
                            Button(action: {
                                selectedColor = color
                                onAvatarChange(selectedShape, color)
                            }) {
                                Circle()
                                    .fill(color.color(isDark: false))
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Circle()
                                            .stroke(PharosDesignTokens.Colors.inkPrimary, lineWidth: selectedColor == color ? 2 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(color.rawValue.capitalized)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(12)
            .background(PharosDesignTokens.Colors.elevated)
            .overlay(
                RoundedRectangle(cornerRadius: PharosDesignTokens.Radii.xl)
                    .stroke(PharosDesignTokens.Colors.borderTranslucent, lineWidth: PharosDesignTokens.Radii.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: PharosDesignTokens.Radii.xl))
        }
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("METADATA")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            metadataRow(label: "Name", value: memberName)
            metadataRow(label: "Agent", value: agentKind.uppercased())
            metadataRow(label: "Host Node", value: machineName)
            metadataRow(label: "Session ID", value: sessionId)

            Divider()
                .overlay(Color.primary.opacity(0.06))

            // Workspace Path & Open Actions
            VStack(alignment: .leading, spacing: 6) {
                Text("Workspace")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(workspacePath)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Button(action: {
                        let expanded = (workspacePath as NSString).expandingTildeInPath
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: expanded)
                    }) {
                        Label("Finder", systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)

                    Button(action: {
                        let expanded = (workspacePath as NSString).expandingTildeInPath
                        if let url = URL(string: "vscode://file/\(expanded)") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Label("VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONTROLS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            // MODEL Switcher Dropdown
            HStack {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("Model", selection: Binding(
                    get: { currentModel },
                    set: { newModel in onModelChange(newModel) }
                )) {
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Divider()
                .overlay(Color.primary.opacity(0.06))

            // MODE Switcher (YOLO vs SAFE)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Mode")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("Mode", selection: Binding(
                        get: { currentMode.lowercased() },
                        set: { _ in onModeToggle() }
                    )) {
                        Text("YOLO").tag("yolo")
                        Text("SAFE").tag("safe")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }

                Text(currentMode.lowercased() == "yolo"
                     ? "Autonomous execution (zero prompt confirmation)."
                     : "Safe mode (prompts for tool & execution approvals).")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var lifecycleCard: some View {
        VStack(spacing: 8) {
            Button(action: onStop) {
                HStack {
                    Image(systemName: "stop.circle")
                    Text("Stop Member")
                }
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)

            Button(action: onRevive) {
                HStack {
                    Image(systemName: "arrow.counterclockwise.circle")
                    Text("Revive Member")
                }
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
    }

    // MARK: - Library Tab

    private var librarySection: some View {
        SessionLibraryView()
    }

    // MARK: - Computer Tab

    private var computerSection: some View {
        LiveTerminalView(viewModel: terminalViewModel)
    }
}
