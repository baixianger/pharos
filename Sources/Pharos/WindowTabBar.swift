import AppKit
import SwiftUI

/// Content titles describe the kind of screen. Native tab labels identify the
/// concrete thing open in that tab. They are deliberately different channels.
enum PharosViewTitle {
    static let dashboard = "Pharos"
    static let rooms = "Chat Rooms"
    static let project = "Project"
}

enum PharosTabTitle {
    static let dashboard = "Dashboard"
    static func room(_ room: String) -> String {
        room.isEmpty ? "Chat Rooms" : room
    }
    static func project(_ name: String) -> String { name }
}

/// Pins the native macOS window tab bar visible (even at a single tab) and
/// writes `title` to `NSWindow.tab.title`, so SwiftUI remains free to manage the
/// visible content title through `navigationTitle` without competing for the
/// native tab label.
///
/// AppKit auto-hides the tab bar when a window group drops to one tab, and there
/// is no public "always show" flag — only `toggleTabBar(_:)`. So we show it on
/// window adoption and re-show it via KVO on `isTabBarVisible` whenever the OS
/// flips it back off. `ensureVisible` is idempotent so we never hide an
/// already-visible bar. Drop it as a zero-size `.background(...)` on the window
/// root; it reaches the hosting `NSWindow` through the view hierarchy.
///
/// New windows (the tab bar's "+", or ⌘N if unbound) join the same group as
/// tabs. The title-bar text stays hidden, so this doesn't reintroduce a title
/// strip — the tab reads `window.title` regardless of title-bar visibility.
struct WindowTabBar: NSViewRepresentable {
    /// The native tab label (identifies the concrete thing open in the tab).
    var title: String
    /// The window title, set directly via AppKit so it lands the instant the
    /// window exists — instead of waiting for SwiftUI's `navigationTitle` to
    /// propagate, which on a fresh tab can lag behind the first mesh load.
    var windowTitle: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowBridgeView {
        NSLog("PHAROS-TITLE makeNSView windowTitle=%@ tab=%@", windowTitle, title)
        let view = WindowBridgeView()
        view.coordinator = context.coordinator
        context.coordinator.set(title: title, windowTitle: windowTitle)
        context.coordinator.applyIfPossible(from: view)
        return view
    }

    func updateNSView(_ nsView: WindowBridgeView, context: Context) {
        nsView.coordinator = context.coordinator
        context.coordinator.set(title: title, windowTitle: windowTitle)
        context.coordinator.applyIfPossible(from: nsView)
    }

    /// A zero-size NSView that reports the exact moment SwiftUI attaches it to a
    /// window (`viewDidMoveToWindow`), so the coordinator titles the window then
    /// — event-driven, not polling. Runloop-async retries all fire within a
    /// fraction of a second, so they can't span a window that materializes
    /// several seconds later; this can.
    final class WindowBridgeView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NSLog("PHAROS-TITLE viewDidMoveToWindow hasWindow=%@", window == nil ? "no" : "yes")
            if let window { coordinator?.apply(to: window) }
        }
    }

    @MainActor
    final class Coordinator {
        private weak var bound: NSWindow?
        private var observation: NSKeyValueObservation?
        private var desiredTitle = PharosTabTitle.dashboard
        private var desiredWindowTitle = PharosViewTitle.dashboard

        func set(title: String, windowTitle: String) {
            desiredTitle = title
            desiredWindowTitle = windowTitle
        }

        func applyIfPossible(from view: NSView) {
            if let window = view.window { apply(to: window) }
        }

        func apply(to window: NSWindow) {
            attach(to: window)
            // Set the window title eagerly (used by the tab when no tab title is
            // set, plus Mission Control / the Window menu) so it's never empty.
            if window.title != desiredWindowTitle { window.title = desiredWindowTitle }
            window.titleVisibility = .hidden
            if window.tab.title != desiredTitle { window.tab.title = desiredTitle }
            NSLog("PHAROS-TITLE apply window.title=%@ tab.title=%@", desiredWindowTitle, desiredTitle)
        }

        func attach(to window: NSWindow) {
            guard bound !== window else { return }
            bound = window
            window.tabbingMode = .preferred   // sibling windows open AS tabs here
            ensureVisible(window)
            installObserver(on: window)
        }

        /// Cap on how many times `installObserver` re-schedules itself waiting
        /// for the window's tab group to form. Bounded so a window that never
        /// joins a group can't spin on the main queue forever.
        private static let maxInstallRetries = 20

        private func installObserver(on window: NSWindow, attempt: Int = 0) {
            guard let group = window.tabGroup else {
                // The group forms slightly later; retry on the next runloop,
                // but give up after a bounded number of attempts.
                guard attempt < Self.maxInstallRetries else { return }
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window, self.bound === window else { return }
                    self.installObserver(on: window, attempt: attempt + 1)
                }
                return
            }
            observation = group.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, _ in
                // KVO may be delivered on a non-main thread; hop to main rather
                // than asserting isolation (which would trap off-main).
                DispatchQueue.main.async {
                    guard let self, let window = self.bound else { return }
                    self.ensureVisible(window)
                }
            }
        }

        private func ensureVisible(_ window: NSWindow) {
            if let group = window.tabGroup {
                if !group.isTabBarVisible { window.toggleTabBar(nil) }
            } else {
                window.toggleTabBar(nil)   // forms a group with the bar shown
            }
        }
    }
}
