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

            Divider()
                .overlay(Color.primary.opacity(0.08))

            // Sub-tab content
            ScrollView {
                VStack(spacing: 14) {
                    switch selectedSubTab {
                    case .details:
                        detailsSection
                    case .library:
                        librarySection
                    case .computer:
                        computerSection
                    }
                }
                .padding(14)
            }
        }
        .frame(minWidth: PharosDesignTokens.Layout.detailsMinWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var inspectorHeader: some View {
        HStack(spacing: 8) {
            Picker("Inspector Tab", selection: $selectedSubTab) {
                ForEach(DetailsSubTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if isOverlay {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Inspector")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: PharosDesignTokens.Layout.titlebarHeight)
    }

    // MARK: - Details Tab

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Avatar Identity & Customizer Card
            avatarCard

            // Metadata Card
            metadataCard

            // Model & Mode Controls
            controlsCard

            // Lifecycle Operations
            lifecycleCard
        }
    }

    private var avatarCard: some View {
        VStack(spacing: 12) {
            Text("AVATAR IDENTITY")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                PharosAvatarView(
                    seed: memberName,
                    customShape: selectedShape,
                    customColor: selectedColor,
                    status: .working,
                    size: 56,
                    showRing: true
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(memberName)
                        .font(.system(size: 13, weight: .bold))

                    Picker("Shape", selection: $selectedShape) {
                        ForEach(AvatarShape.allCases) { shape in
                            Text(shape.displayName).tag(shape)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedShape) { _, newShape in
                        onAvatarChange(newShape, selectedColor)
                    }
                }
            }

            // Color Swatches
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AvatarPaletteColor.allCases.filter { $0 != .black }) { color in
                        Button(action: {
                            selectedColor = color
                            onAvatarChange(selectedShape, color)
                        }) {
                            Circle()
                                .fill(color.color(isDark: false))
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: selectedColor == color ? 2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(color.rawValue.capitalized)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
