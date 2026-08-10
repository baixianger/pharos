import AppKit
import PharosMeshCore
import PharosMeshLifecycle
import SwiftUI

struct PendingMacMeshInvitation: Identifiable {
    let invitation: MeshTrustInvitation
    var id: String {
        invitation.trustGroupID.rawValue.uuidString + ":" +
            invitation.inviterDeviceID.rawValue.uuidString
    }
}

struct MeshSetupView: View {
    @Environment(DistributedMeshSupport.self) private var distributedMesh
    @State private var joinLink = ""
    @State private var isCreating = false
    @State private var isJoining = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                MeshSetupHeader()
                MeshCreateSection(
                    isWorking: isCreating,
                    create: { Task { await createMesh() } }
                )
                MeshJoinSection(
                    link: $joinLink,
                    isWorking: isJoining,
                    join: { Task { await joinMesh() } }
                )
                MeshSetupPrinciples()
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .padding(40)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }

    @MainActor
    private func createMesh() async {
        isCreating = true
        errorMessage = nil
        do { _ = try await distributedMesh.createPersonalMesh() }
        catch { errorMessage = error.localizedDescription }
        isCreating = false
    }

    @MainActor
    private func joinMesh() async {
        guard let invitation = decodeMeshInvitation(joinLink) else {
            errorMessage = "Paste a valid, unexpired Pharos device invitation."
            return
        }
        isJoining = true
        errorMessage = nil
        do {
            try await distributedMesh.accept(
                invitation,
                displayName: Host.current().localizedName ?? "This Mac",
                existingGroupDisposition: .archive
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isJoining = false
    }
}

private struct MeshSetupHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Set up your personal Mesh")
                .font(.largeTitle.weight(.semibold))
            Text("Create a new signed local-first Mesh, or join one already running on another trusted device.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MeshCreateSection: View {
    let isWorking: Bool
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Create a new Mesh", systemImage: "plus.circle.fill")
                .font(.title2.weight(.semibold))
            Text("This Mac becomes the first Mesh admin device and keeps the first signed replica. It is not a central server; invite another admin-capable device for recovery.")
                .foregroundStyle(.secondary)
            Button(action: create) {
                if isWorking {
                    HStack { ProgressView().controlSize(.small); Text("Creating…") }
                } else {
                    Text("Create personal Mesh")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(isWorking)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct MeshJoinSection: View {
    @Binding var link: String
    let isWorking: Bool
    let join: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Join an existing Mesh", systemImage: "link.badge.plus")
                .font(.title2.weight(.semibold))
            Text("Open the invitation received through AirDrop, Mail, Messages, or paste it below.")
                .foregroundStyle(.secondary)
            TextField("pharos://device?…", text: $link)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            Button(action: join) {
                if isWorking {
                    HStack { ProgressView().controlSize(.small); Text("Joining…") }
                } else {
                    Text("Join Mesh")
                }
            }
            .buttonStyle(.glass)
            .disabled(isWorking || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct MeshSetupPrinciples: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Every device keeps its own signed local replica", systemImage: "internaldrive")
            Label("Iroh connects directly or through an encrypted relay", systemImage: "lock.shield")
            Label("Pairing links expire after five minutes and work once", systemImage: "timer")
            Label("Keep at least two Mesh admin devices for recovery", systemImage: "person.2.badge.key")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct JoinMeshSheet: View {
    @Environment(DistributedMeshSupport.self) private var distributedMesh
    @Environment(\.dismiss) private var dismiss
    @State private var link: String
    @State private var invitation: MeshTrustInvitation?
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(invitation: MeshTrustInvitation? = nil) {
        _link = State(initialValue: "")
        _invitation = State(initialValue: invitation)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if let invitation {
                    MeshJoinReview(
                        invitation: invitation,
                        isSwitching: distributedMesh.activeTrustGroupID.map {
                            $0 != invitation.trustGroupID
                        } ?? false,
                        isWorking: isWorking,
                        archiveAndJoin: { Task { await join(.archive) } },
                        leaveAndJoin: { Task { await join(.leave) } }
                    )
                } else {
                    MeshJoinEntry(link: $link) {
                        guard let decoded = decodeMeshInvitation(link) else {
                            errorMessage = "Paste a valid, unexpired Pharos device invitation."
                            return
                        }
                        invitation = decoded
                        errorMessage = nil
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(width: 480)
            .navigationTitle("Join a Mesh")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @MainActor
    private func join(_ disposition: MeshExistingGroupDisposition) async {
        guard let invitation else { return }
        isWorking = true
        errorMessage = nil
        do {
            try await distributedMesh.accept(
                invitation,
                displayName: Host.current().localizedName ?? "This Mac",
                existingGroupDisposition: disposition
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}

private struct MeshJoinEntry: View {
    @Binding var link: String
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Paste an invitation", systemImage: "link")
                .font(.title2.weight(.semibold))
            Text("Invitations can arrive through AirDrop, Mail, Messages, or copy and paste.")
                .foregroundStyle(.secondary)
            TextField("pharos://device?…", text: $link)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            Button("Review invitation", action: review)
                .buttonStyle(.glassProminent)
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct MeshJoinReview: View {
    let invitation: MeshTrustInvitation
    let isSwitching: Bool
    let isWorking: Bool
    let archiveAndJoin: () -> Void
    let leaveAndJoin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Signed device invitation", systemImage: "checkmark.shield.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
            LabeledContent("Personal Mesh") {
                Text(abbreviatedMeshValue(invitation.trustGroupID.rawValue.uuidString))
                    .font(.caption.monospaced())
            }
            LabeledContent("Inviting endpoint") {
                Text(abbreviatedMeshValue(invitation.inviterEndpointID.rawValue))
                    .font(.caption.monospaced())
            }
            if isSwitching {
                Text("This Mac already uses another Mesh. You can archive it locally, or leave it with a signed membership update before switching.")
                    .foregroundStyle(.secondary)
                Button("Archive current Mesh and switch", action: archiveAndJoin)
                    .buttonStyle(.glassProminent)
                Button("Leave current Mesh and switch", role: .destructive, action: leaveAndJoin)
                    .disabled(isWorking)
                Text("Leaving requires another online Mesh admin device. Archiving keeps the old Mesh only in local history and does not revoke this Mac remotely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Trust and join", action: archiveAndJoin)
                    .buttonStyle(.glassProminent)
            }
            if isWorking { ProgressView("Connecting securely…") }
        }
    }
}

func decodeMeshInvitation(_ value: String) -> MeshTrustInvitation? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed),
       let invitation = try? MeshTrustInvitationLink.decode(url) {
        return invitation
    }
    return try? MeshTrustInvitationTicket.decode(trimmed)
}

private func abbreviatedMeshValue(_ value: String) -> String {
    value.count > 20 ? "\(value.prefix(10))…\(value.suffix(10))" : value
}
