import XCTest
import SwiftUI
@testable import Pharos

final class ShellLayoutGeometryTests: XCTestCase {

    // MARK: - 1. Minimum Window Clamping Tests (512 x 520 DIP)

    func testMinimumWindowClamping() {
        let tinySize = CGSize(width: 320, height: 400)
        let clamped = ShellLayoutState.clampWindowSize(tinySize)
        XCTAssertEqual(clamped.width, 512)
        XCTAssertEqual(clamped.height, 520)

        let largeSize = CGSize(width: 1440, height: 900)
        let largeClamped = ShellLayoutState.clampWindowSize(largeSize)
        XCTAssertEqual(largeClamped.width, 1440)
        XCTAssertEqual(largeClamped.height, 900)

        let state = ShellLayoutState(windowWidth: 400, windowHeight: 300)
        XCTAssertEqual(state.windowWidth, 512)
        XCTAssertEqual(state.windowHeight, 520)
    }

    // MARK: - 2. Sidebar Boundaries & Clamping (240 - 400px, default 280px)

    func testSidebarWidthBoundaries() {
        let state = ShellLayoutState(windowWidth: 1200)
        XCTAssertEqual(state.requestedSidebarWidth, 280)

        state.requestedSidebarWidth = 200 // below min 240
        XCTAssertEqual(state.requestedSidebarWidth, 240)

        state.requestedSidebarWidth = 500 // above max 400
        XCTAssertEqual(state.requestedSidebarWidth, 400)

        state.requestedSidebarWidth = 320 // valid in-between
        XCTAssertEqual(state.requestedSidebarWidth, 320)
    }

    // MARK: - 3. Sidebar Drag Hysteresis (collapse < 210, expand >= 220)

    func testSidebarDragHysteresis() {
        let state = ShellLayoutState(windowWidth: 1200, sidebarWidth: 280)
        XCTAssertFalse(state.isSidebarCompact)

        // Drag down to 215: within dead-zone, remains expanded at 240 min clamp
        state.updateSidebarDrag(width: 215)
        XCTAssertFalse(state.isSidebarCompact)

        // Drag down below 210: collapses to compact mode
        state.updateSidebarDrag(width: 205)
        XCTAssertTrue(state.isSidebarCompact)
        XCTAssertEqual(state.effectiveSidebarWidth, 88)

        // While compact, dragging to 215 should NOT expand (needs >= 220)
        state.updateSidebarDrag(width: 215)
        XCTAssertTrue(state.isSidebarCompact)
        XCTAssertEqual(state.effectiveSidebarWidth, 88)

        // Dragging to 225 expands back to normal
        state.updateSidebarDrag(width: 260)
        XCTAssertFalse(state.isSidebarCompact)
        XCTAssertEqual(state.effectiveSidebarWidth, 260)
    }

    // MARK: - 4. Auto-Compact Breakpoint (expandedWidth + 424px)

    func testAutoCompactBreakpointCalculation() {
        let state = ShellLayoutState(windowWidth: 1000, sidebarWidth: 280)
        // With default 280px sidebar, breakpoint = 280 + 424 = 704px
        XCTAssertEqual(state.compactBreakpoint, 704)
        XCTAssertFalse(state.isSidebarCompact)
        XCTAssertEqual(state.effectiveSidebarWidth, 280)

        // Window resized to 705px: still expanded
        state.windowWidth = 705
        XCTAssertFalse(state.isSidebarCompact)
        XCTAssertEqual(state.effectiveSidebarWidth, 280)

        // Window resized to 703px: falls below 704, snaps to 88px icon rail
        state.windowWidth = 703
        XCTAssertTrue(state.isSidebarCompact)
        XCTAssertEqual(state.effectiveSidebarWidth, 88)

        // If user changed sidebar to 320px: breakpoint = 320 + 424 = 744px
        state.requestedSidebarWidth = 320
        XCTAssertEqual(state.compactBreakpoint, 744)

        state.windowWidth = 750
        XCTAssertFalse(state.isSidebarCompact)
        XCTAssertEqual(state.effectiveSidebarWidth, 320)

        state.windowWidth = 740
        XCTAssertTrue(state.isSidebarCompact)
        XCTAssertEqual(state.effectiveSidebarWidth, 88)
    }

    // MARK: - 5. Details Pane Docking vs Overlay Breakpoint

    func testDetailsDockVsOverlayBreakpoints() {
        let state = ShellLayoutState(windowWidth: 1040, sidebarWidth: 280, isDetailsVisible: true)
        // Expanded sidebar (280px) -> dock threshold = 280 + 424 + 280 = 984px
        XCTAssertEqual(state.detailsDockBreakpoint, 984)
        XCTAssertTrue(state.isDetailsDocked)
        XCTAssertFalse(state.isDetailsOverlay)
        XCTAssertEqual(state.effectiveDetailsWidth, 320)

        // Window at 984px: exactly at dock threshold
        state.windowWidth = 984
        XCTAssertTrue(state.isDetailsDocked)
        XCTAssertFalse(state.isDetailsOverlay)

        // Window at 800px: cannot dock (800 < 984), converts to overlay drawer
        state.windowWidth = 800
        XCTAssertFalse(state.isDetailsDocked)
        XCTAssertTrue(state.isDetailsOverlay)

        // If sidebar is compact (88px) -> dock threshold = 88 + 424 + 280 = 792px
        state.isManuallyCompact = true
        XCTAssertEqual(state.detailsDockBreakpoint, 792)
        // Now at 800px with compact sidebar, it CAN dock! (800 >= 792)
        XCTAssertTrue(state.isDetailsDocked)
        XCTAssertFalse(state.isDetailsOverlay)

        // Window at 700px with compact sidebar: 700 < 792 -> overlay
        state.windowWidth = 700
        XCTAssertFalse(state.isDetailsDocked)
        XCTAssertTrue(state.isDetailsOverlay)
    }

    // MARK: - 6. Canvas Width Guarantees

    func testCanvasWidthCalculation() {
        let state = ShellLayoutState(windowWidth: 1200, sidebarWidth: 280, isDetailsVisible: true)
        // Docked: 1200 - 280 - 320 = 600px
        XCTAssertEqual(state.effectiveCanvasWidth, 600)

        // Close details: 1200 - 280 = 920px
        state.isDetailsVisible = false
        XCTAssertEqual(state.effectiveCanvasWidth, 920)

        // Small window 512px: compact sidebar 88px, details overlay (not docked)
        state.windowWidth = 512
        state.isDetailsVisible = true
        // Canvas width = 512 - 88 = 424px (preserved minimum chat width)
        XCTAssertEqual(state.effectiveCanvasWidth, 424)
    }
}
