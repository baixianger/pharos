# iOS 开发经验

本文件记录 Pharos iOS 客户端中已经核验、可以复用的实现经验。重点是聊天界面的键盘避让、消息滚动和动态输入区布局。

跨项目的通用版本维护在 [brainstorm/learning/iOS Development Experience](../../../brainstorm/learning/ios-development-experience/README.md)。本文件保留 Pharos 的具体实现背景和验证结果。

## 聊天界面的四条行为约定

聊天页应同时满足以下行为：

1. 点击消息后收起键盘，但不能破坏回复、复制、附件和上下文菜单操作。
2. 进入或切换聊天室后定位到最新消息，即使历史请求晚于第一次布局完成。
3. 用户仍在消息尾部时，新消息自动跟随；用户主动上滑后暂停跟随，回到底部后恢复。
4. 键盘和输入区附属内容共同参与底部布局：@ 提及栏、回复预览、待发送附件和附件操作面板都不能覆盖最新消息。

## 键盘避让：先使用 safe area，再补充差值

聊天页的推荐结构是：

```swift
ScrollViewReader { proxy in
    ScrollView {
        transcript
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
        composer
    }
}
```

输入区放在消息列表外层的 `safeAreaInset` 中。这样输入区本身和消息滚动区域会随系统 safe area 一起布局，避免把输入框直接塞进消息列表后产生重复滚动或遮挡。

如果嵌套在 `NavigationSplitView`、分屏或 Stage Manager 中时系统 safe area 没有正确传播，再监听 `UIResponder.keyboardWillChangeFrameNotification`，只添加系统没有提供的差值。不要直接把键盘高度再次完整加到 `safeAreaInset` 上，否则会重复计算。

键盘 frame 是屏幕坐标，不一定等于当前 view 或 window 坐标。iPad 分屏、Slide Over 和 Stage Manager 必须先转换坐标：

```swift
let frameInWindow = window.screen.coordinateSpace.convert(keyboardFrame, to: window)
let overlap = max(0, window.bounds.maxY - frameInWindow.minY)
let extra = max(0, overlap - window.safeAreaInsets.bottom)
```

键盘隐藏时要把额外差值清零。键盘通知发生在动画开始前，消息重新定位应在布局事务完成后再执行一个短暂的异步 re-anchor，否则 `scrollTo` 可能早于键盘最终高度，导致最新消息仍被覆盖。

## 输入区高度必须是整体高度

不能只测量 TextField 的高度。composer 的实际占用高度应包括：

- 基础输入框；
- 多行输入框增长后的高度；
- @ 提及成员横向栏；
- 回复中的消息预览；
- 待发送附件横向栏；
- 相机、照片、文件操作面板；
- composer 自身的上下 padding 和 safe-area。

实践中可以在 composer 外层用 `GeometryReader` 写入 `PreferenceKey`，监听整体高度变化。高度变化时，如果用户仍在消息尾部，重新滚动到最新消息；如果用户正在阅读历史，则只调整可视区域，不强行拉回底部。

## “跟随最新消息”必须区分用户意图

不要在每次消息刷新时无条件执行 `scrollTo(lastMessage)`。正确的状态模型是：

```text
用户在尾部       -> followTail = true
用户主动上滑     -> followTail = false
用户滚回尾部     -> followTail = true
新消息到达       -> 仅 followTail 为 true 时 scrollTo 最新消息
键盘/composer 变化 -> 仅 followTail 为 true 时重新定位
加载旧消息       -> 保持用户当前位置，不回到底部
```

iOS 26 可以用 `onScrollGeometryChange` 计算距离底部；通常保留一个小阈值，避免动画和浮点误差让状态在尾部附近反复切换：

```swift
.onScrollGeometryChange(for: CGFloat.self) { geometry in
    max(0, geometry.contentSize.height
        - geometry.containerSize.height
        - geometry.contentOffset.y)
} action: { _, distance in
    followTail = distance < 80
}
```

首次进入房间时需要两次机会定位：第一次在页面稳定后定位，第二次在最新历史数据真正进入视图后定位。否则网络响应晚到时，第一次 `scrollTo` 没有目标，页面会停在错误位置。

## 点击消息收键盘

消息行可以通过 `simultaneousGesture` 提供一个轻量 tap 回调，让父级把 `@FocusState` 设为 `false`：

```swift
.simultaneousGesture(
    TapGesture().onEnded { focused = false }
)
```

使用 simultaneous gesture 是为了不覆盖消息内部已有的 Button、附件点击、滑动回复和 context menu。不要把整个消息行改成一个外层 Button，否则容易改变附件和长按菜单的手势优先级。

## 常见错误

- 在键盘动画开始前立即 `scrollTo`，但没有等待最终布局；
- 同时依赖系统 keyboard safe area，又把完整键盘高度手动加一遍；
- 只计算 TextField 高度，忽略 @、引用和附件区域；
- 每次轮询消息都滚到底部，导致用户无法阅读历史；
- 用户上滑加载旧消息后仍触发“最新消息”定位；
- 用 `UIScreen.main.bounds` 直接计算键盘重叠，导致 iPad 分屏位置错误；
- 用旋转/翻转 ScrollView 模拟倒序聊天，导致 context menu、预览和坐标系出现异常。

## 参考资料

- [Apple: safeAreaInset](https://developer.apple.com/documentation/swiftui/view/safeareainset(edge:alignment:spacing:content:))
- [Apple: ScrollGeometry](https://developer.apple.com/documentation/swiftui/scrollgeometry)
- [Apple: ScrollViewReader](https://developer.apple.com/documentation/swiftui/scrollviewreader)
- [Apple: keyboardWillChangeFrameNotification](https://developer.apple.com/documentation/uikit/uiresponder/keyboardwillchangeframenotification)
- [Swift Forums: natural TextField keyboard avoidance](https://forums.swift.org/t/swiftui-how-to-implement-natural-textfields-keyboard-avoidance-in-scrollview/67616)
- [Stack Overflow: chat-like scrolling and keyboard behavior](https://stackoverflow.com/questions/78193636/swiftui-chat-like-scrolling-and-keyboard-behaviour)

需求清单见 [CHAT_UX_ISSUES.md](CHAT_UX_ISSUES.md)。
