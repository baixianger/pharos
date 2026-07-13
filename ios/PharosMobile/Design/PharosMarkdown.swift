import MarkdownUI
import SwiftUI
import UIKit

extension Theme {
    @MainActor static var pharosWaterfall: Theme {
        Theme()
            .text { FontSize(16); ForegroundColor(.primary) }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(14)
                BackgroundColor(Color.secondary.opacity(0.12))
            }
            .codeBlock { configuration in PharosCodeBlock(configuration: configuration) }
            .heading1 { configuration in
                configuration.label.markdownTextStyle { FontWeight(.bold); FontSize(23) }
                    .padding(.bottom, 2)
            }
            .heading2 { configuration in
                configuration.label.markdownTextStyle { FontWeight(.semibold); FontSize(20) }
            }
            .heading3 { configuration in
                configuration.label.markdownTextStyle { FontWeight(.semibold); FontSize(18) }
            }
            .strong { FontWeight(.semibold) }
            .link { ForegroundColor(.accentColor) }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.45)).frame(width: 3)
                    configuration.label
                        .markdownTextStyle { ForegroundColor(.secondary) }
                        .padding(.leading, 10)
                }
            }
            .table { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .markdownTableBorderStyle(.init(color: .secondary.opacity(0.3), width: 1))
                        .markdownTableBackgroundStyle(.alternatingRows(.clear, .secondary.opacity(0.06)))
                }
            }
    }
}

private struct PharosCodeBlock: View {
    let configuration: CodeBlockConfiguration
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(configuration.language ?? "code").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = configuration.content
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.secondary.opacity(0.1))
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle { FontFamilyVariant(.monospaced); FontSize(13) }
                    .padding(12)
            }
        }
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.2)) }
    }
}

struct StableMarkdownView: View, Equatable {
    let content: String
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.content == rhs.content }

    var body: some View {
        Markdown(content)
            .markdownTheme(.pharosWaterfall)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

