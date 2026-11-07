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

    // Thread Path state (RFC-006 §2, §5)
    public var isThreadMode: Bool = false
    public var threadMessages: [ClientThreadMessage] = []
    public var threadMembers: [ClientMemberDetail] = []
    public var implicitHumanId: String = "human"
    public let onMentionAgent: (String) -> Void

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
        onDismissError: @escaping () -> Void = {},
        isThreadMode: Bool = false,
        threadMessages: [ClientThreadMessage] = [],
        threadMembers: [ClientMemberDetail] = [],
        implicitHumanId: String = "human",
        onMentionAgent: @escaping (String) -> Void = { _ in }
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
        self.isThreadMode = isThreadMode
        self.threadMessages = threadMessages
        self.threadMembers = threadMembers
        self.implicitHumanId = implicitHumanId
        self.onMentionAgent = onMentionAgent
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Grok Bot Centered Floating Chat Header
            canvasHeader

            // Thread Roster Bar (Collaborative multi-agent roster)
            if isThreadMode {
                ThreadRosterBar(
                    members: threadMembers,
                    onMentionAgent: onMentionAgent
                )
                Rectangle()
                    .fill(PharosDesignTokens.Colors.borderTranslucent)
                    .frame(height: PharosDesignTokens.Radii.hairline)
            }

            // Message Canvas Area
            if isThreadMode {
                // Thread Mode: Grok Bot reference conversational message stream
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            // Centered timestamp pill (.gb-timestamp)
                            Text("Today • Active Thread")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(PharosDesignTokens.Colors.inkTertiary)
                                .padding(.top, 12)
                                .padding(.bottom, 6)

                            ThreadChatListView(
                                messages: threadMessages,
                                members: threadMembers,
                                implicitHumanId: implicitHumanId,
                                activeError: activeError,
                                onDismissError: onDismissError,
                                onMentionAgent: onMentionAgent
                            )
                            .id("thread_bottom_anchor")
                        }
                    }
                    .onChange(of: threadMessages.count) { _, _ in
                        scrollProxy.scrollTo("thread_bottom_anchor", anchor: .bottom)
                    }
                }
            } else {
                // 1:1 Session Mode: DeepSeek Harness (DSH) WebKit Canvas
                if turns.isEmpty && liveStreamingText.isEmpty && liveReasoningText.isEmpty && activeApproval == nil {
                    emptyState
                } else {
                    PharosWebCanvasView(
                        turns: turns,
                        liveStreamingText: liveStreamingText,
                        liveReasoningText: liveReasoningText,
                        activeApproval: activeApproval,
                        isTurnInProgress: isTurnInProgress,
                        onResolveApproval: onResolveApproval
                    )
                }
            }

            // Floating Bottom Composer (.gb-composer-wrap)
            PharosComposerView(
                text: $composerText,
                placeholder: composerPlaceholder,
                isSteeringMode: isSteeringMode,
                onToggleSteering: onToggleSteering,
                onSend: onSendMessage
            )
        }
        .frame(minWidth: PharosDesignTokens.Layout.canvasMinChatWidth)
        .background(PharosDesignTokens.Colors.pane)
    }

    private var composerPlaceholder: String {
        if isThreadMode {
            return "Message #\(title)… (@agent to direct)"
        }
        if isSteeringMode {
            return "Steer \(title) mid-turn…"
        }
        return "Message \(title)…"
    }

    // MARK: - Header

    private var canvasHeader: some View {
        ZStack {
            // Centered Signature Floating Chat Pill (.gb-chat-pill)
            Button(action: onToggleDetails) {
                HStack(spacing: 8) {
                    PharosAvatarView(
                        seed: title,
                        status: isTurnInProgress ? .working : .idle,
                        size: 28,
                        showRing: false
                    )

                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)

                        if let kind = agentKind {
                            Text(kind.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(PharosDesignTokens.Colors.hoverNeutral)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                        }

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(PharosDesignTokens.Colors.inkTertiary)
                    }
                }
                .padding(.vertical, 3)
                .padding(.trailing, 12)
                .padding(.leading, 4)
                .background(
                    Capsule()
                        .fill(PharosDesignTokens.Colors.elevated)
                )
                .overlay(
                    Capsule()
                        .stroke(PharosDesignTokens.Colors.borderTranslucent, lineWidth: PharosDesignTokens.Radii.hairline)
                )
                .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .help("Click to view details inspector")

            // Trailing Inspector Toggle Button
            HStack {
                Spacer()
                Button(action: onToggleDetails) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isDetailsOpen ? PharosDesignTokens.Colors.accent : PharosDesignTokens.Colors.inkSecondary)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(isDetailsOpen ? PharosDesignTokens.Colors.selectedNeutral : PharosDesignTokens.Colors.hoverNeutral)
                        )
                }
                .buttonStyle(.plain)
                .help("Toggle Details Inspector")
                .padding(.trailing, 16)
            }
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(PharosDesignTokens.Colors.chrome)
        .overlay(
            Rectangle()
                .fill(PharosDesignTokens.Colors.borderTranslucent)
                .frame(height: PharosDesignTokens.Radii.hairline),
            alignment: .bottom
        )
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
