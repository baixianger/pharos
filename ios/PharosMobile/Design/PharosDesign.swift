import SwiftUI

/// Shared visual language for Pharos Mobile. The system stays deliberately
/// quiet: hierarchy comes from type, spacing and semantic status glyphs rather
/// than stacked cards or decorative gradients.
enum PharosDesign {
    static let pageInset: CGFloat = 20
    static let rowVerticalPadding: CGFloat = 11
    static let compactSpacing: CGFloat = 6

    static let pageBackground = Color(uiColor: .systemBackground)
    static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
    static let separator = Color.primary.opacity(0.08)
    static let muted = Color.secondary.opacity(0.72)
}

/// Deterministic launch routing used by simulator visual QA. These arguments
/// are inert in normal launches and avoid production-only mock data.
enum PharosLaunchOptions {
    private static let arguments = ProcessInfo.processInfo.arguments

    static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

struct PharosSectionTitle: View {
    let title: String
    var count: Int?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let count {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let action {
                Button("Add", systemImage: "plus", action: action)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }
}

struct PharosFilterStrip<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.0) { option, label in
                    Button(label) { selection = option }
                        .font(.subheadline.weight(selection == option ? .semibold : .regular))
                        .foregroundStyle(selection == option ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(selection == option ? PharosDesign.secondaryBackground : .clear,
                                    in: Capsule())
                        .contentShape(.capsule)
                        .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, PharosDesign.pageInset)
        }
    }
}

struct PharosStatusGlyph: View {
    enum Kind {
        case active, idle, warning, blocked, done, offline

        var color: Color {
            switch self {
            case .active: .green
            case .idle: .blue
            case .warning: .orange
            case .blocked: .red
            case .done: .mint
            case .offline: .secondary
            }
        }

        var symbol: String {
            switch self {
            case .active: "waveform.path.ecg"
            case .idle: "circle.lefthalf.filled"
            case .warning: "exclamationmark"
            case .blocked: "xmark"
            case .done: "checkmark"
            case .offline: "circle.dotted"
            }
        }
    }

    let kind: Kind
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.48, weight: .bold))
            .foregroundStyle(kind.color)
            .frame(width: size, height: size)
            .background(kind.color.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}

struct PharosSkeletonRows: View {
    var count = 5

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.secondary.opacity(0.13))
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(.secondary.opacity(0.16))
                            .frame(width: index.isMultiple(of: 2) ? 180 : 225, height: 13)
                        Capsule().fill(.secondary.opacity(0.1))
                            .frame(width: index.isMultiple(of: 2) ? 110 : 145, height: 9)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
                if index < count - 1 { Divider().opacity(0.45) }
            }
        }
        .padding(.horizontal, PharosDesign.pageInset)
        .accessibilityLabel("Loading")
    }
}

extension View {
    func pharosPlainList() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(PharosDesign.pageBackground)
            .environment(\.defaultMinListRowHeight, 1)
    }
}
