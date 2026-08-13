import SwiftUI

@main
struct PharosMobileApp: App {
    var body: some Scene {
        WindowGroup { AppContainer() }
    }
}

private struct AppContainer: View {
    @State private var settings: AppSettings
    @State private var identities: SSHIdentityStore
    @State private var rooms: RoomStore
    @State private var pairing = PairingCoordinator()
    @State private var showsLaunchGlow = true
    private let isDemo: Bool

    init() {
        let isDemo = PharosDemoMode.isEnabled
        self.isDemo = isDemo
        let settings = AppSettings(demo: isDemo)
        let identities = SSHIdentityStore()
        _settings = State(initialValue: settings)
        _identities = State(initialValue: identities)
        _rooms = State(initialValue: RoomStore(
            settings: settings,
            identities: identities,
            demoData: isDemo ? .store : nil
        ))
    }

    var body: some View {
        @Bindable var pairing = pairing
        // The main app is always the root; the setup wizard is a dismissible
        // cover (auto-shown until a Broker is configured, re-openable from
        // Settings) rather than an inescapable root screen.
        ZStack {
            MainTabView()
                .environment(settings)
                .environment(identities)
                .environment(rooms)
                .environment(pairing)
                .onOpenURL { pairing.receive($0) }
                .fullScreenCover(isPresented: $pairing.showsSetupGuide) {
                    BrokerSetupGuide()
                        .environment(settings)
                        .environment(identities)
                        .environment(rooms)
                        .environment(pairing)
                }
                .sheet(item: $pairing.pending) { invitation in
                    PairBrokerConfirmation(invitation: invitation)
                        .environment(settings)
                }
                .alert("Pairing link unavailable", isPresented: $pairing.showsError) {
                    Button("OK") {}
                } message: {
                    Text(pairing.errorMessage ?? "Use a new pairing code from Pharos on your desktop.")
                }
                .task {
                    if !isDemo, settings.mesh.host.isEmpty { pairing.showsSetupGuide = true }
                }
                .onChange(of: settings.mesh.host) { _, host in
                    if !host.isEmpty { pairing.showsSetupGuide = false }
                }

            if showsLaunchGlow {
                PharosLaunchGlow()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(1050))
            withAnimation(.easeOut(duration: 0.35)) { showsLaunchGlow = false }
        }
    }
}

private struct PharosLaunchGlow: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.13)
            GeometryReader { proxy in
                let size = max(proxy.size.width, proxy.size.height)
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.18)
                        .fill(.blue.opacity(0.34))
                        .frame(width: size * 0.82, height: size * 0.58)
                        .blur(radius: size * 0.13)
                        .offset(x: -size * 0.20, y: -size * 0.18)
                    RoundedRectangle(cornerRadius: size * 0.18)
                        .fill(.purple.opacity(0.28))
                        .frame(width: size * 0.72, height: size * 0.64)
                        .blur(radius: size * 0.12)
                        .offset(x: size * 0.24, y: -size * 0.20)
                    RoundedRectangle(cornerRadius: size * 0.18)
                        .fill(.orange.opacity(0.20))
                        .frame(width: size * 0.75, height: size * 0.52)
                        .blur(radius: size * 0.14)
                        .offset(x: size * 0.10, y: size * 0.34)
                    RoundedRectangle(cornerRadius: size * 0.20)
                        .fill(.cyan.opacity(0.12))
                        .frame(width: size * 0.58, height: size * 0.34)
                        .blur(radius: size * 0.10)
                        .offset(x: -size * 0.02, y: size * 0.04)
                    VStack(spacing: 10) {
                        Text("PHAROS")
                            .font(.system(size: min(38, proxy.size.width * 0.105), weight: .semibold, design: .rounded))
                            .tracking(7)
                            .foregroundStyle(.white)
                        Text("MESH ALL YOUR AGENTS")
                            .font(.system(size: min(12, proxy.size.width * 0.032), weight: .medium, design: .rounded))
                            .tracking(2.2)
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    .scaleEffect(pulse ? 1.025 : 0.985)
                    .opacity(pulse ? 1 : 0.86)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pharos. Mesh all your agents.")
    }
}
