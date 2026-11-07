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
                .fill(PharosDesignTokens.Colors.elevated)
                .overlay(
                    RoundedRectangle(
                        cornerRadius: isExpanded
                            ? PharosDesignTokens.Layout.composerExpandedRadius
                            : PharosDesignTokens.Layout.composerCompactRadius
                    )
                    .stroke(
                        isFocused ? PharosDesignTokens.Colors.accent.opacity(0.6) : PharosDesignTokens.Colors.borderTranslucent,
                        lineWidth: PharosDesignTokens.Layout.composerBorderWidth
                    )
                )
                .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)

                // Input & Controls
                VStack(alignment: .leading, spacing: 0) {
                    if isExpanded {
                        TextEditor(text: $text)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .focused($isFocused)
                            .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)
                            .frame(minHeight: 40, maxHeight: PharosDesignTokens.Layout.composerContentMaxHeight)
                            .scrollContentBackground(.hidden)
                            .padding(.top, 10)
                            .padding(.horizontal, 14)
                    } else {
                        HStack(spacing: 8) {
                            // Left Action / Mode Indicator Pill
                            Button(action: onToggleSteering) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(isSteeringMode ? PharosDesignTokens.Colors.statusAttention : PharosDesignTokens.Colors.statusWorking)
                                        .frame(width: 6, height: 6)

                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 11))
                                        .foregroundStyle(PharosDesignTokens.Colors.inkSecondary)
                                }
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(PharosDesignTokens.Colors.hoverNeutral))
                            }
                            .buttonStyle(.plain)
                            .help(isSteeringMode ? "Steering Mode Active" : "Prompt Queue Mode")
                            .padding(.leading, 6)

                            TextField(placeholder, text: $text)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14))
                                .focused($isFocused)
                                .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)
                                .frame(height: PharosDesignTokens.Layout.composerCompactHeight)
                                .onSubmit {
                                    submitMessage()
                                }

                            sendButton
                                .padding(.trailing, 6)
                        }
                    }

                    // Bottom controls bar (visible when expanded)
                    if isExpanded {
                        HStack(spacing: 8) {
                            // Prompt Mode Toggle
                            Button(action: onToggleSteering) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(isSteeringMode ? PharosDesignTokens.Colors.statusAttention : PharosDesignTokens.Colors.statusWorking)
                                        .frame(width: 6, height: 6)
                                    Text(isSteeringMode ? "STEER" : "QUEUE")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(PharosDesignTokens.Colors.inkPrimary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(PharosDesignTokens.Colors.hoverNeutral)
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
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .animation(PharosDesignTokens.Springs.composerResize, value: isExpanded)
    }

    private var sendButton: some View {
        Button(action: submitMessage) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? PharosDesignTokens.Colors.inkTertiary : Color.white)
                .frame(width: 30, height: 30)
                .background(
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? PharosDesignTokens.Colors.hoverNeutral
                    : PharosDesignTokens.Colors.accent
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
