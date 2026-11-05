import SwiftUI
import PharosClientKit

/// Variable-height desktop chat composer modeled faithfully on Grok Bot geometry.
/// Dynamically expands from compact 44px pill to expanded rounded paper card.
public struct PharosComposerView: View {
    @Binding public var text: String
    public let placeholder: String
    public let isSteeringMode: Bool
    public let onToggleSteering: () -> Void
    public let onSend: (String) -> Void

    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        placeholder: String = "Type a prompt or message…",
        isSteeringMode: Bool = false,
        onToggleSteering: @escaping () -> Void = {},
        onSend: @escaping (String) -> Void
    ) {
        self._text = text
        self.placeholder = placeholder
        self.isSteeringMode = isSteeringMode
        self.onToggleSteering = onToggleSteering
        self.onSend = onSend
    }

    /// True if content has newlines or multiple lines
    private var isExpanded: Bool {
        text.contains("\n") || text.count > 60
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                // Card background with hairline border & specular shadow
                RoundedRectangle(
                    cornerRadius: isExpanded
                        ? PharosDesignTokens.Layout.composerExpandedRadius
                        : PharosDesignTokens.Layout.composerCompactRadius
                )
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(
                        cornerRadius: isExpanded
                            ? PharosDesignTokens.Layout.composerExpandedRadius
                            : PharosDesignTokens.Layout.composerCompactRadius
                    )
                    .stroke(
                        isFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12),
                        lineWidth: PharosDesignTokens.Layout.composerBorderWidth
                    )
                )
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)

                // Input & Controls
                VStack(alignment: .leading, spacing: 0) {
                    // Text Input field
                    if isExpanded {
                        TextEditor(text: $text)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .focused($isFocused)
                            .frame(minHeight: 40, maxHeight: PharosDesignTokens.Layout.composerContentMaxHeight)
                            .scrollContentBackground(.hidden)
                            .padding(.top, 10)
                            .padding(.horizontal, 14)
                    } else {
                        TextField(placeholder, text: $text)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .focused($isFocused)
                            .frame(height: PharosDesignTokens.Layout.composerCompactHeight)
                            .padding(.leading, PharosDesignTokens.Layout.composerCompactRadius)
                            .padding(.trailing, 80)
                            .onSubmit {
                                submitMessage()
                            }
                    }

                    // Bottom controls bar (visible when expanded)
                    if isExpanded {
                        HStack(spacing: 8) {
                            // Prompt Mode Toggle
                            Button(action: onToggleSteering) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(isSteeringMode ? PharosDesignTokens.Colors.statusAttention : Color.secondary)
                                        .frame(width: 6, height: 6)
                                    Text(isSteeringMode ? "STEER" : "QUEUE")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(isSteeringMode ? "Mid-turn steering injection" : "Queue turn prompt")

                            Spacer()

                            // Send Button
                            sendButton
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .padding(.top, 4)
                    }
                }

                // Inline send button (when compact)
                if !isExpanded {
                    sendButton
                        .padding(.trailing, 6)
                        .padding(.bottom, 5)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(PharosDesignTokens.Springs.composerResize, value: isExpanded)
    }

    private var sendButton: some View {
        Button(action: submitMessage) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.4) : Color.white)
                .frame(width: 32, height: 32)
                .background(
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.primary.opacity(0.08)
                        : Color.accentColor
                )
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .keyboardShortcut(.return, modifiers: [.command])
    }

    private func submitMessage() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
        text = ""
    }
}
