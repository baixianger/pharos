import SwiftUI
import AppKit

/// Canonical design tokens for Pharos desktop client.
/// Adapted faithfully from Grok Bot design tokens (2026-11-05_design-tokens.json).
/// See THIRD_PARTY_NOTICES.md for attributions.
public enum PharosDesignTokens {

    // MARK: - Layout Constants

    public enum Layout {
        /// Absolute minimum window dimensions for the desktop app.
        public static let minWindowWidth: CGFloat = 512
        public static let minWindowHeight: CGFloat = 520

        /// Navigation Sidebar (Left Pane)
        public static let sidebarDefaultWidth: CGFloat = 280
        public static let sidebarMinWidth: CGFloat = 240
        public static let sidebarMaxWidth: CGFloat = 400
        public static let sidebarCompactWidth: CGFloat = 88
        public static let sidebarDragCollapseThreshold: CGFloat = 210
        public static let sidebarDragExpandThreshold: CGFloat = 220
        public static let sidebarRowHeight: CGFloat = 54
        public static let sidebarAvatarSize: CGFloat = 36
        public static let mainBotAvatarSize: CGFloat = 60

        /// Conversation Canvas (Middle Pane)
        public static let canvasMinChatWidth: CGFloat = 424
        public static let titlebarHeight: CGFloat = 44
        public static let macControlsInset: CGFloat = 72

        /// Details Inspector (Right Pane)
        public static let detailsDefaultWidth: CGFloat = 320
        public static let detailsMinWidth: CGFloat = 280
        public static let detailsDragCollapseThreshold: CGFloat = 244
        public static let detailsCloseLingerMs: Double = 300
        public static let detailsAvatarSize: CGFloat = 64

        /// Composer
        public static let composerCompactHeight: CGFloat = 44
        public static let composerCompactRadius: CGFloat = 22
        public static let composerExpandedRadius: CGFloat = 18
        public static let composerBorderWidth: CGFloat = 0.5
        public static let composerContentMinHeight: CGFloat = 20
        public static let composerContentMaxHeight: CGFloat = 120

        /// Chat Bubbles
        public static let bubbleMaxStandardWidth: CGFloat = 560
        public static let bubbleRadius: CGFloat = 18
        public static let bubbleCornerJoinedRadius: CGFloat = 6
        public static let bubblePaddingInline: CGFloat = 14
        public static let bubblePaddingBlock: CGFloat = 8
        public static let bubbleLineHeight: CGFloat = 22
        public static let bubbleOneLineHeight: CGFloat = 36
    }

    // MARK: - Radii & Hairlines

    public enum Radii {
        public static let xs: CGFloat = 2
        public static let sm: CGFloat = 4
        public static let base: CGFloat = 8
        public static let lg: CGFloat = 10
        public static let xl: CGFloat = 14
        public static let xl2: CGFloat = 16
        public static let xl3: CGFloat = 18
        public static let card: CGFloat = 24
        public static let pill: CGFloat = 9999
        public static let hairline: CGFloat = 0.5
    }

    // MARK: - Dynamic Color Helpers

    private static func dynamicColor(
        light: (r: Double, g: Double, b: Double, a: Double),
        dark: (r: Double, g: Double, b: Double, a: Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            if match == .darkAqua {
                return NSColor(
                    calibratedRed: dark.r / 255.0,
                    green: dark.g / 255.0,
                    blue: dark.b / 255.0,
                    alpha: dark.a
                )
            } else {
                return NSColor(
                    calibratedRed: light.r / 255.0,
                    green: light.g / 255.0,
                    blue: light.b / 255.0,
                    alpha: light.a
                )
            }
        }))
    }

    // MARK: - Color Palette

    public enum Colors {
        // Base surfaces
        public static let pane = PharosDesignTokens.dynamicColor(
            light: (255, 255, 255, 1.0),
            dark: (22, 22, 22, 1.0)
        )

        public static let chrome = PharosDesignTokens.dynamicColor(
            light: (252, 252, 252, 1.0),
            dark: (18, 18, 18, 1.0)
        )

        public static let sidebar = PharosDesignTokens.dynamicColor(
            light: (245, 245, 245, 1.0),
            dark: (14, 14, 14, 1.0)
        )

        public static let elevated = PharosDesignTokens.dynamicColor(
            light: (255, 255, 255, 1.0),
            dark: (31, 31, 31, 1.0)
        )

        // Inks & Typography
        public static let inkPrimary = PharosDesignTokens.dynamicColor(
            light: (28, 28, 28, 1.0),
            dark: (245, 245, 245, 1.0)
        )

        public static let inkSecondary = PharosDesignTokens.dynamicColor(
            light: (28, 28, 28, 0.68),
            dark: (245, 245, 245, 0.66)
        )

        public static let inkTertiary = PharosDesignTokens.dynamicColor(
            light: (28, 28, 28, 0.56),
            dark: (245, 245, 245, 0.54)
        )

        // Borders & Overlays
        public static let borderTranslucent = PharosDesignTokens.dynamicColor(
            light: (28, 28, 28, 0.12),
            dark: (245, 245, 245, 0.10)
        )

        public static let hoverNeutral = PharosDesignTokens.dynamicColor(
            light: (28, 28, 28, 0.06),
            dark: (245, 245, 245, 0.08)
        )

        public static let selectedNeutral = PharosDesignTokens.dynamicColor(
            light: (28, 28, 28, 0.09),
            dark: (245, 245, 245, 0.14)
        )

        // Bubble Fills
        public static let bubbleAgent = PharosDesignTokens.dynamicColor(
            light: (28, 28, 28, 0.06),
            dark: (245, 245, 245, 0.04)
        )

        public static let bubbleUser = PharosDesignTokens.dynamicColor(
            light: (22, 128, 243, 1.0), // #1680f3 Grok Bot accent
            dark: (17, 109, 210, 1.0)
        )

        // Accents
        public static let accent = PharosDesignTokens.dynamicColor(
            light: (22, 128, 243, 1.0),
            dark: (17, 109, 210, 1.0)
        )

        public static let accentBright = PharosDesignTokens.dynamicColor(
            light: (30, 134, 252, 1.0),
            dark: (24, 132, 252, 1.0)
        )

        public static let accentMagenta = Color(red: 255/255, green: 94/255, blue: 177/255) // #ff5eb1

        // Semantic Status
        public static let statusWorking = Color(red: 16/255, green: 171/255, blue: 97/255) // #10ab61
        public static let statusAttention = Color(red: 218/255, green: 131/255, blue: 14/255) // #da830e
        public static let statusDanger = Color(red: 231/255, green: 46/255, blue: 59/255) // #e72e3b
    }

    // MARK: - Fluid Spring Animations

    public enum Springs {
        /// 200ms cubic-bezier(.22,1,.36,1) smooth panel expand
        public static let panelExpand = Animation.spring(response: 0.28, dampingFraction: 0.88)
        /// 300ms cubic-bezier(.2,0,0,1) details panel drawer
        public static let detailsDrawer = Animation.spring(response: 0.32, dampingFraction: 0.92)
        /// 150ms gentle hover
        public static let hover = Animation.easeInOut(duration: 0.15)
        /// Variable-height composer resize
        public static let composerResize = Animation.spring(response: 0.30, dampingFraction: 0.85)
    }
}

// MARK: - View Modifiers & Styles

public struct GbCardModifier: ViewModifier {
    public var radius: CGFloat = PharosDesignTokens.Radii.xl
    public var elevated: Bool = true

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(elevated ? PharosDesignTokens.Colors.elevated : PharosDesignTokens.Colors.pane)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(PharosDesignTokens.Colors.borderTranslucent, lineWidth: PharosDesignTokens.Radii.hairline)
            )
            .shadow(
                color: Color.black.opacity(elevated ? 0.04 : 0.0),
                radius: 6,
                x: 0,
                y: 2
            )
    }
}

public struct GbHairlineBorderModifier: ViewModifier {
    public var radius: CGFloat = PharosDesignTokens.Radii.xl

    public func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(PharosDesignTokens.Colors.borderTranslucent, lineWidth: PharosDesignTokens.Radii.hairline)
            )
    }
}

public extension View {
    func gbCard(radius: CGFloat = PharosDesignTokens.Radii.xl, elevated: Bool = true) -> some View {
        modifier(GbCardModifier(radius: radius, elevated: elevated))
    }

    func gbHairline(radius: CGFloat = PharosDesignTokens.Radii.xl) -> some View {
        modifier(GbHairlineBorderModifier(radius: radius))
    }
}

/// Exact Grok Bot .gb-toggle switch style (32x20 capsule, 16px white knob with shadow)
public struct GbToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    configuration.isOn.toggle()
                }
            } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(configuration.isOn ? PharosDesignTokens.Colors.accent : PharosDesignTokens.Colors.hoverNeutral)
                        .frame(width: 32, height: 20)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .padding(2)
                        .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }
}
