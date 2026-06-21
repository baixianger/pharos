import SwiftUI

/// Lightweight, dependency-free SwiftUI markdown renderer for issue bodies and
/// project-log notes. Adapted from Wick's `WickMarkdown` (Pharos shares Wick's
/// design language and its no-extra-deps stance — the full swift-markdown-ui
/// package would pull a remote dependency Pharos doesn't otherwise carry).
///
/// Apple's `AttributedString(markdown:)` handles inline marks (`**bold**`,
/// `*italic*`, `` `code` ``, links); this view owns only the block layout that
/// Apple's built-in parser stops at:
///   - `#`/`##`/`###` headings
///   - `- ` / `* ` bullet lists
///   - `1.` / `1)` numbered lists
///   - ``` fenced code blocks
///   - blank-line-separated paragraphs
struct MarkdownText: View {
    let text: String
    var accent: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: Block model

    private enum Block {
        case heading(level: Int, text: String)
        case bullets([String])
        case ordered([String])
        case code(String)
        case paragraph(String)
    }

    /// Line-based block parser (line-oriented so fenced code blocks — which may
    /// contain blank lines — are grouped correctly).
    private var blocks: [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [Block] = []
        var i = 0

        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        func isBullet(_ s: String) -> Bool { trimmed(s).hasPrefix("- ") || trimmed(s).hasPrefix("* ") }
        func isOrdered(_ s: String) -> Bool {
            trimmed(s).range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil
        }

        while i < lines.count {
            let line = lines[i]
            let t = trimmed(line)

            if t.isEmpty { i += 1; continue }

            // Fenced code block.
            if t.hasPrefix("```") {
                var body: [String] = []
                i += 1
                while i < lines.count, !trimmed(lines[i]).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }   // closing fence
                result.append(.code(body.joined(separator: "\n")))
                continue
            }
            // Heading.
            if let r = t.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let level = t.distance(from: t.startIndex, to: t.firstIndex(of: " ") ?? t.startIndex)
                result.append(.heading(level: min(level, 3), text: String(t[r.upperBound...])))
                i += 1
                continue
            }
            // Bullet list.
            if isBullet(line) {
                var items: [String] = []
                while i < lines.count, isBullet(lines[i]) {
                    items.append(String(trimmed(lines[i]).dropFirst(2))); i += 1
                }
                result.append(.bullets(items))
                continue
            }
            // Numbered list.
            if isOrdered(line) {
                var items: [String] = []
                while i < lines.count, isOrdered(lines[i]) {
                    let lt = trimmed(lines[i])
                    if let r = lt.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                        items.append(String(lt[r.upperBound...]))
                    }
                    i += 1
                }
                result.append(.ordered(items))
                continue
            }
            // Paragraph — gather consecutive plain lines.
            var para: [String] = []
            while i < lines.count {
                let lt = trimmed(lines[i])
                if lt.isEmpty || lt.hasPrefix("```") || isBullet(lines[i]) || isOrdered(lines[i])
                    || lt.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil { break }
                para.append(lines[i]); i += 1
            }
            result.append(.paragraph(para.joined(separator: "\n")))
        }
        return result
    }

    // MARK: Block rendering

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let s):
            Text(attributed(s))
                .font(.system(size: [0: 20, 1: 20, 2: 17, 3: 15][level] ?? 15,
                              weight: level <= 1 ? .bold : .semibold))
                .padding(.top, 2)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(accent).frame(width: 5, height: 5).padding(.top, 6)
                        Text(attributed(item)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).").font(.body.monospacedDigit()).foregroundStyle(accent)
                        Text(attributed(item)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }

        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

        case .paragraph(let s):
            Text(attributed(s))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Inline-mark parse via Apple's markdown attributer; soft line breaks within
    /// a paragraph are preserved so multi-line prose doesn't collapse.
    private func attributed(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}
