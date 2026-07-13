import SwiftUI

struct MessageRow: View {
    let message: MeshMessage
    let member: MeshMember?

    var body: some View {
        if message.from == "human" { humanCard } else { agentWaterfall }
    }

    private var humanCard: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(message.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
            metadata
        }
        .padding(.horizontal, 16).padding(.leading, 40)
    }

    private var agentWaterfall: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text("@\(message.from)").font(.subheadline.weight(.semibold))
                if !message.to.isEmpty {
                    Text("→ " + message.to.map { "@\($0)" }.joined(separator: " "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                metadata
            }
            StableMarkdownView(content: message.text).equatable()
        }
        .padding(.horizontal, 16)
    }

    private var metadata: some View {
        Text(message.date, style: .time).font(.caption2).foregroundStyle(.tertiary)
    }

    private var statusColor: Color {
        switch member?.state.flatMap(MeshSessionState.init(rawValue:)) {
        case .busy: .orange
        case .blocked: .red
        case .stopped, .idle: .green
        case .gone: .gray.opacity(0.4)
        case nil: .gray
        }
    }
}

