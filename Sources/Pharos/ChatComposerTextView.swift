import SwiftUI
import AppKit

/// The keys the chat composer cares about, normalized off AppKit selectors so
/// the decision logic can be unit-tested without a live text view.
enum ChatComposerKey: Equatable {
    case newline   // Return / Enter / line-break
    case up
    case down
    case tab
    case escape
    case other
}

/// What the composer should do for a given key. Kept a pure value so the
/// Enter/Shift+Enter/IME/mention matrix is testable in isolation.
enum ChatComposerAction: Equatable {
    case send            // plain Enter with no active mention → send the message
    case insertNewline   // Shift+Enter → let the text view insert a real newline
    case acceptMention   // Enter/Tab while the @-mention popup is up → complete it
    case moveMention(Int)// ↑/↓ while the popup is up → move the selection
    case dismissMention  // Esc while the popup is up → hide it
    case passThrough     // not ours — let the field editor handle it
}

enum ChatComposer {
    /// The heart of the IME-safe composer. `hasMarkedText` is true while an
    /// input method is mid-composition (e.g. picking a Chinese candidate); in
    /// that state Enter must fall through so the IME confirms the candidate and
    /// never triggers a send/newline — the exact safety SwiftUI's onKeyPress
    /// can't provide.
    static func action(for key: ChatComposerKey,
                       shiftHeld: Bool,
                       hasMarkedText: Bool,
                       mentionActive: Bool) -> ChatComposerAction {
        switch key {
        case .newline:
            if hasMarkedText { return .passThrough }   // IME confirming a candidate
            if mentionActive { return .acceptMention }
            if shiftHeld { return .insertNewline }
            return .send
        case .up:
            return mentionActive ? .moveMention(-1) : .passThrough
        case .down:
            return mentionActive ? .moveMention(1) : .passThrough
        case .tab:
            return mentionActive ? .acceptMention : .passThrough
        case .escape:
            return mentionActive ? .dismissMention : .passThrough
        case .other:
            return .passThrough
        }
    }

    /// Whether the field editor's `doCommandBy` should report the command as
    /// handled (consumed). `insertNewline`/`passThrough` return false so the
    /// text view performs its own default (insert a newline / normal handling).
    static func consumes(_ action: ChatComposerAction) -> Bool {
        switch action {
        case .send, .acceptMention, .moveMention, .dismissMention: return true
        case .insertNewline, .passThrough: return false
        }
    }
}

/// A multi-line, IME-safe chat input backed by `NSTextView`. Enter sends,
/// Shift+Enter inserts a newline, and the field editor confirms IME composition
/// natively before any command reaches us. Grows with its content up to
/// `maxHeight`, then scrolls.
struct ChatComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    /// Edge-triggered focus request: set true to steal first-responder; the
    /// view resets it to false once focused.
    @Binding var requestFocus: Bool
    var isEnabled: Bool = true
    var minHeight: CGFloat = 24
    var maxHeight: CGFloat = 140

    var onSend: () -> Void
    var mentionActive: () -> Bool
    var onMentionMove: (Int) -> Void
    var onMentionAccept: () -> Void
    var onMentionDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 4, height: 5)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        // Never overwrite text the user is actively composing (marked text) —
        // that would break IME. Programmatic changes (send-clear, mention
        // complete, draft restore) land here when not composing.
        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
            context.coordinator.recalcHeight()
        }
        if requestFocus {
            DispatchQueue.main.async {
                if textView.window?.firstResponder !== textView {
                    textView.window?.makeFirstResponder(textView)
                }
                if requestFocus { requestFocus = false }
            }
        }
        context.coordinator.recalcHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerTextView
        weak var textView: NSTextView?

        init(_ parent: ChatComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Don't publish mid-composition marked text as the committed draft.
            if textView.hasMarkedText() { return }
            if parent.text != textView.string { parent.text = textView.string }
            recalcHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let key = Self.key(for: selector)
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            let action = ChatComposer.action(for: key,
                                             shiftHeld: shift,
                                             hasMarkedText: textView.hasMarkedText(),
                                             mentionActive: parent.mentionActive())
            switch action {
            case .send:          parent.onSend()
            case .acceptMention: parent.onMentionAccept()
            case .moveMention(let d): parent.onMentionMove(d)
            case .dismissMention: parent.onMentionDismiss()
            case .insertNewline, .passThrough: break
            }
            return ChatComposer.consumes(action)
        }

        func recalcHeight() {
            guard let textView, let lm = textView.layoutManager, let tc = textView.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
            let target = min(max(used + textView.textContainerInset.height * 2, parent.minHeight), parent.maxHeight)
            if abs(target - parent.height) > 0.5 {
                DispatchQueue.main.async { [weak self] in self?.parent.height = target }
            }
        }

        private static func key(for selector: Selector) -> ChatComposerKey {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                return .newline
            case #selector(NSResponder.moveUp(_:)):    return .up
            case #selector(NSResponder.moveDown(_:)):  return .down
            case #selector(NSResponder.insertTab(_:)): return .tab
            case #selector(NSResponder.cancelOperation(_:)): return .escape
            default: return .other
            }
        }
    }
}
