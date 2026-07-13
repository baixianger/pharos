import AppKit
import SwiftUI

/// One source of truth for native window/tab labels. SwiftUI's
/// `navigationTitle` and AppKit's `NSWindow.title` can both write the title, so
/// every room surface must use the exact same value.
enum PharosWindowTitle {
    static func room(_ room: String) -> String {
        room.isEmpty ? "Chat Rooms" : "💬 \(room)"
    }
}

/// Pins the native macOS window tab bar visible (even at a single tab) and
/// mirrors `title` onto the window, so each open Pharos window is a native tab
/// labeled with its project — the "one project per tab" model.
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
    var title: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(title: title, from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(title: title, from: nsView)
    }

    @MainActor
    final class Coordinator {
        private weak var bound: NSWindow?
        private var observation: NSKeyValueObservation?
        /// Read when deferred window adoption runs. A newly created native tab
        /// can receive several SwiftUI updates before `view.window` exists; an
        /// older captured value must never win later.
        private var desiredTitle = "Pharos"

        func update(title: String, from view: NSView) {
            desiredTitle = title
            if let window = view.window {
                attach(to: window)
                apply(title: desiredTitle, to: window)
                return
            }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let window = view?.window else { return }
                self.attach(to: window)
                self.apply(title: self.desiredTitle, to: window)
            }
        }

        func apply(title: String, to window: NSWindow) {
            window.titleVisibility = .hidden
            if window.title != title { window.title = title }
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
