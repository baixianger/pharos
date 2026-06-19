import SwiftUI

/// The number of app launches before the star-prompt banner is shown.
let starPromptLaunchThreshold = 5

/// A thin, dismissible banner that appears at the bottom of the main window
/// once (after `starPromptLaunchThreshold` launches) asking the user to star
/// the repo on GitHub. Either action (Star or Not now) sets `starPromptDone`
/// so the banner is permanently hidden.
struct StarPromptBanner: View {
    @AppStorage("pharos.starPromptDone")  private var done      = false
    @AppStorage("pharos.launchCount")     private var launches  = 0
    @Environment(ProjectStore.self)       private var store

    /// True when the banner should be visible.
    private var shouldShow: Bool {
        !done && launches >= starPromptLaunchThreshold && !store.projects.isEmpty
    }

    var body: some View {
        if shouldShow {
            BannerContent(done: $done)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct BannerContent: View {
    @Binding var done: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("Enjoying Pharos? A ⭐ on GitHub really helps.")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("★ Star") {
                Links.open(Links.repo)
                done = true
            }
            .buttonStyle(.glass)
            .font(.subheadline)

            Button {
                done = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Not now — don't show again")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }
}
