import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PharosMeshCore
import SwiftUI

/// One desktop pairing assistant for the active Broker. The UI deliberately
/// does not reveal whether that Broker is local, another Mac, or Linux.
struct PairDeviceSheet: View {
    let endpoint: String
    @Environment(\.dismiss) private var dismiss
    @State private var pairingLink: String?
    @State private var errorMessage: String?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pair iPhone").font(.title2.weight(.semibold))
                    Text("Scan with Pharos on your iPhone")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            if loading {
                ProgressView("Creating a secure pairing code…")
                    .frame(width: 260, height: 260)
            } else if let pairingLink, let image = QRCodeRenderer.image(for: pairingLink) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 260, height: 260)
                    .accessibilityLabel("Pharos Broker pairing QR code")
                Text(endpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("This code expires in 5 minutes and works once.")
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
    }

    @MainActor
    private func createPairingLink() async {
        loading = true
        errorMessage = nil
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
