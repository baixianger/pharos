import PharosMeshCore
import SwiftUI

struct BrokerSetupOnboardingView: View {
    @Environment(ProjectStore.self) private var store
    let onComplete: () -> Void

    @State private var step = 1
    @State private var placement: BrokerPlacement = .thisMac
    @State private var pairingLink = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if step == 1 {
                    brokerStep
                } else {
                    iphoneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(.background)
        .onOpenURL { url in
            guard MeshPairingLink(url: url) != nil else { return }
            pairingLink = url.absoluteString
            placement = .anotherMac
        }
        .alert("Broker setup failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up Pharos").font(.title2.weight(.semibold))
                Text(step == 1 ? "1 of 2 · Mesh Broker" : "2 of 2 · Pharos for iPhone")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
    }

    private var brokerStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("First, set up a Pharos Mesh Broker")
                        .font(.largeTitle.weight(.semibold))
                    Text("The Broker privately coordinates your projects, issues, rooms, messages, and attachments. You only need one.")
                        .font(.title3).foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 12) {
                    ForEach(BrokerPlacement.allCases) { option in
                        placementButton(option)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label("Private networking with Tailscale", systemImage: "lock.shield")
                        .font(.headline)
                    Text("Install Tailscale and sign in with the same tailnet on this Mac and the Broker machine. Pharos does not require a public internet port.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        Link("Tailscale for macOS", destination: URL(string: "https://tailscale.com/download/mac")!)
                        Link("Tailscale for Linux", destination: URL(string: "https://tailscale.com/docs/install/linux")!)
                    }
                }
                .padding(18)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                placementInstructions
                actionArea
            }
            .padding(32)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func placementButton(_ option: BrokerPlacement) -> some View {
        Button {
            placement = option
            errorMessage = nil
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: option.symbol).font(.title2)
                Text(option.title).font(.headline)
                Text(option.subtitle)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .background(placement == option ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(placement == option ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var placementInstructions: some View {
        switch placement {
        case .thisMac:
            Label("Pharos will run the Broker on this Mac and advertise it only on its Tailscale address.",
                  systemImage: "desktopcomputer")
                .foregroundStyle(.secondary)
        case .anotherMac:
            remoteInstructions(
                title: "On the other Mac",
                detail: "Install and open the Pharos app, finish its Broker setup, then open Settings → Machines and copy a pairing link."
            )
        case .linux:
            remoteInstructions(
                title: "On the Linux server",
                detail: "Install pharos-mesh, start its system service, then run pharos-mesh pair --endpoint TAILSCALE-IP:47800."
            )
        }
    }

    private func remoteInstructions(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary)
            TextField("Paste pharos://pair link", text: $pairingLink)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
        }
    }

    private var actionArea: some View {
        HStack {
            Spacer()
            Button {
                Task { await configureBroker() }
            } label: {
                if isWorking {
                    ProgressView().controlSize(.small).frame(width: 150)
                } else {
                    Text(placement == .thisMac ? "Use this Mac" : "Pair with Broker")
                        .frame(width: 150)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking || (placement != .thisMac && pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
    }

    private var iphoneStep: some View {
        VStack(spacing: 26) {
            Spacer()
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 58, weight: .thin))
                .foregroundStyle(.tint)
            VStack(spacing: 10) {
                Text("Pharos for iPhone").font(.largeTitle.weight(.semibold))
                Text("Your single-person company in your pocket")
                    .font(.title2).foregroundStyle(.secondary)
            }
            Text("Stay close to projects, issues, agents, and group chat when you are away from your desk. Your iPhone connects privately through the same Mesh Broker.")
                .font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            VStack(alignment: .leading, spacing: 10) {
                Label("Install Pharos on your iPhone", systemImage: "1.circle.fill")
                Label("Sign in to the same Tailscale tailnet", systemImage: "2.circle.fill")
                Label("Later, open Settings → Machines → Pair iPhone… and scan the code", systemImage: "3.circle.fill")
            }
            .font(.headline)
            .padding(20)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            Spacer()
            HStack {
                Button("Back") { step = 1 }
                Spacer()
                Button("Open Pharos") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(28)
        }
        .padding(.horizontal, 32)
    }

    @MainActor
    private func configureBroker() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        switch placement {
        case .thisMac:
            let endpoint = await Task.detached {
                PairingService.selfTailscaleIP().map { "\($0):\(MeshRemote.port)" }
            }.value
            guard let endpoint else {
                errorMessage = "Install Tailscale, sign in, and make sure this Mac has a Tailscale IPv4 address."
                return
            }
            store.meshServerEndpoint = ""
            store.setMeshHub(true)
            let response = await Task.detached {
                MeshHosting.apply(hosting: true)
                return MeshClient.send(MeshRequest(cmd: "capabilities"), to: endpoint)
            }.value
            guard response.ok else {
                store.setMeshHub(false)
                errorMessage = response.error ?? "The Broker did not start on this Mac."
                return
            }
        case .anotherMac, .linux:
            guard let url = URL(string: pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let invitation = MeshPairingLink(url: url), !invitation.isExpired else {
                errorMessage = "Use a valid, unexpired Pharos pairing link."
                return
            }
            var request = MeshRequest(cmd: "pairing-redeem")
            request.memberID = invitation.brokerID
            request.payload = invitation.token
            let response = await Task.detached {
                MeshClient.send(request, to: invitation.endpoint)
            }.value
            guard response.ok, response.payload == invitation.brokerID else {
                errorMessage = response.error ?? "The Broker identity did not match the pairing link."
                return
            }
            store.setMeshHub(false)
            store.meshServerEndpoint = invitation.endpoint
            MeshClient.remoteEndpoint = invitation.endpoint
            MeshPaths.setDialEndpointFile(invitation.endpoint)
        }
        step = 2
    }
}

private enum BrokerPlacement: String, CaseIterable, Identifiable {
    case thisMac
    case anotherMac
    case linux

    var id: String { rawValue }
    var title: String {
        switch self {
        case .thisMac: "This Mac"
        case .anotherMac: "Another Mac"
        case .linux: "Personal VPC"
        }
    }
    var subtitle: String {
        switch self {
        case .thisMac: "The simplest setup for a Mac that is often online."
        case .anotherMac: "Use an always-on Mac elsewhere in your tailnet."
        case .linux: "Run the headless Broker on your private Linux server."
        }
    }
    var symbol: String {
        switch self {
        case .thisMac: "macmini"
        case .anotherMac: "desktopcomputer"
        case .linux: "server.rack"
        }
    }
}
