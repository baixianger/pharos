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
    static let dashboard = "Pharos"
    static func room(_ room: String) -> String {
        room.isEmpty ? "Chat Rooms" : room
    }
    static func project(_ name: String) -> String { name }
}

/// Pins the native macOS window tab bar visible (even at a single tab) and sets
/// the window title. The window title (e.g. "Pharos" on the dashboard) is shown
/// in the title bar and is set directly via AppKit the instant the window
/// exists — so a fresh tab shows "Pharos" immediately instead of waiting for
/// SwiftUI's `navigationTitle` to propagate (which lagged behind the first mesh
/// load by several seconds). The native tab label carries the concrete screen
/// name via `NSWindow.tab.title`.
///
/// AppKit auto-hides the tab bar when a window group drops to one tab, and there
/// is no public "always show" flag — only `toggleTabBar(_:)`. So we show it on
/// window adoption and re-show it via KVO on `isTabBarVisible` whenever the OS
/// flips it back off. `ensureVisible` is idempotent so we never hide an
/// already-visible bar. Drop it as a zero-size `.background(...)` on the window
/// root; it reaches the hosting `NSWindow` through the view hierarchy.
struct WindowTabBar: NSViewRepresentable {
    /// The native tab label (identifies the concrete thing open in the tab).
    var title: String
    /// The window title shown in the title bar (e.g. "Pharos" on the dashboard).
    var windowTitle: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(title: title, windowTitle: windowTitle, from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(title: title, windowTitle: windowTitle, from: nsView)
    }

    @MainActor
    final class Coordinator {
        private weak var bound: NSWindow?
        private var observation: NSKeyValueObservation?
        /// Read when deferred window adoption runs. A newly created native tab
        /// can receive several SwiftUI updates before `view.window` exists; an
        /// older captured value must never win later.
        private var desiredTitle = PharosTabTitle.dashboard
        private var desiredWindowTitle = PharosViewTitle.dashboard

        func update(title: String, windowTitle: String, from view: NSView) {
            desiredTitle = title
            desiredWindowTitle = windowTitle
            applyWhenReady(from: view, attempt: 0)
        }

        /// A fresh native tab can take a few dozen milliseconds to gain its
        /// window. Poll with a short delay until it does (bounded) so the title
        /// lands promptly — a single deferred tick can fire before the window
        /// exists and then never retry, leaving the title unset until the next
        /// unrelated state change (the mesh load, seconds later).
        private func applyWhenReady(from view: NSView, attempt: Int) {
            if let window = view.window {
                attach(to: window)
                apply(title: desiredTitle, windowTitle: desiredWindowTitle, to: window)
                return
            }
            guard attempt < 300 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak view] in
                guard let self, let view else { return }
                self.applyWhenReady(from: view, attempt: attempt + 1)
            }
        }

        func apply(title: String, windowTitle: String, to window: NSWindow) {
            // Keep the title bar hidden so the sidebar stays full-height under
            // the traffic lights (a visible title strip pushes it down). The
            // screen name lives in the native tab label instead; window.title
            // still carries it for Mission Control / the Window menu.
            window.titleVisibility = .hidden
            if window.title != windowTitle { window.title = windowTitle }
            if window.tab.title != title { window.tab.title = title }
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
