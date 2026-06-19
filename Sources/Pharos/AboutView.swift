import SwiftUI
import AppKit

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build  = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            // App icon (the real app icon, rendered crisp)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 92, height: 92)
                .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
                .padding(.top, 28)

            Text("Pharos")
                .font(.system(size: 22, weight: .bold))
                .padding(.top, 14)

            Text("Your vibe coding project manager")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 5)

            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 7)

            // Primary action — encourage a star.
            Button {
                Links.open(Links.repo)
            } label: {
                Label("Star on GitHub", systemImage: "star.fill")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(.horizontal, 46)
            .padding(.top, 24)

            // Secondary links.
            HStack(spacing: 26) {
                AboutLink(label: "Source", systemImage: "chevron.left.forwardslash.chevron.right") {
                    Links.open(Links.repo)
                }
                AboutLink(label: "Issues", systemImage: "exclamationmark.bubble") {
                    Links.open(Links.issues)
                }
            }
            .padding(.top, 15)

            Text("© 2026 Pai · MIT License")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 20)
                .padding(.bottom, 24)
        }
        .frame(width: 340)
        .fixedSize()
        .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct AboutLink: View {
    let label: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
