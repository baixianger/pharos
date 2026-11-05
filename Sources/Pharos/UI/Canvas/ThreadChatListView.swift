import SwiftUI
import PharosClientKit

/// Renders the plain conversational chat bubble stream for multi-agent threads (RFC-006 §5).
/// Enforces the plain bubble invariant: only final text and attachments are rendered.
/// Intermediate tool executions, thinking steps, and terminal outputs are strictly omitted.
public struct ThreadChatListView: View {
    public let messages: [ClientThreadMessage]
    public let members: [ClientMemberDetail]
    public let implicitHumanId: String
    public let activeError: PharosClientError?
    public let onDismissError: () -> Void
    public let onMentionAgent: (String) -> Void

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
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: - User Chat Bubble (Right-aligned)

    private func userChatBubble(_ message: ClientThreadMessage) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 48)

            VStack(alignment: .trailing, spacing: 4) {
                // Bubble Body
                Text(message.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                // Attachments if any
                if !message.attachments.isEmpty {
                    attachmentsView(message.attachments)
                }

                // Metadata: Timestamp + Delivery Receipt
                HStack(spacing: 5) {
                    Text(formatTime(message.timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    deliveryReceiptBadge(message.receipt)
                }
            }
        }
    }

    // MARK: - Agent Chat Bubble (Left-aligned)

    private func agentChatBubble(_ message: ClientThreadMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Agent Avatar
            Circle()
                .fill(agentColor(for: message.senderName).opacity(0.18))
                .frame(width: 30, height: 30)
                .overlay(
                    Text(message.senderName.prefix(1).uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(agentColor(for: message.senderName))
                )

            VStack(alignment: .leading, spacing: 4) {
                // Sender Name Header
                HStack(spacing: 6) {
                    Text(message.senderName)
                        .font(.system(size: 12, weight: .semibold))

                    Text("AGENT")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    Text(formatTime(message.timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                // Bubble Body
                Text(message.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                // Attachments if any
                if !message.attachments.isEmpty {
                    attachmentsView(message.attachments)
                }
            }

            Spacer(minLength: 48)
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
                    .foregroundStyle(Color.accentColor)
                Text("Read")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)

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

    private func attachmentsView(_ attachments: [CanonicalAttachment]) -> some View {
        HStack(spacing: 6) {
            ForEach(attachments, id: \.filename) { att in
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 10))
                    Text(att.filename)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
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

    // MARK: - Empty State

    private var emptyThreadState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.bubble.left")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Text("Group Conversation")
                .font(.system(size: 15, weight: .semibold))

            Text("Post a message below to broadcast to all participating agents, or use @agent to address a specific agent.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
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

    private func agentColor(for name: String) -> Color {
        let lower = name.lowercased()
        if lower.contains("codex") { return .blue }
        if lower.contains("agy") || lower.contains("antigravity") { return .purple }
        if lower.contains("dsh") { return .orange }
        return .teal
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
