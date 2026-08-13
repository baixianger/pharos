import SwiftUI

/// A Slack/Discord-style message group. Consecutive messages from the same
/// sender can omit the avatar and identity line without losing authorship.
struct MessageRow: View {
    let message: MeshMessage
    let member: MeshMember?
    var showsHeader = true
    var onReply: (() -> Void)?
    var onOpenAttachment: ((MeshAttachment) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            if isHuman {
                Spacer(minLength: 40)
                humanMessageBody
            } else {
                VStack(alignment: .leading, spacing: showsHeader ? 6 : 2) {
                    if showsHeader {
                        identityBlock
                    }
                    // Agent content deliberately starts at the row's leading
                    // edge. The avatar belongs to identity, not to the text
                    // column, so long Markdown lines get the full width.
                    messageBody
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, showsHeader ? 8 : 1)
        .padding(.bottom, 2)
        .contentShape(.rect)
        // Let the system coordinate this horizontal action with the parent
        // ScrollView's vertical pan. A row-level DragGesture competes with
        // scrolling and was the source of intermittent touch hesitation.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let onReply {
                Button("Reply", systemImage: "arrowshape.turn.up.left") {
                    onReply()
                }
                .tint(.accentColor)
            }
        }
    }

    private var humanMessageBody: some View {
        messageBody
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 17))
            .overlay {
                RoundedRectangle(cornerRadius: 17)
                    .stroke(.secondary.opacity(0.12), lineWidth: 0.7)
            }
            .frame(maxWidth: 320, alignment: .trailing)
    }

    private var identityBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            ChatAvatar(name: displayName, member: member, isHuman: false)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(message.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                HStack(spacing: 7) {
                    Text(kindLabel ?? "AGENT")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                    if !message.to.isEmpty {
                        Text(message.to.map { "@\($0)" }.joined(separator: " "))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                    }
                }
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

    private var isHuman: Bool { message.from == "human" }
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
            PharosAgentGradient(name: name)
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

private struct PharosAgentGradient: View {
    let name: String

    private var variant: Int {
        abs(name.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % 12
    }

    var body: some View {
        GeometryReader { proxy in
            let size = max(proxy.size.width, proxy.size.height)
            ZStack {
                LinearGradient(colors: baseColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(blobColors.0).frame(width: size * 1.05).blur(radius: size * 0.22).offset(blobOffsets.0)
                Circle().fill(blobColors.1).frame(width: size * 0.92).blur(radius: size * 0.18).offset(blobOffsets.1)
                Circle().fill(blobColors.2).frame(width: size * 0.78).blur(radius: size * 0.16).offset(blobOffsets.2)
                LinearGradient(colors: [.white.opacity(0.28), .clear, .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            // The gradient is composed inside a circular boundary. It is not
            // a rounded-square export clipped into a circle; the rim and light
            // falloff are part of the avatar design itself.
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.82), edgeColor.opacity(0.58), .white.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: max(1, size * 0.035)
                    )
            }
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.22), lineWidth: max(0.7, size * 0.014))
                    .blur(radius: size * 0.025)
            }
            .shadow(color: edgeColor.opacity(0.34), radius: size * 0.13)
        }
    }

    private var baseColors: [Color] {
        [[.black, .cyan], [.indigo, .black], [.green, .black], [.blue, .purple],
         [.pink, .indigo], [.purple, .black], [.orange, .pink], [.green, .black],
         [.pink, .blue], [.indigo, .black], [.blue, .indigo], [.pink, .black]][variant]
    }

    private var blobColors: (Color, Color, Color) {
        let colors: [(Color, Color, Color)] = [
            (.cyan, .blue, .purple), (.yellow, .purple, .blue), (.green, .mint, .blue),
            (.cyan, .pink, .blue), (.pink, .purple, .blue), (.purple, .pink, .blue),
            (.orange, .pink, .purple), (.green, .mint, .yellow), (.pink, .blue, .white),
            (.purple, .pink, .blue), (.blue, .cyan, .purple), (.pink, .purple, .orange)
        ]
        return colors[variant]
    }

    private var edgeColor: Color {
        [
            .cyan, .yellow, .green, .cyan, .pink, .blue,
            .orange, .green, .pink, .purple, .blue, .pink
        ][variant]
    }

    private var blobOffsets: (CGSize, CGSize, CGSize) {
        let offsets: [(CGSize, CGSize, CGSize)] = [
            (offset(-12, -10), offset(14, 8), offset(-8, 14)), (offset(-10, -8), offset(14, 10), offset(10, -2)),
            (offset(-10, 0), offset(14, -8), offset(0, 13)), (offset(-12, -8), offset(12, 8), offset(4, -14)),
            (offset(-10, -12), offset(10, 12), offset(0, 0)), (offset(0, -10), offset(10, 12), offset(-12, 0)),
            (offset(-8, -10), offset(12, 8), offset(0, 14)), (offset(-12, 4), offset(12, -8), offset(0, 12)),
            (offset(-10, -8), offset(12, 10), offset(-8, 0)), (offset(-12, 0), offset(12, 0), offset(0, 12)),
            (offset(-10, -10), offset(10, 10), offset(0, -12)), (offset(-8, -12), offset(12, 8), offset(-10, 10))
        ]
        return offsets[variant]
    }

    private func offset(_ x: CGFloat, _ y: CGFloat) -> CGSize {
        CGSize(width: x, height: y)
    }
}
