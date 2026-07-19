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

        /// A fresh native tab can receive several SwiftUI updates before
        /// `view.window` exists. Retry on the runloop until it does (bounded)
        /// instead of giving up after a single deferred tick — otherwise the
        /// title only lands on the next unrelated state change (e.g. the mesh
        /// load seconds later).
        private func applyWhenReady(from view: NSView, attempt: Int) {
            if let window = view.window {
                attach(to: window)
                apply(title: desiredTitle, windowTitle: desiredWindowTitle, to: window)
                return
            }
            guard attempt < 30 else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.applyWhenReady(from: view, attempt: attempt + 1)
            }
        }

        func apply(title: String, windowTitle: String, to window: NSWindow) {
            // Set the window title eagerly (used by the tab when no tab title is
            // set, plus Mission Control / the Window menu) so it's never empty.
            if window.title != windowTitle { window.title = windowTitle }
            window.titleVisibility = .hidden
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
