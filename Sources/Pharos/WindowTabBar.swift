import AppKit
import SwiftUI

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
        let t = title
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window)
            context.coordinator.apply(title: t, to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let t = title
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            context.coordinator.attach(to: window)
            context.coordinator.apply(title: t, to: window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var bound: NSWindow?
        private var observation: NSKeyValueObservation?

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

        private func installObserver(on window: NSWindow) {
            guard let group = window.tabGroup else {
                // The group forms slightly later; retry on the next runloop.
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window, self.bound === window else { return }
                    self.installObserver(on: window)
                }
                return
            }
            observation = group.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
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
