import SwiftUI
import UIKit

/// A Slack/Discord-style message group. Consecutive messages from the same
/// sender can omit the avatar and identity line without losing authorship.
struct MessageRow: View {
    let message: MeshMessage
    let member: MeshMember?
    var showsHeader = true
    var onReply: (() -> Void)?
    var onOpenAttachment: ((MeshAttachment) -> Void)?

    @State private var swipeOffset: CGFloat = 0
    @State private var didTrigger = false
    private let replyThreshold: CGFloat = 60

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            if showsHeader {
                ChatAvatar(name: displayName, member: member, isHuman: isHuman)
            } else {
                Color.clear.frame(width: 38, height: 1)
            }

            VStack(alignment: .leading, spacing: showsHeader ? 5 : 2) {
                if showsHeader { identityLine }
                messageBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, showsHeader ? 8 : 1)
        .padding(.bottom, 2)
        .contentShape(.rect)
        .offset(x: swipeOffset)
        // Swipe-to-reply: a reply glyph trails the row as you drag right and
        // fires once past the threshold — avoids the long-press full-screen
        // preview for the common case.
        .overlay(alignment: .leading) {
            if onReply != nil, swipeOffset > 1 {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.callout)
                    .foregroundStyle(.tint)
                    .opacity(Double(min(swipeOffset / replyThreshold, 1)))
                    .scaleEffect(swipeOffset >= replyThreshold ? 1.15 : 0.9)
                    .offset(x: max(4, swipeOffset - 34))
            }
        }
        .gesture(replyDragGesture)
        .contextMenu {
            if let onReply {
                Button("Reply", systemImage: "arrowshape.turn.up.left") { onReply() }
            }
            Button("Copy message", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = message.text
            }
        }
    }

    private var replyDragGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard onReply != nil else { return }
                // Horizontal-rightward only, so vertical scrolling is unaffected.
                guard value.translation.width > abs(value.translation.height) else { return }
                let dx = min(max(0, value.translation.width), 90)
                swipeOffset = dx
                if dx >= replyThreshold, !didTrigger {
                    didTrigger = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
            .onEnded { _ in
                if didTrigger { onReply?() }
                didTrigger = false
                withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { swipeOffset = 0 }
            }
    }

    private var identityLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(displayName)
                .font(.subheadline.weight(.semibold))

            if let kindLabel {
                Text(kindLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isHuman ? Color.secondary : Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((isHuman ? Color.secondary : Color.accentColor).opacity(0.1), in: Capsule())
            }

            Text(message.date, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if !message.to.isEmpty {
                Text(message.to.map { "@\($0)" }.joined(separator: " "))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var messageBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let reply = message.replyTo { replyCard(reply) }

            if !message.text.isEmpty {
                if isHuman {
                    Text(message.text)
                        .font(.body)
                        .textSelection(.enabled)
                } else {
                    StableMarkdownView(content: message.text).equatable()
                }
            }

            ForEach(message.attachments ?? []) { attachment in
                Button { onOpenAttachment?(attachment) } label: { attachmentCard(attachment) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func replyCard(_ reply: MeshReply) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(reply.from == "human" ? "You" : reply.from)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(reply.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private func attachmentCard(_ attachment: MeshAttachment) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.1))
                Image(systemName: attachment.mimeType == "application/pdf" ? "doc.richtext" : "photo")
                    .foregroundStyle(.tint)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: 310)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
    }

    private var isHuman: Bool {
        message.authorMemberID?.hasPrefix("human@") == true ||
            (message.authorMemberID == nil && message.from == "human")
    }
    private var displayName: String { isHuman ? "You" : message.from }

    private var kindLabel: String? {
        if isHuman { return nil }
        return switch member?.kind?.lowercased() {
        case "codex": "CODEX"
        case "claude": "CLAUDE"
        case let value? where !value.isEmpty: value.uppercased()
        default: "AGENT"
        }
    }
}

struct ChatAvatar: View {
    let name: String
    let member: MeshMember?
    var isHuman = false
    var size: CGFloat = 38

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(avatarColor.gradient)
                .frame(width: size, height: size)
                .overlay {
                    if isHuman {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(.white)
                    } else {
                        Text(initials)
                            .font(.system(size: size * 0.31, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }

            if !isHuman {
                Circle()
                    .fill(presenceColor)
                    .frame(width: max(9, size * 0.27), height: max(9, size * 0.27))
                    .overlay(Circle().stroke(.background, lineWidth: 2))
                    .accessibilityLabel(presenceLabel)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(presenceLabel)")
    }

    private var initials: String {
        let pieces = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        let value = pieces.prefix(2).compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "A" : value.uppercased()
    }

    private var avatarColor: Color {
        if isHuman { return .accentColor }
        let palette: [Color] = [.indigo, .purple, .blue, .teal, .orange, .pink]
        let checksum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[checksum % palette.count]
    }

    private var presenceColor: Color {
        switch member?.state.flatMap(MeshSessionState.init(rawValue:)) {
        case .busy: .orange
        case .blocked: .red
        case .stopped, .idle: .green
        case .gone: .gray.opacity(0.45)
        case nil: .gray
        }
    }

    private var presenceLabel: String {
        switch member?.state.flatMap(MeshSessionState.init(rawValue:)) {
        case .busy: "Busy"
        case .blocked: "Blocked"
        case .stopped, .idle: "Available"
        case .gone: "Offline"
        case nil: "Unknown status"
        }
    }
}
