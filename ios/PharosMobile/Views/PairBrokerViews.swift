import SwiftUI
import VisionKit
import PharosMeshLifecycle
import PharosMeshProtocol
import UIKit

struct MeshSetupGuide: View {
    @Environment(PairingCoordinator.self) private var pairing
    @Environment(DistributedMeshSupport.self) private var distributedMesh
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showsScanner = false
    @State private var showsManualEntry = false
    @State private var manualLink = ""
    @State private var isCreating = false
    @State private var createError: String?
    @State private var isResetting = false
    @State private var showsResetConfirmation = false

    var body: some View {
        @Bindable var pairing = pairing
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if horizontalSizeClass == .regular {
                        Text("Set up Pharos")
                            .font(.largeTitle.bold())
                            .padding(.bottom, 4)
                    }
                    SetupIntroSection()
                    CreatePersonalMeshSection(
                        isCreating: isCreating,
                        create: { Task { await createPersonalMesh() } }
                    )
                    ExistingMeshAvailabilitySection()
                    PairPhoneSection {
                        showsScanner = true
                    }
                    DisclosureGroup("Troubleshooting and manual pairing",
                                    isExpanded: $showsManualEntry) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Paste the trusted-device link shown by Pharos on your Mac or Linux device.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            TextField("pharos://device?…", text: $manualLink)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Pairing link")
                            Button("Open pairing link") {
                                pairing.receive(manualLink)
                            }
                            .disabled(manualLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Divider()
                            Button(
                                isResetting ? "Resetting…" : "Reset as a new Mesh device",
                                role: .destructive
                            ) {
                                showsResetConfirmation = true
                            }
                            .disabled(isResetting)
                            Text("Deletes this iPhone's local Mesh data and device identity. Other devices and their data are not changed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 12)
                    }
                    if let createError {
                        Text(createError).foregroundStyle(.red)
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
            .alert(
                "Couldn’t set up Mesh",
                isPresented: Binding(
                    get: { createError != nil },
                    set: { if !$0 { createError = nil } }
                )
            ) {
                Button("OK") { createError = nil }
            } message: {
                Text(createError ?? "Try again in a moment.")
            }
            .confirmationDialog(
                "Reset this iPhone as a new Mesh device?",
                isPresented: $showsResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Local Mesh Data and Identity", role: .destructive) {
                    Task { await resetAsNewMeshDevice() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("After the reset, scan a fresh invitation. Other devices may still list the old iPhone until you remove it there.")
            }
        }
    }

    @MainActor
    private func createPersonalMesh() async {
        isCreating = true
        createError = nil
        do {
            _ = try await distributedMesh.createPersonalMesh()
            pairing.showsSetupGuide = false
        } catch {
            createError = error.localizedDescription
        }
        isCreating = false
    }

    @MainActor
    private func resetAsNewMeshDevice() async {
        isResetting = true
        createError = nil
        do {
            try await distributedMesh.resetAsNewMeshDevice()
        } catch {
            createError = error.localizedDescription
        }
        isResetting = false
    }
}

private struct SetupIntroSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Set up your personal Mesh")
                .font(.title2.weight(.semibold))
            Text("Every trusted device keeps its own signed local replica. No Broker or cloud service is the source of truth.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct CreatePersonalMeshSection: View {
    let isCreating: Bool
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("1. Create a new Mesh", systemImage: "plus.circle.fill")
                .font(.headline)
            Text("Start here when this is your first Pharos device. This iPhone becomes a Mesh admin device with its own signed local replica; it is not a central server.")
                .foregroundStyle(.secondary)
            Button(action: create) {
                if isCreating {
                    HStack { ProgressView(); Text("Creating…") }
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Create personal Mesh")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isCreating)
        }
    }
}

private struct ExistingMeshAvailabilitySection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Or join an existing Mesh", systemImage: "link.badge.plus")
                .font(.headline)
            DeploymentOption(
                symbol: "desktopcomputer",
                title: "A personal Mac",
                detail: "Open Pharos and keep it available while this iPhone pairs and performs its first sync."
            )
            DeploymentOption(
                symbol: "server.rack",
                title: "A personal VPC or Linux server",
                detail: "Run the distributed sync service as an optional always-on replica, not as a data authority."
            )
            Label("Iroh connects devices directly when possible and otherwise uses an encrypted relay. No public port or Tailscale setup is required.",
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
            Label("Join from another trusted device", systemImage: "qrcode.viewfinder")
                .font(.headline)
            Text("On another device, choose Invite a device. Open its magic link from AirDrop, Mail, or Messages, or scan its QR code here. For a headless Linux replica, run:")
                .foregroundStyle(.secondary)
            Text("pharos-mesh distributed sync-serve --data-dir /var/lib/pharos-mesh --invite-file /tmp/pharos-invite.txt")
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
    @Environment(PairingCoordinator.self) private var pairing
    @Environment(\.dismiss) private var dismiss
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var didConnect = false
    @State private var now = Date()
    @State private var requiresDeviceReset = false
    @State private var showsResetConfirmation = false

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
                    if invitation.requestedRoles.contains(.controller) {
                        Label(
                            "This device will be a Mesh Admin and can approve, invite, or remove trusted devices.",
                            systemImage: "person.badge.key.fill"
                        )
                        .foregroundStyle(.tint)
                    }
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
                        if requiresDeviceReset {
                            Button("Reset This iPhone and Retry", role: .destructive) {
                                showsResetConfirmation = true
                            }
                            .disabled(isConnecting || isExpired)
                        }
                    }
                }
                Section {
                    Button {
                        Task { await connect(.archive) }
                    } label: {
                        if isConnecting {
                            HStack { ProgressView(); Text("Pairing…") }
                        } else if isExpired {
                            Text("Code expired")
                        } else if switchesPersonalMesh {
                            Text("Archive current Mesh and switch")
                        } else {
                            Text("Trust and connect")
                        }
                    }
                    .disabled(isConnecting || isExpired)
                    if switchesPersonalMesh {
                        Button("Leave current Mesh and switch", role: .destructive) {
                            Task { await connect(.leave) }
                        }
                        .disabled(isConnecting || isExpired)
                    }
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
        .confirmationDialog(
            "Reset this iPhone and retry pairing?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Local Mesh Data and Retry", role: .destructive) {
                Task { await resetAndRetry() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This creates a completely new device identity. Other devices keep their data and may still list the old iPhone until it is removed there.")
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
            return "Mesh Admin (controller) + signed data replica"
        }
        if roles.contains(.controller) { return "Mesh Admin (controller)" }
        if roles.contains(.replica) { return "Signed data replica" }
        return "Trusted-device access"
    }

    private func abbreviated(_ value: String) -> String {
        value.count > 16 ? "\(value.prefix(8))…\(value.suffix(8))" : value
    }

    @MainActor
    private func connect(_ disposition: MeshExistingGroupDisposition) async {
        isConnecting = true
        errorMessage = nil
        requiresDeviceReset = false
        do {
            try await distributedMesh.accept(
                invitation,
                displayName: UIDevice.current.name,
                existingGroupDisposition: disposition
            )
            didConnect = true
            pairing.showsSetupGuide = false
        } catch {
            errorMessage = "Pairing failed: \(error.localizedDescription)"
            requiresDeviceReset = (error as? MeshTrustGroupLifecycleError) ==
                .archivedReplicaNeedsReset
        }
        isConnecting = false
    }

    @MainActor
    private func resetAndRetry() async {
        isConnecting = true
        errorMessage = nil
        requiresDeviceReset = false
        do {
            try await distributedMesh.resetAsNewMeshDevice()
            try await distributedMesh.accept(
                invitation,
                displayName: UIDevice.current.name,
                existingGroupDisposition: .archive
            )
            didConnect = true
            pairing.showsSetupGuide = false
        } catch {
            errorMessage = "Pairing failed: \(error.localizedDescription)"
            requiresDeviceReset = (error as? MeshTrustGroupLifecycleError) ==
                .archivedReplicaNeedsReset
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
                            .accessibilityLabel("Pairing link")
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
                    .accessibilityLabel("Pairing link")
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
