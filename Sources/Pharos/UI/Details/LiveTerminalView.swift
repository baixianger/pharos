import SwiftUI
import AppKit

/// Observable view-model managing terminal lines, ANSI parsing, and live streaming controls.
@Observable
@MainActor
public final class LiveTerminalViewModel {
    public var lines: [AnsiTerminalLine] = []
    public var rawOutputBuffer: String = ""
    public var isStreaming: Bool = true
    public var autoScroll: Bool = true
    public var tmuxSession: String
    public var terminalDimensions: String = "80x24"

    private let parser = AnsiTerminalParser.shared
    private var maxLines: Int = 1000

    public init(
        tmuxSession: String = "pharos:agent-session",
        initialText: String? = nil
    ) {
        self.tmuxSession = tmuxSession
        if let initialText = initialText {
            appendOutput(initialText)
        } else {
            // Seed with realistic tmux pane header
            appendOutput("\u{001B}[1;36m[tmux]\u{001B}[0m attached to session \u{001B}[1;32m\(tmuxSession)\u{001B}[0m (window 0, pane 0)\n")
            appendOutput("\u{001B}[2m$ pharos agent peek --follow --uds ~/.codex/app-server-control/app-server-control.sock\u{001B}[0m\n")
            appendOutput("\u{001B}[32m✔ UDS connection established\u{001B}[0m • streaming live ANSI buffer...\n")
        }
    }

    /// Appends output chunks and updates parsed lines.
    public func appendOutput(_ chunk: String) {
        rawOutputBuffer += chunk
        let parsed = parser.parse(text: chunk)

        if lines.isEmpty {
            lines = parsed
        } else {
            // Merge last line if chunk didn't start with newline
            var updated = lines
            if let firstNew = parsed.first, !chunk.hasPrefix("\n") && !chunk.hasPrefix("\r\n") {
                let lastIndex = updated.count - 1
                let combinedRaw = updated[lastIndex].rawText + firstNew.rawText
                let combinedSegments = updated[lastIndex].segments + firstNew.segments
                updated[lastIndex] = AnsiTerminalLine(
                    lineNumber: updated[lastIndex].lineNumber,
                    segments: combinedSegments,
                    rawText: combinedRaw
                )
                if parsed.count > 1 {
                    var nextLineNum = updated[lastIndex].lineNumber + 1
                    for line in parsed.dropFirst() {
                        updated.append(AnsiTerminalLine(
                            lineNumber: nextLineNum,
                            segments: line.segments,
                            rawText: line.rawText
                        ))
                        nextLineNum += 1
                    }
                }
            } else {
                var nextLineNum = (updated.last?.lineNumber ?? 0) + 1
                for line in parsed {
                    updated.append(AnsiTerminalLine(
                        lineNumber: nextLineNum,
                        segments: line.segments,
                        rawText: line.rawText
                    ))
                    nextLineNum += 1
                }
            }

            // Cap buffer
            if updated.count > maxLines {
                updated = Array(updated.suffix(maxLines))
            }
            lines = updated
        }
    }

    public func togglePause() {
        isStreaming.toggle()
    }

    public func clear() {
        lines.removeAll()
        rawOutputBuffer = ""
    }

    public func copyAll() {
        let plain = AnsiTerminalParser.stripAnsi(from: rawOutputBuffer)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plain, forType: .string)
    }
}

/// The Live Terminal streaming pane (Computer sub-tab).
public struct LiveTerminalView: View {
    @State public var viewModel: LiveTerminalViewModel
    @State private var copyFeedback: Bool = false

    public init(viewModel: LiveTerminalViewModel) {
        self._viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        VStack(spacing: 0) {
            terminalToolbar

            Divider()
                .overlay(Color.white.opacity(0.1))

            terminalCanvas
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Toolbar

    private var terminalToolbar: some View {
        HStack(spacing: 10) {
            // Live / Paused Status Indicator
            HStack(spacing: 5) {
                Circle()
                    .fill(viewModel.isStreaming ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(viewModel.isStreaming ? "LIVE" : "PAUSED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(viewModel.isStreaming ? Color.green : Color.orange)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())

            // Session & Dimension Info
            Text("\(viewModel.tmuxSession) • \(viewModel.terminalDimensions)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            // Pause / Resume Toggle
            Button(action: { viewModel.togglePause() }) {
                Image(systemName: viewModel.isStreaming ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(viewModel.isStreaming ? "Pause Stream" : "Resume Stream")

            // Copy All Button
            Button(action: {
                viewModel.copyAll()
                copyFeedback = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copyFeedback = false
                }
            }) {
                Image(systemName: copyFeedback ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(copyFeedback ? Color.green : Color.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Copy Terminal Text")

            // Clear Button
            Button(action: { viewModel.clear() }) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Clear Terminal")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
    }

    // MARK: - Canvas

    private var terminalCanvas: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.lines) { line in
                        terminalLineView(line)
                    }

                    // Bottom anchor for auto-scroll
                    Color.clear
                        .frame(height: 1)
                        .id("terminalBottom")
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.lines.count) { _, _ in
                if viewModel.autoScroll && viewModel.isStreaming {
                    proxy.scrollTo("terminalBottom", anchor: .bottom)
                }
            }
        }
        .frame(minHeight: 220, maxHeight: 380)
    }

    private func terminalLineView(_ line: AnsiTerminalLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if line.segments.isEmpty {
                Text(" ")
                    .font(.system(size: 11, design: .monospaced))
            } else {
                ForEach(line.segments) { segment in
                    Text(segment.text)
                        .font(.system(
                            size: 11,
                            weight: segment.isBold ? .bold : .regular,
                            design: .monospaced
                        ))
                        .foregroundStyle(segment.foreground ?? Color(white: 0.88))
                        .background(segment.background ?? Color.clear)
                        .italic(segment.isItalic)
                        .underline(segment.isUnderline)
                        .opacity(segment.isDim ? 0.6 : 1.0)
                }
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}
