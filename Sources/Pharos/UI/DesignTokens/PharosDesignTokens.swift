import SwiftUI

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

        /// Conversation Canvas (Middle Pane)
        public static let canvasMinChatWidth: CGFloat = 424
        public static let titlebarHeight: CGFloat = 44
        public static let macControlsInset: CGFloat = 72

        /// Details Inspector (Right Pane)
        public static let detailsDefaultWidth: CGFloat = 320
        public static let detailsMinWidth: CGFloat = 280
        public static let detailsDragCollapseThreshold: CGFloat = 244
        public static let detailsCloseLingerMs: Double = 300

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
        public static let bubblePaddingInline: CGFloat = 12
        public static let bubblePaddingBlock: CGFloat = 7
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

    // MARK: - Color Palette

    public enum Colors {
        // Base surfaces
        public static let paneLight = Color(red: 1.0, green: 1.0, blue: 1.0)
        public static let paneDark = Color(red: 22/255, green: 22/255, blue: 22/255) // #161616

        public static let chromeLight = Color(red: 252/255, green: 252/255, blue: 252/255) // #fcfcfc
        public static let chromeDark = Color(red: 18/255, green: 18/255, blue: 18/255) // #121212

        public static let sidebarLight = Color(red: 245/255, green: 245/255, blue: 245/255) // #f5f5f5
        public static let sidebarDark = Color(red: 14/255, green: 14/255, blue: 14/255) // #0e0e0e

        public static let elevatedLight = Color(red: 1.0, green: 1.0, blue: 1.0)
        public static let elevatedDark = Color(red: 31/255, green: 31/255, blue: 31/255) // #1f1f1f

        // Inks & Typography
        public static let inkPrimaryLight = Color(red: 28/255, green: 28/255, blue: 28/255) // #1c1c1c
        public static let inkPrimaryDark = Color(red: 245/255, green: 245/255, blue: 245/255) // #f5f5f5

        public static let inkSecondaryLight = Color(red: 28/255, green: 28/255, blue: 28/255).opacity(0.68)
        public static let inkSecondaryDark = Color(red: 245/255, green: 245/255, blue: 245/255).opacity(0.66)

        public static let inkTertiaryLight = Color(red: 28/255, green: 28/255, blue: 28/255).opacity(0.56)
        public static let inkTertiaryDark = Color(red: 245/255, green: 245/255, blue: 245/255).opacity(0.54)

        // Borders
        public static let borderTranslucentLight = Color(red: 28/255, green: 28/255, blue: 28/255).opacity(0.12)
        public static let borderTranslucentDark = Color(red: 245/255, green: 245/255, blue: 245/255).opacity(0.10)

        // Accents (Blue)
        public static let accentLight = Color(red: 22/255, green: 128/255, blue: 243/255) // #1680f3
        public static let accentDark = Color(red: 17/255, green: 109/255, blue: 210/255) // #116dd2

        public static let accentBrightLight = Color(red: 30/255, green: 134/255, blue: 252/255) // #1e86fc
        public static let accentBrightDark = Color(red: 24/255, green: 132/255, blue: 252/255) // #1884fc

        public static let accentForegroundLight = Color(red: 11/255, green: 109/255, blue: 211/255) // #0b6dd3
        public static let accentForegroundDark = Color(red: 77/255, green: 155/255, blue: 255/255) // #4d9bff

        // Semantic Status
        public static let statusWorking = Color(red: 16/255, green: 171/255, blue: 97/255) // #10ab61
        public static let statusAttention = Color(red: 218/255, green: 131/255, blue: 14/255) // #da830e
        public static let statusDanger = Color(red: 231/255, green: 46/255, blue: 59/255) // #e72e3b

        // Bubble Fills
        public static let agentBubbleLight = Color(red: 28/255, green: 28/255, blue: 28/255).opacity(0.06)
        public static let agentBubbleDark = Color(red: 245/255, green: 245/255, blue: 245/255).opacity(0.04)

        public static let userBubbleLight = Color(red: 28/255, green: 28/255, blue: 28/255)
        public static let userBubbleDark = Color(red: 245/255, green: 245/255, blue: 245/255).opacity(0.18)
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
