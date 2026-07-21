import SwiftUI
import VisionKit
import PharosMeshProtocol
import UIKit

struct BrokerSetupGuide: View {
    @Environment(PairingCoordinator.self) private var pairing
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showsScanner = false
    @State private var showsManualEntry = false
    @State private var manualLink = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if horizontalSizeClass == .regular {
                        Text("Set up Pharos")
                            .font(.largeTitle.bold())
                            .padding(.bottom, 4)
                    }
                    SetupIntroSection()
                    BrokerDeploymentSection()
                    PairPhoneSection {
                        showsScanner = true
                    }
                    DisclosureGroup("Troubleshooting and manual pairing",
                                    isExpanded: $showsManualEntry) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Paste the pairing link shown by Pharos on your Mac or Linux Broker.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            TextField("pharos://pair?…", text: $manualLink)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                            Button("Open pairing link") {
                                pairing.receive(manualLink)
                            }
                            .disabled(manualLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.top, 12)
                    }
                }
                .padding(.horizontal, horizontalSizeClass == .regular ? 44 : 20)
                .padding(.top, horizontalSizeClass == .regular ? 28 : 20)
                .padding(.bottom, horizontalSizeClass == .regular ? 40 : 20)
                .frame(maxWidth: horizontalSizeClass == .regular ? 760 : 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(horizontalSizeClass == .regular ? "" : "Set up Pharos")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        pairing.showsSetupGuide = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Close setup")
                    }
                }
            }
            .sheet(isPresented: $showsScanner) {
                PairingScannerSheet { value in
                    showsScanner = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        pairing.receive(value)
                    }
                }
            }
        }
    }
}

private struct SetupIntroSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("First, set up a Pharos Mesh Broker")
                .font(.title2.weight(.semibold))
            Text("The Broker privately stores your projects, issues, rooms, messages, and attachments. You only need one.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct BrokerDeploymentSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("1. Choose where the Broker runs", systemImage: "1.circle.fill")
                .font(.headline)
            DeploymentOption(
                symbol: "desktopcomputer",
                title: "A personal Mac",
                detail: "Install the Pharos DMG, open Pharos, and keep the Mac available when you want to sync."
            )
            DeploymentOption(
                symbol: "server.rack",
                title: "A personal VPC or Linux server",
                detail: "Install the pharos-mesh package and run its system service for an always-on Broker."
            )
            Label("Install and sign in to Tailscale on this iPhone and on the Broker machine. Keep both in the same private tailnet.",
                  systemImage: "lock.shield")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DeploymentOption: View {
    let symbol: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct PairPhoneSection: View {
    let scan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("2. Pair this iPhone", systemImage: "2.circle.fill")
                .font(.headline)
            Text("On a Mac, open Pharos → Settings → Machines and select Pair iPhone. On Linux, run:")
                .foregroundStyle(.secondary)
            Text("pharos-mesh pair --endpoint HOST:47800")
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            Button(action: scan) {
                Label("Scan pairing QR code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

struct PairBrokerConfirmation: View {
    let invitation: PairingLink
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var state: PairingValidationState = .checking
    private let client = MeshTCPClient()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Broker", value: invitation.endpoint)
                    LabeledContent("Identity", value: abbreviatedIdentity)
                    LabeledContent("Expires", value: Date(timeIntervalSince1970: invitation.expiresAt),
                                   format: .dateTime.hour().minute().second())
                }
                Section {
                    validationView
                }
                Section {
                    Button("Connect this iPhone") {
                        Task { await connect() }
                    }
                    .disabled(state != .ready || invitation.isExpired)
                } footer: {
                    Text("The pairing code is single-use. No SSH key, password, or Tailscale credential is transferred.")
                }
            }
            .navigationTitle("Pair with Broker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await validate() }
        }
    }

    private var abbreviatedIdentity: String {
        let value = invitation.brokerID
        return value.count > 16 ? "\(value.prefix(8))…\(value.suffix(8))" : value
    }

    @ViewBuilder
    private var validationView: some View {
        switch state {
        case .checking:
            HStack { ProgressView(); Text("Checking Broker…") }
        case .ready:
            Label("Compatible Pharos Mesh Broker", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .connecting:
            HStack { ProgressView(); Text("Pairing this iPhone…") }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @MainActor
    private func validate() async {
        guard !invitation.isExpired else {
            state = .failed("This pairing code has expired.")
            return
        }
        state = .checking
        do {
            let response = try await client.send(MeshRequest(cmd: "capabilities"),
                                                 host: invitation.host, port: invitation.port)
            guard response.capabilities?.contains("pairing-v2") == true else {
                state = .failed("Update the Broker before pairing this iPhone.")
                return
            }
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func connect() async {
        guard !invitation.isExpired else {
            state = .failed("This pairing code has expired.")
            return
        }
        state = .connecting
        do {
            var request = MeshRequest(cmd: "pairing-redeem")
            request.memberID = invitation.brokerID
            request.payload = invitation.token
            let response = try await client.send(request, host: invitation.host, port: invitation.port)
            guard let payload = response.payload, let data = payload.data(using: .utf8),
                  let credential = try? JSONDecoder().decode(MeshPairingCredential.self, from: data),
                  credential.brokerID == invitation.brokerID else {
                state = .failed("The Broker identity did not match the pairing code.")
                return
            }
            settings.updateMesh(host: invitation.host, port: invitation.port,
                                controlToken: credential.controlToken)
            dismiss()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct PairDeviceConfirmation: View {
    let invitation: MeshTrustInvitation
    @Environment(DistributedMeshSupport.self) private var distributedMesh
    @Environment(\.dismiss) private var dismiss
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var didConnect = false
    @State private var now = Date()

    var body: some View {
        NavigationStack {
            if didConnect {
                ContentUnavailableView {
                    Label("Device connected", systemImage: "checkmark.circle.fill")
                } description: {
                    Text("This iPhone now has its own signed replica and will sync directly with trusted devices.")
                } actions: {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .symbolRenderingMode(.multicolor)
                .navigationTitle("Pair device")
            } else {
                List {
                Section("Trusted device") {
                    LabeledContent(
                        "Device endpoint",
                        value: abbreviated(invitation.inviterEndpointID.rawValue)
                    )
                    LabeledContent(
                        "Pairing code",
                        value: isExpired
                            ? "Expired — scan a new code"
                            : "Expires in \(remainingSeconds / 60):" +
                                String(format: "%02d", remainingSeconds % 60)
                    )
                    .foregroundStyle(isExpired ? .orange : .primary)
                    Label(
                        "Endpoint identity verified by signature",
                        systemImage: "checkmark.shield.fill"
                    )
                    .foregroundStyle(.green)
                }
                Section("Access") {
                    LabeledContent(
                        "Access",
                        value: accessSummary
                    )
                    LabeledContent(
                        "Personal Mesh",
                        value: abbreviated(
                            invitation.trustGroupID.rawValue.uuidString
                        )
                    )
                    if switchesPersonalMesh {
                        Label(
                            "This iPhone is already using another personal Mesh. " +
                            "Continuing switches the active Mesh; its existing " +
                            "local data is kept and is not deleted.",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .foregroundStyle(.orange)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        if isConnecting {
                            HStack { ProgressView(); Text("Pairing…") }
                        } else if isExpired {
                            Text("Code expired")
                        } else {
                            Text(switchesPersonalMesh ? "Switch Mesh and connect" : "Trust and connect")
                        }
                    }
                    .disabled(isConnecting || isExpired)
                } footer: {
                    Text(
                        "The code is single-use. No IP address, password, " +
                        "or SSH key is transferred; the signature verifies the device."
                    )
                }
                }
                .navigationTitle("Pair device")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled, !didConnect, !isExpired {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
    }

    private var isExpired: Bool {
        invitation.expiresAtMilliseconds <=
            Int64(now.timeIntervalSince1970 * 1_000)
    }

    private var remainingSeconds: Int {
        max(0, Int(
            Double(invitation.expiresAtMilliseconds) / 1_000 -
                now.timeIntervalSince1970
        ))
    }

    private var switchesPersonalMesh: Bool {
        guard let current = distributedMesh.activeTrustGroupID else { return false }
        return current != invitation.trustGroupID
    }

    private var accessSummary: String {
        let roles = Set(invitation.requestedRoles)
        if roles.contains(.controller), roles.contains(.replica) {
            return "Data sync and signed agent control"
        }
        if roles.contains(.controller) { return "Signed agent control" }
        if roles.contains(.replica) { return "Data sync" }
        return "Trusted-device access"
    }

    private func abbreviated(_ value: String) -> String {
        value.count > 16 ? "\(value.prefix(8))…\(value.suffix(8))" : value
    }

    @MainActor
    private func connect() async {
        isConnecting = true
        errorMessage = nil
        do {
            try await distributedMesh.accept(
                invitation, displayName: UIDevice.current.name
            )
            didConnect = true
        } catch {
            errorMessage = "Pairing failed: \(error)"
        }
        isConnecting = false
    }
}

private enum PairingValidationState: Equatable {
    case checking
    case ready
    case connecting
    case failed(String)
}

struct PairingScannerSheet: View {
    var allowsLegacyBrokerLinks = true
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var manualLink = ""
    @State private var showsManualEntry = false
    @State private var validationError: String?
    @State private var showsValidationError = false

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported,
                   DataScannerViewController.isAvailable {
                    PairingDataScanner(onCode: receive)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView {
                        Label("Camera scanning unavailable", systemImage: "qrcode.viewfinder")
                    } description: {
                        Text("Paste the pairing link instead.")
                    } actions: {
                        TextField(
                            allowsLegacyBrokerLinks
                                ? "pharos://device?… or pharos://pair?…"
                                : "pharos://device?…",
                            text: $manualLink
                        )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Button("Continue") { receive(manualLink) }
                            .disabled(manualLink.isEmpty)
                    }
                    .padding()
                }
            }
            .navigationTitle("Scan Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if DataScannerViewController.isSupported,
                   DataScannerViewController.isAvailable {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Enter Link", systemImage: "keyboard") {
                            showsManualEntry = true
                        }
                    }
                }
            }
            .alert("Enter pairing link", isPresented: $showsManualEntry) {
                TextField(
                    allowsLegacyBrokerLinks
                        ? "pharos://device?… or pharos://pair?…"
                        : "pharos://device?…",
                    text: $manualLink
                )
                Button("Continue") { receive(manualLink) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Paste the link generated by Pharos on the device you want to trust.")
            }
            .alert(
                "Not a valid pairing code",
                isPresented: $showsValidationError
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationError ?? "Use a new code generated by Pharos.")
            }
        }
    }

    private func receive(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowsLegacyBrokerLinks || isTrustedDeviceInvitation(trimmed) else {
            validationError = "This screen accepts only a trusted-device invitation from the distributed Mesh."
            showsValidationError = true
            return
        }
        onCode(trimmed)
    }

    private func isTrustedDeviceInvitation(_ value: String) -> Bool {
        if (try? MeshTrustInvitationTicket.decode(value)) != nil { return true }
        guard let url = URL(string: value) else { return false }
        return (try? MeshTrustInvitationLink.decode(url)) != nil
    }
}

private struct PairingDataScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController,
                                          coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard let value = addedItems.compactMap({ item -> String? in
                if case .barcode(let barcode) = item { return barcode.payloadStringValue }
                return nil
            }).first else { return }
            guard !delivered else { return }
            delivered = true
            onCode(value)
        }
    }
}
