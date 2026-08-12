# iOS Chat UX Requirements

These are the four confirmed requirements for the mobile chat room.

1. Tapping a message dismisses the keyboard. Message actions such as reply,
   attachment buttons, copy, and context menus must remain usable.
2. Opening or switching to a room starts at the newest loaded message. This
   must also work when the history response arrives after the first layout pass.
3. The transcript follows the newest message while the user is at the tail.
   A deliberate upward scroll pauses follow mode; returning to the tail resumes
   it. Loading older history must not snap the reader back down.
4. Keyboard transitions and composer accessories must preserve the visible
   transcript. The bottom obstruction is the complete occupied area: keyboard,
   composer, @mention strip, reply preview, pending attachment strip, and
   attachment tray. The newest message must not be covered or overlap these
   surfaces.

## Implementation guidance

- Keep the composer in the outer container's bottom safe-area layout rather than
  placing it inside the message list.
- Measure dynamic composer content with `GeometryReader`/a preference key.
- Use keyboard frame notifications only for the portion not already represented
  by the window safe area. Keyboard frames are reported in screen coordinates;
  convert them before comparing with a view's geometry in split-view layouts.
- Use `ScrollGeometry` to derive distance from the tail. Follow new messages
  only while that distance is near zero, and use `ScrollViewReader` to re-anchor
  after message, keyboard, or composer-height changes.
- Schedule the re-anchor after the layout/keyboard transaction, not only when
  the room view first appears.

Community implementations converge on the same split: keep the input bar
outside the transcript, reserve bottom space for the complete input/keyboard
obstruction, and re-anchor only when the user is already at the tail. They also
warn that an unconditional `scrollTo` during keyboard animation fights the
user's scroll position. These are useful secondary references, not API
contracts:

- Swift Forums, natural TextField keyboard avoidance in a ScrollView:
  https://forums.swift.org/t/swiftui-how-to-implement-natural-textfields-keyboard-avoidance-in-scrollview/67616
- Stack Overflow, chat-like scrolling and keyboard behavior:
  https://stackoverflow.com/questions/78193636/swiftui-chat-like-scrolling-and-keyboard-behaviour
- Stack Overflow, `ScrollView` behavior in ChatGPT-like UI:
  https://stackoverflow.com/questions/79782461/swiftui-scrollview-behavior-in-chatgpt-like-ui

## References checked

- Apple, `safeAreaInset` and `safeAreaPadding`:
  https://developer.apple.com/documentation/swiftui/view/safeareainset(edge:alignment:spacing:content:)
- Apple, `ScrollGeometry` and `onScrollGeometryChange`:
  https://developer.apple.com/documentation/swiftui/scrollgeometry
- Apple, `ScrollViewReader`:
  https://developer.apple.com/documentation/swiftui/scrollviewreader
- Apple, `keyboardWillChangeFrameNotification`:
  https://developer.apple.com/documentation/uikit/uiresponder/keyboardwillchangeframenotification
