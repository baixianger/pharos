import SwiftUI
import PharosClientKit

/// Roster bar displayed at the top of a collaborative group thread.
/// Shows active agent participants, their models, and activity status rings.
/// Invariant: The human user is an implicit participant and never rendered in this roster list.
public struct ThreadRosterBar: View {
    public let members: [ClientMemberDetail]
    public let onMentionAgent: (String) -> Void

    public init(
        members: [ClientMemberDetail],
        onMentionAgent: @escaping (String) -> Void = { _ in }
    ) {
        self.members = members
        self.onMentionAgent = onMentionAgent
    }

    public var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text("\(members.count) agent\(members.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Divider()
                .frame(height: 14)
                .overlay(Color.primary.opacity(0.1))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(members) { member in
                        Button(action: {
                            onMentionAgent(member.name)
                        }) {
                            HStack(spacing: 5) {
                                // Agent Avatar View
                                PharosAvatarView(
                                    seed: member.avatarSeed,
                                    status: avatarStatus(from: member.status),
                                    size: 20,
                                    showRing: false
                                )

                                Text("@\(member.name)")
                                    .font(.system(size: 11, weight: .medium))

                                Text("• \(member.model)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3.5)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Click to mention @\(member.name) in thread")
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.02))
        .overlay(
            Divider()
                .overlay(Color.primary.opacity(0.06)),
            alignment: .bottom
        )
    }

    private func agentColor(for agent: String) -> Color {
        switch agent.lowercased() {
        case "codex": return .blue
        case "agy", "antigravity": return .purple
        case "dsh": return .orange
        default: return .teal
        }
    }

    private func statusColor(for status: String) -> Color {
        switch status.lowercased() {
        case "working", "busy": return .green
        case "needs_human", "attention": return .orange
        case "stopped", "offline": return .secondary
        default: return .blue
        }
    }

    private func avatarStatus(from status: String) -> AvatarActivityStatus {
        switch status.lowercased() {
        case "working", "busy": return .working
        case "needs_human", "attention": return .needsHuman
        case "stopped", "offline": return .stopped
        default: return .idle
        }
    }
}
