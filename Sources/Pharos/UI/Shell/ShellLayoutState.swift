import SwiftUI

/// Layout model managing responsive 3-pane geometry, breakpoint transitions,
/// and hysteresis thresholds according to Grok Bot desktop rules.
@Observable
public final class ShellLayoutState {

    // MARK: - Properties

    public var windowWidth: CGFloat = 1180
    public var windowHeight: CGFloat = 760

    /// Expanded width requested for the left sidebar (clamped between 240 and 400).
    public var requestedSidebarWidth: CGFloat = PharosDesignTokens.Layout.sidebarDefaultWidth {
        didSet {
            let clamped = min(
                max(requestedSidebarWidth, PharosDesignTokens.Layout.sidebarMinWidth),
                PharosDesignTokens.Layout.sidebarMaxWidth
            )
            if requestedSidebarWidth != clamped {
                requestedSidebarWidth = clamped
            }
        }
    }

    /// User explicitly toggled the sidebar into compact mode.
    public var isManuallyCompact: Bool = false

    /// Inspector / details pane visibility.
    public var isDetailsVisible: Bool = false

    /// Requested width for the details pane (min 280, default 320).
    public var requestedDetailsWidth: CGFloat = PharosDesignTokens.Layout.detailsDefaultWidth {
        didSet {
            let clamped = max(requestedDetailsWidth, PharosDesignTokens.Layout.detailsMinWidth)
            if requestedDetailsWidth != clamped {
                requestedDetailsWidth = clamped
            }
        }
    }

    // MARK: - Initializer

    public init(
        windowWidth: CGFloat = 1180,
        windowHeight: CGFloat = 760,
        sidebarWidth: CGFloat = PharosDesignTokens.Layout.sidebarDefaultWidth,
        isDetailsVisible: Bool = false
    ) {
        self.windowWidth = max(windowWidth, PharosDesignTokens.Layout.minWindowWidth)
        self.windowHeight = max(windowHeight, PharosDesignTokens.Layout.minWindowHeight)
        self.requestedSidebarWidth = min(
            max(sidebarWidth, PharosDesignTokens.Layout.sidebarMinWidth),
            PharosDesignTokens.Layout.sidebarMaxWidth
        )
        self.isDetailsVisible = isDetailsVisible
    }

    // MARK: - Breakpoints & Computed Layout

    /// Breakpoint under which the sidebar automatically collapses to 88px compact rail.
    /// Formula: `expandedWidth + 424`.
    public var compactBreakpoint: CGFloat {
        return requestedSidebarWidth + PharosDesignTokens.Layout.canvasMinChatWidth
    }

    /// True if sidebar is currently in compact 88px icon rail mode (either auto or manual).
    public var isSidebarCompact: Bool {
        if isManuallyCompact { return true }
        return windowWidth < compactBreakpoint
    }

    /// The actual rendered pixel width of the sidebar.
    public var effectiveSidebarWidth: CGFloat {
        if isSidebarCompact {
            return PharosDesignTokens.Layout.sidebarCompactWidth
        }
        return requestedSidebarWidth
    }

    /// Breakpoint above which the details pane can permanently dock alongside chat.
    /// Formula: `effectiveSidebarWidth + 424 + 280`.
    public var detailsDockBreakpoint: CGFloat {
        return effectiveSidebarWidth + PharosDesignTokens.Layout.canvasMinChatWidth + PharosDesignTokens.Layout.detailsMinWidth
    }

    /// Details pane is docked when visible and the window can accommodate all 3 panes simultaneously.
    public var isDetailsDocked: Bool {
        guard isDetailsVisible else { return false }
        return windowWidth >= detailsDockBreakpoint
    }

    /// Details pane is rendered as an overlay drawer when visible but window is constrained.
    public var isDetailsOverlay: Bool {
        guard isDetailsVisible else { return false }
        return !isDetailsDocked
    }

    /// Rendered width of the details pane.
    public var effectiveDetailsWidth: CGFloat {
        guard isDetailsVisible else { return 0 }
        if isDetailsDocked {
            let maxDocked = max(0, windowWidth - effectiveSidebarWidth - PharosDesignTokens.Layout.canvasMinChatWidth)
            return min(requestedDetailsWidth, maxDocked)
        } else {
            let maxOverlay = max(0, windowWidth - effectiveSidebarWidth)
            return min(requestedDetailsWidth, maxOverlay)
        }
    }

    /// Width of the conversation canvas.
    public var effectiveCanvasWidth: CGFloat {
        if isDetailsDocked {
            return max(PharosDesignTokens.Layout.canvasMinChatWidth, windowWidth - effectiveSidebarWidth - effectiveDetailsWidth)
        } else {
            return max(PharosDesignTokens.Layout.canvasMinChatWidth, windowWidth - effectiveSidebarWidth)
        }
    }

    // MARK: - Interactive Actions

    /// Handles drag resizing with hysteresis on the sidebar separator.
    public func updateSidebarDrag(width: CGFloat) {
        if isSidebarCompact {
            // Expand when dragged past 220px
            if width >= PharosDesignTokens.Layout.sidebarDragExpandThreshold {
                isManuallyCompact = false
                requestedSidebarWidth = width
            }
        } else {
            // Collapse when dragged below 210px
            if width <= PharosDesignTokens.Layout.sidebarDragCollapseThreshold {
                isManuallyCompact = true
            } else {
                requestedSidebarWidth = width
            }
        }
    }

    /// Toggles sidebar compact / expanded state.
    public func toggleSidebarCompact() {
        isManuallyCompact.toggle()
    }

    /// Toggles details inspector visibility.
    public func toggleDetails() {
        isDetailsVisible.toggle()
    }

    // MARK: - Static Clamping Helper

    public static func clampWindowSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(size.width, PharosDesignTokens.Layout.minWindowWidth),
            height: max(size.height, PharosDesignTokens.Layout.minWindowHeight)
        )
    }
}
