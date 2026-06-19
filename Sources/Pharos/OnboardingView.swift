import SwiftUI

struct OnboardingView: View {
    @Environment(ProjectStore.self) private var store
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            // App identity
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(.secondary)
                Text("Pharos")
                    .font(.largeTitle.bold())
                Text("Your vibe coding project manager")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // What it does
            VStack(alignment: .leading, spacing: 14) {
                bulletRow(symbol: "folder.badge.plus",
                          text: "Track local folders and GitHub repos in one place")
                bulletRow(symbol: "terminal",
                          text: "Launch Claude Code or Codex in one click, with tmux support")
                bulletRow(symbol: "waveform.path",
                          text: "See git status, commit activity, and running agents at a glance")
            }
            .padding(.horizontal, 8)

            // Actions
            VStack(spacing: 12) {
                Button {
                    store.requestAdd()
                    onDismiss()
                } label: {
                    Label("Add Local Folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Button {
                    store.requestImport()
                    onDismiss()
                } label: {
                    Label("Import from GitHub", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)

                Button("Skip for now") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .font(.callout)
                .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(width: 420)
    }

    private func bulletRow(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }
}
