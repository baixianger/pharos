import CoreImage
import CoreImage.CIFilterBuiltins
import PharosMeshProtocol
import SwiftUI
import UIKit

struct InviteDeviceSheet: View {
    @Environment(DistributedMeshSupport.self) private var distributedMesh
    @Environment(\.dismiss) private var dismiss
    @State private var invitationURL: URL?
    @State private var expiresAt: Date?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    InviteDeviceHeader()
                    if isLoading {
                        ProgressView("Creating a secure invitation…")
                            .frame(height: 280)
                    } else if let invitationURL,
                              let image = MobileQRCodeRenderer.image(
                                for: invitationURL.absoluteString
                              ) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 260, height: 260)
                            .accessibilityLabel("Pharos trusted-device invitation QR code")
                        if let expiresAt {
                            Text("Expires \(expiresAt, format: .dateTime.hour().minute().second())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ShareLink(
                            item: invitationURL,
                            subject: Text("Join my Pharos Mesh"),
                            message: Text("Open this signed, single-use invitation in Pharos. It expires after five minutes.")
                        ) {
                            Label("Share with AirDrop, Mail, or Messages", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Button("Copy invitation link", systemImage: "doc.on.doc") {
                            UIPasteboard.general.url = invitationURL
                        }
                        Button("Create a new invitation", systemImage: "arrow.clockwise") {
                            Task { await createInvitation() }
                        }
                    } else {
                        ContentUnavailableView {
                            Label("Invitation unavailable", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(errorMessage ?? "Pharos could not create an invitation.")
                        } actions: {
                            Button("Try Again") { Task { await createInvitation() } }
                        }
                    }
                    InviteDeviceSecurityNote()
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Invite a device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await createInvitation() }
    }

    @MainActor
    private func createInvitation() async {
        isLoading = true
        errorMessage = nil
        do {
            let url = try await distributedMesh.issueInvitation()
            invitationURL = url
            expiresAt = (try? MeshTrustInvitationLink.decode(url)).map {
                Date(timeIntervalSince1970:
                    Double($0.expiresAtMilliseconds) / 1_000)
            }
        } catch {
            invitationURL = nil
            expiresAt = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct InviteDeviceHeader: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Invite another trusted device")
                .font(.title2.weight(.semibold))
            Text("Scan nearby, or use the system share sheet to send the same magic link through AirDrop, Mail, or Messages.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }
}

private struct InviteDeviceSecurityNote: View {
    var body: some View {
        Label(
            "The invitation is signed, expires after five minutes, and can be redeemed once. Send it only to a device you control.",
            systemImage: "checkmark.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private enum MobileQRCodeRenderer {
    static func image(for value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 10, y: 10)
        ) else { return nil }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
