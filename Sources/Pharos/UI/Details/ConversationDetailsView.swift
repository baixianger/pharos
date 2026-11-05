import SwiftUI
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

    public let onModelChange: (String) -> Void
    public let onModeToggle: () -> Void
    public let onStop: () -> Void
    public let onRevive: () -> Void

    public init(
        isOverlay: Bool = false,
        onClose: @escaping () -> Void = {},
        memberName: String = "agent",
        agentKind: String = "codex",
        machineName: String = "mini",
        currentModel: String = "gpt-4o",
        currentMode: String = "yolo",
        workspacePath: String = "~/workspace",
        onModelChange: @escaping (String) -> Void = { _ in },
        onModeToggle: @escaping () -> Void = {},
        onStop: @escaping () -> Void = {},
        onRevive: @escaping () -> Void = {}
    ) {
        self.isOverlay = isOverlay
        self.onClose = onClose
        self.memberName = memberName
        self.agentKind = agentKind
        self.machineName = machineName
        self.currentModel = currentModel
        self.currentMode = currentMode
        self.workspacePath = workspacePath
        self.onModelChange = onModelChange
        self.onModeToggle = onModeToggle
        self.onStop = onStop
        self.onRevive = onRevive
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header with sub-tabs & close button
            inspectorHeader

            Divider()
                .overlay(Color.primary.opacity(0.08))

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
            // Metadata Card
            VStack(alignment: .leading, spacing: 8) {
                Text("METADATA")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                metadataRow(label: "Name", value: memberName)
                metadataRow(label: "Agent", value: agentKind.uppercased())
                metadataRow(label: "Host Node", value: machineName)
                metadataRow(label: "Path", value: workspacePath)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Model & Mode Controls
            VStack(alignment: .leading, spacing: 10) {
                Text("CONTROLS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Model")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(currentModel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                HStack {
                    Text("Mode")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button(action: onModeToggle) {
                        Text(currentMode.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                currentMode == "yolo"
                                    ? PharosDesignTokens.Colors.statusWorking.opacity(0.18)
                                    : PharosDesignTokens.Colors.statusAttention.opacity(0.18)
                            )
                            .foregroundStyle(
                                currentMode == "yolo"
                                    ? PharosDesignTokens.Colors.statusWorking
                                    : PharosDesignTokens.Colors.statusAttention
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Lifecycle Operations
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
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("No artifacts attached")
                .font(.system(size: 13, weight: .medium))

            Text("Generated patches, logs, and files will appear here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(.top, 20)
    }

    // MARK: - Computer Tab

    private var computerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TMUX LIVE STREAM")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("$ pharos member status")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.green)
                Text("[tmux] pane active • 80x24 • UDS connected")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
