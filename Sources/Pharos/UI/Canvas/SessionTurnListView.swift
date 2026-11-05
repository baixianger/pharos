import SwiftUI
import PharosClientKit

/// Renders the complete 1:1 direct agent session conversation stream,
/// including hierarchical turns, collapsible reasoning cards, tool executions,
/// live typing indicators, and inline approval dialogs.
public struct SessionTurnListView: View {
    public let turns: [CanonicalTurn]
    public let activeApproval: CanonicalApprovalRequest?
    public let activeError: PharosClientError?
    public let liveStreamingText: String
    public let liveReasoningText: String
    public let isTurnInProgress: Bool
    public let onResolveApproval: (ApprovalDecision) -> Void
    public let onDismissError: () -> Void

    public init(
        turns: [CanonicalTurn],
        activeApproval: CanonicalApprovalRequest? = nil,
        activeError: PharosClientError? = nil,
        liveStreamingText: String = "",
        liveReasoningText: String = "",
        isTurnInProgress: Bool = false,
        onResolveApproval: @escaping (ApprovalDecision) -> Void = { _ in },
        onDismissError: @escaping () -> Void = {}
    ) {
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
        VStack(spacing: 20) {
            // Error Banner (if any)
            if let error = activeError {
                errorBanner(error)
            }

            // Rendered Turns
            ForEach(turns) { turn in
                turnView(turn)
            }

            // Live streaming assistant bubble (when turn in progress)
            if isTurnInProgress && (!liveStreamingText.isEmpty || !liveReasoningText.isEmpty) {
                liveStreamingAssistantView
            }

            // Active Approval Request Card
            if let request = activeApproval {
                ApprovalDialogCardView(request: request, onResolve: onResolveApproval)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.vertical, 20)
    }

    // MARK: - Turn Rendering

    private func turnView(_ turn: CanonicalTurn) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(turn.steps) { step in
                ForEach(step.blocks) { block in
                    blockView(block)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: CanonicalBlock) -> some View {
        switch block.kind {
        case .userText(let text):
            userBubble(text)

        case .assistantText(let text):
            assistantBubble(text)

        case .reasoning(let reasoning):
            reasoningCard(title: "Thinking Process", content: reasoning.thinking)

        case .toolCall(let toolCall):
            toolCallCard(toolCall)

        case .toolResult(let result):
            toolResultCard(result)

        case .terminalCommand(let cmd):
            terminalCommandCard(cmd)

        case .filePatch(let patch):
            filePatchCard(patch)

        case .attachment(let att):
            attachmentCard(att)
        }
    }

    // MARK: - Chat Bubbles

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(Color(nsColor: .controlTextColor))
                .padding(.horizontal, PharosDesignTokens.Layout.bubblePaddingInline)
                .padding(.vertical, PharosDesignTokens.Layout.bubblePaddingBlock)
                .background(
                    RoundedRectangle(cornerRadius: PharosDesignTokens.Layout.bubbleRadius)
                        .fill(Color(nsColor: .selectedControlColor).opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PharosDesignTokens.Layout.bubbleRadius)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .frame(maxWidth: PharosDesignTokens.Layout.bubbleMaxStandardWidth, alignment: .trailing)
        }
        .padding(.horizontal, 20)
    }

    private func assistantBubble(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(Color.primary)
                .padding(.horizontal, PharosDesignTokens.Layout.bubblePaddingInline)
                .padding(.vertical, PharosDesignTokens.Layout.bubblePaddingBlock)
                .background(
                    RoundedRectangle(cornerRadius: PharosDesignTokens.Layout.bubbleRadius)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PharosDesignTokens.Layout.bubbleRadius)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .frame(maxWidth: PharosDesignTokens.Layout.bubbleMaxStandardWidth, alignment: .leading)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Reasoning & Tools Cards

    private func reasoningCard(title: String, content: String) -> some View {
        DisclosureGroup {
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
    }

    private func toolCallCard(_ call: CanonicalToolCall) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text("TOOL:")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)

            Text(call.toolName)
                .font(.system(size: 11, weight: .bold, design: .monospaced))

            Spacer()
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 20)
    }

    private func toolResultCard(_ res: CanonicalToolResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(res.isError ? "TOOL ERROR" : "TOOL OUTPUT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(res.isError ? Color.red : Color.secondary)
                Spacer()
            }
            Text(res.result.description)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .padding(8)
        .background(res.isError ? Color.red.opacity(0.06) : Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 20)
    }

    private func terminalCommandCard(_ cmd: CanonicalTerminalCommand) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("$ \(cmd.command)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green)
                Spacer()
                if let exit = cmd.exitCode {
                    Text("exit \(exit)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(exit == 0 ? Color.secondary : Color.red)
                }
            }
            if let out = cmd.stdout ?? cmd.stderr, !out.isEmpty {
                Text(out)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 20)
    }

    private func filePatchCard(_ patch: CanonicalFilePatch) -> some View {
        HStack {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 12))
            Text(patch.path)
                .font(.system(size: 11, design: .monospaced))
            Spacer()
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 20)
    }

    private func attachmentCard(_ att: CanonicalAttachment) -> some View {
        HStack {
            Image(systemName: "paperclip")
                .font(.system(size: 12))
            Text(att.filename)
                .font(.system(size: 11))
            Spacer()
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 20)
    }

    // MARK: - Live Streaming Assistant View

    private var liveStreamingAssistantView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !liveReasoningText.isEmpty {
                reasoningCard(title: "Thinking…", content: liveReasoningText)
            }

            if !liveStreamingText.isEmpty {
                HStack {
                    Text(liveStreamingText)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, PharosDesignTokens.Layout.bubblePaddingInline)
                        .padding(.vertical, PharosDesignTokens.Layout.bubblePaddingBlock)
                        .background(
                            RoundedRectangle(cornerRadius: PharosDesignTokens.Layout.bubbleRadius)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: PharosDesignTokens.Layout.bubbleRadius)
                                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                        )
                    Spacer()
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: PharosClientError) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.red)

            switch error {
            case .backendUnreachable(let backend, let reason):
                Text("[\(backend.uppercased()) Unreachable]: \(reason)")
                    .font(.system(size: 12, weight: .medium))
            default:
                Text(error.localizedDescription)
                    .font(.system(size: 12, weight: .medium))
            }

            Spacer()

            Button(action: onDismissError) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
    }
}
