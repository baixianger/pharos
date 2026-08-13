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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowPulse = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.005, green: 0.035, blue: 0.025),
                    Color(red: 0.008, green: 0.09, blue: 0.045),
                    Color(red: 0.005, green: 0.025, blue: 0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GeometryReader { proxy in
                let shortSide = min(proxy.size.width, proxy.size.height)
                let blockWidth = min(proxy.size.width * 0.72, shortSide * 0.74)
                let blockHeight = max(42, shortSide * 0.13)

                ZStack {
                    // Surrounding field: the launch composition needs a full
                    // gradient atmosphere, not only a floating center bar.
                    RadialGradient(
                        colors: [
                            Color(red: 0.14, green: 0.72, blue: 0.18).opacity(0.42),
                            Color(red: 0.03, green: 0.18, blue: 0.09).opacity(0.16),
                            .clear
                        ],
                        center: .center,
                        startRadius: shortSide * 0.04,
                        endRadius: shortSide * 0.62
                    )
                    .frame(width: proxy.size.width * 1.45, height: proxy.size.height * 0.92)
                    .blur(radius: shortSide * 0.10)

                    EllipticalGradient(
                        colors: [
                            Color(red: 0.02, green: 0.66, blue: 0.48).opacity(0.28),
                            .clear
                        ],
                        center: .trailing,
                        startRadiusFraction: 0.05,
                        endRadiusFraction: 0.72
                    )
                    .frame(width: proxy.size.width * 0.76, height: proxy.size.height * 0.68)
                    .offset(x: proxy.size.width * 0.34, y: proxy.size.height * 0.02)
                    .blur(radius: shortSide * 0.08)

                    EllipticalGradient(
                        colors: [
                            Color(red: 0.08, green: 0.62, blue: 0.16).opacity(0.24),
                            .clear
                        ],
                        center: .leading,
                        startRadiusFraction: 0.04,
                        endRadiusFraction: 0.70
                    )
                    .frame(width: proxy.size.width * 0.72, height: proxy.size.height * 0.70)
                    .offset(x: -proxy.size.width * 0.34, y: -proxy.size.height * 0.04)
                    .blur(radius: shortSide * 0.09)

                    // A broad, screen-adaptive bloom gives the launch scene
                    // the Modular Gradient feel without reproducing the App
                    // Icon's rounded-square silhouette.
                    RoundedRectangle(cornerRadius: blockHeight * 0.48)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.05, green: 0.58, blue: 0.22).opacity(0.42),
                                    Color(red: 0.62, green: 1.0, blue: 0.08).opacity(0.86),
                                    Color(red: 0.08, green: 0.78, blue: 0.48).opacity(0.56)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: blockWidth, height: blockHeight)
                        .blur(radius: blockHeight * 0.72)
                        .opacity(glowPulse ? 0.95 : 0.72)

                    RoundedRectangle(cornerRadius: blockHeight * 0.42)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.08, green: 0.68, blue: 0.22),
                                    Color(red: 0.72, green: 1.0, blue: 0.18),
                                    Color(red: 0.12, green: 0.82, blue: 0.62)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: blockWidth * 0.80, height: blockHeight * 0.46)
                        .blur(radius: blockHeight * 0.20)
                        .opacity(0.94)

                    RoundedRectangle(cornerRadius: blockHeight * 0.30)
                        .fill(.white.opacity(0.18))
                        .frame(width: blockWidth * 0.58, height: blockHeight * 0.12)
                        .blur(radius: blockHeight * 0.08)
                        .opacity(glowPulse ? 0.95 : 0.72)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pharos loading")
    }
}
