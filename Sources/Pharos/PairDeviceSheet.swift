import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PharosMeshCore
import SwiftUI

/// One desktop pairing assistant for the active Broker. The UI deliberately
/// does not reveal whether that Broker is local, another Mac, or Linux.
struct PairDeviceSheet: View {
    let endpoint: String
    @Environment(DistributedMeshSupport.self) private var distributedMesh
    @Environment(\.dismiss) private var dismiss
    @State private var pairingLink: String?
    @State private var invitation: MeshTrustInvitation?
    @State private var errorMessage: String?
    @State private var loading = true
    @State private var initialTrustedDeviceCount = 0
    @State private var pairedDeviceName: String?

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pair a device").font(.title2.weight(.semibold))
                    Text("Scan with Pharos on your other device")
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
                    .accessibilityLabel("Pharos Broker pairing QR code")
                if !distributedMesh.isProductModeEnabled {
                    Text(endpoint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                PairingExpiryLabel(expiresAtMilliseconds: invitation?.expiresAtMilliseconds)
                Label(
                    "Grants controller and replica access to your personal Mesh",
                    systemImage: "person.badge.key.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Copy pairing link", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pairingLink, forType: .string)
                }
            } else {
                ContentUnavailableView("Pairing unavailable",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage ?? "The Broker did not create a pairing code."))
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
                initialTrustedDeviceCount = distributedMesh.trustedDevices.count
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
            if distributedMesh.trustedDevices.count > initialTrustedDeviceCount {
                pairedDeviceName = distributedMesh.trustedDevices.last?.descriptor.displayName
                    ?? "The new device"
            }
        }
    }
}

private struct PairingExpiryLabel: View {
    let expiresAtMilliseconds: Int64?

    var body: some View {
        if let expiresAtMilliseconds {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                PairingRemainingLabel(
                    expiration: Date(
                        timeIntervalSince1970:
                            Double(expiresAtMilliseconds) / 1_000
                    ),
                    now: context.date
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

    var body: some View {
        let seconds = max(0, Int(expiration.timeIntervalSince(now)))
        Label {
            if seconds > 0 {
                Text("Expires in \(seconds / 60):\(seconds % 60, format: .number.precision(.integerLength(2))) · works once")
            } else {
                Text("Expired · create a new code")
            }
        } icon: {
            Image(systemName: seconds > 0 ? "timer" : "exclamationmark.triangle.fill")
        }
        .foregroundStyle(seconds > 0 ? Color.secondary : Color.orange)
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
