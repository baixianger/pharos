import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PharosMeshCore
import SwiftUI

/// One desktop pairing assistant for trusted devices. Distributed pairing
/// exchanges signed device identity; legacy Broker pairing stays behind the
/// explicit compatibility runtime mode.
struct PairDeviceSheet: View {
    let endpoint: String
    @Environment(DistributedMeshSupport.self) private var distributedMesh
    @Environment(\.dismiss) private var dismiss
    @State private var pairingLink: String?
    @State private var invitation: MeshTrustInvitation?
    @State private var errorMessage: String?
    @State private var loading = true
    @State private var initialTrustedDeviceIDs: Set<UUID> = []
    @State private var pairedDeviceName: String?

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(distributedMesh.isProductModeEnabled ? "Invite a device" : "Pair a device")
                        .font(.title2.weight(.semibold))
                    Text(distributedMesh.isProductModeEnabled
                         ? "Scan nearby, or send the magic link privately"
                         : "Open Pharos on the other device and scan this code")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            if loading {
                ProgressView("Creating a secure pairing code…")
                    .frame(width: 260, height: 260)
            } else if let pairedDeviceName {
                ContentUnavailableView(
                    "Device connected",
                    systemImage: "checkmark.circle.fill",
                    description: Text("\(pairedDeviceName) joined your personal Mesh and can now replicate data.")
                )
                .symbolRenderingMode(.multicolor)
                .frame(width: 300, height: 300)
            } else if let pairingLink, let image = QRCodeRenderer.image(for: pairingLink) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 260, height: 260)
                    .accessibilityLabel("Pharos trusted-device invitation QR code")
                if !distributedMesh.isProductModeEnabled {
                    Text(endpoint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                PairingExpiryLabel(
                    expiresAtMilliseconds: invitation?.expiresAtMilliseconds,
                    createNewCode: distributedMesh.isProductModeEnabled
                        ? { Task { await createPairingLink() } } : nil
                )
                Label(
                    "Lets this device sync your data and approve signed agent controls",
                    systemImage: "person.badge.key.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button(
                    distributedMesh.isProductModeEnabled
                        ? "Copy invitation link" : "Copy pairing link",
                    systemImage: "doc.on.doc"
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pairingLink, forType: .string)
                }
                if let url = URL(string: pairingLink) {
                    ShareLink(
                        item: url,
                        subject: Text("Join my Pharos Mesh"),
                        message: Text("Open this signed, single-use invitation in Pharos. It expires after five minutes.")
                    ) {
                        Label("Share with AirDrop, Mail, or Messages", systemImage: "square.and.arrow.up")
                    }
                }
            } else {
                ContentUnavailableView("Pairing unavailable",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage ?? "Pharos did not create a pairing code."))
                Button("Try Again") { Task { await createPairingLink() } }
            }
        }
        .padding(24)
        .frame(width: 420)
        .frame(minHeight: 440)
        .task { await createPairingLink() }
        .task(id: pairingLink) { await watchForPairedDevice() }
    }

    @MainActor
    private func createPairingLink() async {
        loading = true
        errorMessage = nil
        pairedDeviceName = nil
        if distributedMesh.isProductModeEnabled {
            do {
                initialTrustedDeviceIDs = Set(
                    distributedMesh.trustedDevices.map { $0.descriptor.id.rawValue }
                )
                let url = try await distributedMesh.issueInvitation()
                invitation = try MeshTrustInvitationLink.decode(url)
                pairingLink = url.absoluteString
                loading = false
                return
            } catch {
                pairingLink = nil
                errorMessage = "The distributed Mesh endpoint is not ready: \(error)"
                loading = false
                return
            }
        }
        let response = await Task.detached {
            MeshClient.send(MeshRequest(cmd: "pairing-create", timeoutMs: 300_000,
                                        host: endpoint))
        }.value
        guard !Task.isCancelled else { return }
        if response.ok, let payload = response.payload,
           let url = URL(string: payload), MeshPairingLink(url: url) != nil {
            pairingLink = payload
        } else {
            pairingLink = nil
            errorMessage = response.error ?? "Update the active Broker to a version that supports pairing."
        }
        loading = false
    }

    @MainActor
    private func watchForPairedDevice() async {
        guard distributedMesh.isProductModeEnabled, pairingLink != nil else { return }
        while !Task.isCancelled, pairedDeviceName == nil {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            try? await distributedMesh.refreshTrustedDevices()
            if let joined = distributedMesh.trustedDevices.first(where: {
                !initialTrustedDeviceIDs.contains($0.descriptor.id.rawValue)
            }) {
                pairedDeviceName = joined.descriptor.displayName
            }
        }
    }
}

private struct PairingExpiryLabel: View {
    let expiresAtMilliseconds: Int64?
    let createNewCode: (() -> Void)?

    var body: some View {
        if let expiresAtMilliseconds {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                PairingRemainingLabel(
                    expiration: Date(
                        timeIntervalSince1970:
                            Double(expiresAtMilliseconds) / 1_000
                    ),
                    now: context.date,
                    createNewCode: createNewCode
                )
            }
        } else {
            Text("This code expires in 5 minutes and works once.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct PairingRemainingLabel: View {
    let expiration: Date
    let now: Date
    let createNewCode: (() -> Void)?

    var body: some View {
        let seconds = max(0, Int(expiration.timeIntervalSince(now)))
        VStack(spacing: 8) {
            Label {
                if seconds > 0 {
                    Text("Expires in \(seconds / 60):\(seconds % 60, format: .number.precision(.integerLength(2))) · works once")
                } else {
                    Text("This pairing code has expired")
                }
            } icon: {
                Image(systemName: seconds > 0 ? "timer" : "exclamationmark.triangle.fill")
            }
            .foregroundStyle(seconds > 0 ? Color.secondary : Color.orange)
            if seconds == 0, let createNewCode {
                Button("Create new code", systemImage: "arrow.clockwise") {
                    createNewCode()
                }
            }
        }
    }
}

private enum QRCodeRenderer {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width,
                                                      height: output.extent.height))
    }
}
