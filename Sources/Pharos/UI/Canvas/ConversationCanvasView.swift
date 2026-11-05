import SwiftUI
import PharosClientKit

/// The central conversation canvas pane, rendering 1:1 sessions or group threads.
public struct ConversationCanvasView: View {
    public let title: String
    public let subtitle: String?
    public let agentKind: String?
    public let machineName: String?
    public let status: String?
    public let isDetailsOpen: Bool
    public let onToggleDetails: () -> Void

    @Binding public var composerText: String
    public let isSteeringMode: Bool
    public let onToggleSteering: () -> Void
    public let onSendMessage: (String) -> Void

    // 1:1 Session Turn History & Streaming state
    public var turns: [CanonicalTurn] = []
    public var activeApproval: CanonicalApprovalRequest?
    public var activeError: PharosClientError?
    public var liveStreamingText: String = ""
    public var liveReasoningText: String = ""
    public var isTurnInProgress: Bool = false
    public let onResolveApproval: (ApprovalDecision) -> Void
    public let onDismissError: () -> Void

    public init(
        title: String,
        subtitle: String? = nil,
        agentKind: String? = nil,
        machineName: String? = nil,
        status: String? = nil,
        isDetailsOpen: Bool = false,
        onToggleDetails: @escaping () -> Void = {},
        composerText: Binding<String>,
        isSteeringMode: Bool = false,
        onToggleSteering: @escaping () -> Void = {},
        onSendMessage: @escaping (String) -> Void = { _ in },
        turns: [CanonicalTurn] = [],
        activeApproval: CanonicalApprovalRequest? = nil,
        activeError: PharosClientError? = nil,
        liveStreamingText: String = "",
        liveReasoningText: String = "",
        isTurnInProgress: Bool = false,
        onResolveApproval: @escaping (ApprovalDecision) -> Void = { _ in },
        onDismissError: @escaping () -> Void = {}
    ) {
        self.title = title
        self.subtitle = subtitle
        self.agentKind = agentKind
        self.machineName = machineName
        self.status = status
        self.isDetailsOpen = isDetailsOpen
        self.onToggleDetails = onToggleDetails
        self._composerText = composerText
        self.isSteeringMode = isSteeringMode
        self.onToggleSteering = onToggleSteering
        self.onSendMessage = onSendMessage
        self.turns = turns
        self.activeApproval = activeApproval
        self.activeError = activeError
        self.liveStreamingText = liveStreamingText
        self.liveReasoningText = liveReasoningText
        self.isTurnInProgress = isTurnInProgress
        self.onResolveApproval = onResolveApproval
        self.onDismissError = onDismissError
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            canvasHeader

            Divider()
                .overlay(Color.primary.opacity(0.08))

            // Message Scroll Canvas
            ScrollViewReader { scrollProxy in
                ScrollView {
                    if turns.isEmpty && liveStreamingText.isEmpty && liveReasoningText.isEmpty && activeApproval == nil {
                        emptyState
                    } else {
                        SessionTurnListView(
                            turns: turns,
                            activeApproval: activeApproval,
                            activeError: activeError,
                            liveStreamingText: liveStreamingText,
                            liveReasoningText: liveReasoningText,
                            isTurnInProgress: isTurnInProgress,
                            onResolveApproval: onResolveApproval,
                            onDismissError: onDismissError
                        )
                        .id("bottom_anchor")
                    }
                }
                .onChange(of: liveStreamingText) { _, _ in
                    scrollProxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
                .onChange(of: turns.count) { _, _ in
                    scrollProxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
            }

            Divider()
                .overlay(Color.primary.opacity(0.08))

            // Expandable Bottom Composer
            PharosComposerView(
                text: $composerText,
                placeholder: isSteeringMode ? "Steer \(title) mid-turn…" : "Message \(title)…",
                isSteeringMode: isSteeringMode,
                onToggleSteering: onToggleSteering,
                onSend: onSendMessage
            )
        }
        .frame(minWidth: PharosDesignTokens.Layout.canvasMinChatWidth)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Header

    private var canvasHeader: some View {
        HStack(spacing: 10) {
            // Avatar
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 32, height: 32)
                .overlay(
                    Text(title.prefix(1).uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                )

            // Title & Badges
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    if let kind = agentKind {
                        Text(kind.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    if let machine = machineName {
                        Text(machine)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Details Inspector Toggle
            Button(action: onToggleDetails) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isDetailsOpen ? Color.accentColor : Color.secondary)
                    .frame(width: 30, height: 30)
                    .background(isDetailsOpen ? Color.accentColor.opacity(0.12) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Toggle Details Inspector")
        }
        .padding(.horizontal, 16)
        .frame(height: PharosDesignTokens.Layout.titlebarHeight)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Text("Ready to start")
                .font(.system(size: 15, weight: .semibold))

            Text("Type a prompt below to interact directly with \(title).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(.top, 40)
    }
}
