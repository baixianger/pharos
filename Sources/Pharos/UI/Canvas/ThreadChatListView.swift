import SwiftUI
import PharosClientKit

/// Renders the conversational chat bubble stream for multi-agent threads modeled faithfully on Grok Bot geometry.
/// Features `min(80%, 560px)` bubbles, specular linear gradient, 18px concentric radii,
/// 22px line height (`.lineSpacing(8)`), model-specific badges, rich @mention highlights, and delivery receipts.
public struct ThreadChatListView: View {
    public let messages: [ClientThreadMessage]
    public let members: [ClientMemberDetail]
    public let implicitHumanId: String
    public let activeError: PharosClientError?
    public let onDismissError: () -> Void
    public let onMentionAgent: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        messages: [ClientThreadMessage],
        members: [ClientMemberDetail] = [],
        implicitHumanId: String = "human",
        activeError: PharosClientError? = nil,
        onDismissError: @escaping () -> Void = {},
        onMentionAgent: @escaping (String) -> Void = { _ in }
    ) {
        self.messages = messages
        self.members = members
        self.implicitHumanId = implicitHumanId
        self.activeError = activeError
        self.onDismissError = onDismissError
        self.onMentionAgent = onMentionAgent
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    public var body: some View {
        LazyVStack(spacing: 16) {
            // Error banner if any
            if let error = activeError {
                errorBanner(error)
            }

            if messages.isEmpty {
                emptyThreadState
            } else {
                ForEach(messages) { message in
                    let isUser = isUserMessage(message)
                    if isUser {
                        userChatBubble(message)
                    } else {
                        agentChatBubble(message)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - User Chat Bubble (Grok Bot Blue Gradient, Right-Aligned)

    private func userChatBubble(_ message: ClientThreadMessage) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 48)

            VStack(alignment: .trailing, spacing: 4) {
                // Bubble Body Clamped to Grok Bot Max 560px
                VStack(alignment: .trailing, spacing: 6) {
                    formattedMessageText(message.text, isUser: true)
                        .font(.system(size: 14, weight: .regular))
                        .lineSpacing(8)
                        .tracking(-0.14)
                        .foregroundStyle(.white)

                    if !message.attachments.isEmpty {
                        attachmentsView(message.attachments, isUser: true)
                    }
                }
                .padding(.horizontal, PharosDesignTokens.Layout.bubblePaddingInline)
                .padding(.vertical, PharosDesignTokens.Layout.bubblePaddingBlock)
                .background(userBubbleBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: PharosDesignTokens.Layout.bubbleRadius)
                        .stroke(Color.white.opacity(0.18), lineWidth: PharosDesignTokens.Radii.hairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: PharosDesignTokens.Layout.bubbleRadius))
                .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1.5)
                .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 4)

                // Metadata: Timestamp + 4-Stage Delivery Receipt
                HStack(spacing: 5) {
                    Text(formatTime(message.timestamp))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(PharosDesignTokens.Colors.inkTertiary)

                    deliveryReceiptBadge(message.receipt)
                }
                .padding(.trailing, 4)
            }
            .frame(maxWidth: 560, alignment: .trailing)
        }
    }

    private var userBubbleBackground: some View {
        LinearGradient(
            colors: isDark ? [
                Color(red: 30/255, green: 134/255, blue: 252/255),
                Color(red: 17/255, green: 109/255, blue: 210/255)
            ] : [
                Color(red: 22/255, green: 128/255, blue: 243/255),
                Color(red: 14/255, green: 102/255, blue: 201/255)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Agent Chat Bubble (Grok Bot Multi-Agent Card, Left-Aligned)

    private func agentChatBubble(_ message: ClientThreadMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Grok Bot Expressive Procedural Avatar (32px)
            PharosAvatarView(
                seed: message.senderAvatarSeed ?? message.senderName,
                status: .idle,
                size: 32,
                showRing: false
            )

            VStack(alignment: .leading, spacing: 4) {
                // Sender Header: Name, Model Pill Badge, Timestamp
                HStack(spacing: 6) {
                    Text(message.senderName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)

                    agentModelBadge(for: message.senderName)

                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(PharosDesignTokens.Colors.inkTertiary)

                    Text(formatTime(message.timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(PharosDesignTokens.Colors.inkTertiary)
                }

                // Bubble Body Clamped to Grok Bot Max 560px
                VStack(alignment: .leading, spacing: 6) {
                    formattedMessageText(message.text, isUser: false)
                        .font(.system(size: 14, weight: .regular))
                        .lineSpacing(8)
                        .tracking(-0.14)
                        .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)

                    if !message.attachments.isEmpty {
                        attachmentsView(message.attachments, isUser: false)
                    }
                }
                .padding(.horizontal, PharosDesignTokens.Layout.bubblePaddingInline)
                .padding(.vertical, PharosDesignTokens.Layout.bubblePaddingBlock)
                .background(PharosDesignTokens.Colors.bubbleAgent)
                .overlay(
                    RoundedRectangle(cornerRadius: PharosDesignTokens.Layout.bubbleRadius)
                        .stroke(PharosDesignTokens.Colors.borderTranslucent, lineWidth: PharosDesignTokens.Radii.hairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: PharosDesignTokens.Layout.bubbleRadius))
                .shadow(color: Color.black.opacity(0.04), radius: 3, x: 0, y: 1)
            }
            .frame(maxWidth: 560, alignment: .leading)

            Spacer(minLength: 48)
        }
    }

    // MARK: - Model Pill Badge

    @ViewBuilder
    private func agentModelBadge(for name: String) -> some View {
        let info = badgeInfo(for: name)
        Text(info.text)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(info.tint.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 3.5))
            .foregroundStyle(info.tint)
    }

    private func badgeInfo(for name: String) -> (text: String, tint: Color) {
        let lower = name.lowercased()
        if lower.contains("codex") {
            return ("CODEX", Color(red: 0/255, green: 201/255, blue: 114/255))
        } else if lower.contains("agy") || lower.contains("antigravity") || lower.contains("gemini") {
            return ("AGY", Color(red: 169/255, green: 126/255, blue: 254/255))
        } else if lower.contains("dsh") || lower.contains("deepseek") {
            return ("DEEPSEEK", Color(red: 65/255, green: 118/255, blue: 230/255))
        } else if lower.contains("claude") {
            return ("CLAUDE", Color(red: 217/255, green: 119/255, blue: 6/255))
        } else {
            return ("AGENT", PharosDesignTokens.Colors.inkSecondary)
        }
    }

    // MARK: - Rich Text with Mention Highlights

    @ViewBuilder
    private func formattedMessageText(_ text: String, isUser: Bool) -> some View {
        // Highlight @mentions in text (e.g., @codex, @all)
        if text.contains("@") {
            let words = text.split(separator: " ", omittingEmptySubsequences: false)
            Text(words.enumerated().map { index, word in
                let str = String(word)
                return str.hasPrefix("@") ? "**\(str)**" : str
            }.joined(separator: " "))
        } else {
            Text(text)
        }
    }

    // MARK: - Delivery Receipt Badge

    private func deliveryReceiptBadge(_ receipt: DeliveryReceiptState) -> some View {
        HStack(spacing: 3) {
            switch receipt {
            case .pending:
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("Sending…")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

            case .delivered:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Text("Delivered")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

            case .consumed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(red: 22/255, green: 128/255, blue: 243/255))
                Text("Read")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(red: 22/255, green: 128/255, blue: 243/255))

            case .unverifiedFallback:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text("Unverified")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Attachments View

    private func attachmentsView(_ attachments: [CanonicalAttachment], isUser: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(attachments, id: \.filename) { att in
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 10))
                    Text(att.filename)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isUser ? Color.white.opacity(0.18) : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isUser ? .white : PharosDesignTokens.Colors.inkPrimary)
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: PharosClientError) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)

            Text(error.localizedDescription)
                .font(.system(size: 12))
                .foregroundStyle(.primary)

            Spacer()

            Button(action: onDismissError) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Empty State (Grok Bot Style)

    private var emptyThreadState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(PharosDesignTokens.Colors.hoverNeutral)
                    .frame(width: 54, height: 54)

                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 24))
                    .foregroundStyle(PharosDesignTokens.Colors.accent)
            }

            Text("Team Chatroom")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)

            Text("Send messages to collaborate with all active agents, or use @agent to direct instructions.")
                .font(.system(size: 12))
                .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.top, 40)
    }

    // MARK: - Helpers

    private func isUserMessage(_ msg: ClientThreadMessage) -> Bool {
        let sender = msg.senderId.lowercased()
        return sender == implicitHumanId.lowercased() ||
               sender == "human" ||
               sender == "tester" ||
               sender == "you" ||
               msg.senderName.lowercased() == "you"
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
