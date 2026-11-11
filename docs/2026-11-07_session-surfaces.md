---
summary: Desktop services connect local sessions and remote Codex/DSH through SSH, Projects and Threads; provider HITL, Goal, Todo and remote Antigravity verification remain incomplete.
---

# Session 界面与 Agent 能力实测

各家详情及证据边界分别记录在 [Codex](2026-11-07_codex-session-validation.md)、[Antigravity](2026-11-07_antigravity-session-validation.md) 和 [DSH](2026-11-07_dsh-session-validation.md)。

## 工作队列

| 顺序 | 改进 | 状态 |
| --- | --- | --- |
| 1 | Grok Bot 外壳与 SVG 头像 | 复用 brainstorm mockup 的 HTML、CSS 和 SVG 动画，macOS 在同一 WKWebView 渲染。 |
| 2 | Session 中间的 DSH 幕布 | 已实现。依据本机 DSH 0.2.2-rc.1 的组件样式收紧阅读列、圆角和折叠行。工具输入输出合并，表格只用横分隔线，宽表在正文列内滚动。 |
| 3 | Thread 成员头像 | 已实现。桌面头像轻叠，超过五人显示四位加省略号，悬停和键盘聚焦触发依次展开。窄屏和原生 iOS 使用群头像，超过四人显示三位加省略号。直连 Session 仍显示单头像。 |
| 4 | 保留右栏，补 Session 档案 | 已实现。Details 跟随选中会话显示 Agent、主机、会话 ID、状态、工作区和已有配置。Library 显示对话文件，Computer 保留终端输出和按主机绑定的 VNC 预留区。 |
| 5 | DSH 式输入区 | 已实现界面和规范化事件。HITL、Goal、Todo 位于现有输入框上方，有数据才显示。问答支持选项、自填和密码式输入。Provider 对接与验收见下一步。 |
| 6 | 三家 Agent 能力调查 | 完成首轮本机探针与协议对照，详见下文。 |
| 7 | 真实桌面 Session 数据链 | 进行中。本机三家列表、历史与发送已有生产服务；Codex 和 Antigravity 的隔离会话完成真实回复，mac-air DSH 已完成真实回复和桌面交互，本机 DSH 隔离 Host 的模型曾报错。事件、远程及桌面 UI 的完整验收仍未完成。 |
| 8 | 丰富右栏与全局任务列表 | 待完成。先接有来源的用量与文件，再加主机级日程和各家专有详情。VNC 预留位尚无图像或输入通路。 |

## 2026-11-07 服务接入与验收进度

桌面生产服务已连接现有项目存储、Mesh Thread 与本机三家 Session。Thread 使用真实 Broker 或分布式 Mesh，历史轮询刷新；Project 使用本地项目注册表。Session 列表经 Codex daemon 和两家 ACP 查询，Antigravity 通过 ACP 重放历史及发送，DSH 通过本机 loopback Host 的分页 journal、WebSocket 和 prompt API 连接。Goal/Todo 的历史快照和实时事件已接入输入区；数据未提供时不会伪造。

| 验证对象 | 已有证据 | 未完成或不可用 |
| --- | --- | --- |
| Codex | 生产服务真实会话查询与发送通过；自有回合的结构化问答完成回写、关闭通知与回合继续，旁观连接隔离经 fixture 验证。持久测试 Session Goal 设置、读取、完成与清除通过，服务可读取快照并防止旧快照覆盖新事件。 | 其他客户端发起的回合不会抢答；真实桌面点击、命令/文件审批、问答取消、Todo/Plan、并发抢答与重连待验证。 |
| Antigravity | 实际 ACP 列表读取到会话；隔离会话跨进程 `session/load` 重放用户及回复消息，生产服务继续发送并收到真实完成事件。真实桌面权限拒绝和精确匹配安全命令的单次允许已回写，允许后的工具输出及助手回复已确认；模拟 ACP 测试覆盖 Plan 和请求 ID 碰撞。 | 拒绝后正文未观察到；真实 Goal/Todo 和远程认证仍未验证，未暴露字段不能假定存在。 |
| DSH | mac-air 真实测试回合调用 `create_goal`、`todo_write` 和 `ask_user_question`，服务收到事件并提交选项，回合生成指定回复且完成；journal 可恢复 Goal 和两条 Todo。真实桌面 WebKit 问答及权限拒绝、单次允许均已验证。隔离本机 Host 的模型仍以 error 结束。 | Goal 的清除、真实网络断线重连未验收；真实 Goal 自动后续回合的完整运行、断线与并发仍待验收。 |
| Thread / Project | 隔离 Broker 核对 room、成员、历史和投递；真实 Codex 已接收并完成定向消息；Project 按 UUID 和主机 checkout 关联真实本地及 mac-air Session。 | DSH 的真实桌面消息往返、分布式 Mesh 和物理鼠标操作待验收；DSH 已通过隔离真实 Host、Runtime 和 Broker 的本机往返；Codex 和明确绑定的本机 Antigravity Thread 回复及从远程 Project 打开 Codex Session 已通过程序驱动桌面验证。 |
| 远程主机 | mac-air 的 Codex 经 SSH 读到 7 个会话及其中 12 个回合，临时只读回合收发通过；DSH 0.2.1 经 ACP 列出 155 个会话，桌面服务读到其中 3 个回合。 | mac-air DSH 发送、结构化问答及权限拒绝和单次允许已通过真实桌面 WebKit；mac-pro Antigravity 1.5.2 清单请求返回认证错误；远程 Codex 审批和真实网络恢复待验收。 |

验证应逐家覆盖真实请求、UI 操作、后端确认、同一会话继续运行、刷新与重连；协议 fixture 不等于代理端到端通过。另有待修问题：DSH 会话事件流断开后的补齐与重订阅，发送期间传输错误后的 UI 状态，及历史载入与新事件并发时的合并。全量测试曾在 `CodexDaemonClientTests` 附近长时间无进展而中止，不能视为通过；需定位后重跑。桌面截图和头像录屏对照也尚未完成。

## 远程 Codex 会话接入

桌面读取用户配置的 SSH 主机，跳过本机；对远程现有 Codex daemon 建立专用 Unix socket 隧道，复用 Session 列表、历史、发送及事件服务。每台主机的 Session ID 带独立前缀，防止与本机或其他主机冲突。隧道本地 socket 位于权限为 0700 的临时目录，服务关闭时清理。未启动远端程序或修改远端部署。

2026-11-07 在 mac-air 验证：桌面服务发现远程会话并读取 12 回合历史；独立的临时、只读 Codex 会话通过同一 SSH 传输发送提示并收到匹配的回复及完成事件。实际桌面 WebKit 渲染、断线重连、并发主机和共享 daemon 的审批所有权尚未验收。远程 Antigravity 尚未接入；当前远程发现只覆盖 `hosts.json` 配置的 SSH 主机，不代表整个 Mesh 节点覆盖。

## 远程 DSH 与 Antigravity 补充验证

mac-air 的 DSH 0.2.1-rc.2 需要通过 SSH 环境补齐 Homebrew PATH。真实 ACP 列出 155 个会话。该版本的历史分页要求从 follow 快照取得 `throughSeq`，而且同一个 peer 的逻辑流需要复用一条 WebSocket；生产传输已按此方式连接远程 Host。桌面服务实际发现远程 DSH，读取了一个包含 3 个回合的会话；交互流握手与历史读取同时完成。使用临时 loopback Host 和 SSH 转发，结束时检查了测试 Host 进程已退出。

远程 DSH 消息发送、回复、完成状态及结构化问答回写已在服务层实际验证；流式渲染、权限审批、Goal 清除、Host 启动失败、断线重连和并发访问还需覆盖。远程会话仅从用户配置的 SSH 主机发现。

mac-pro 的 Antigravity 1.5.2 接受 ACP 初始化并声明会话列表能力，但 `session/list` 返回 `-32000` 认证错误；检查的 CLI conversations 元数据目录没有会话数据库，故没有可接入并验证的真实远程会话。mac-air 未发现 Antigravity CLI。未调整远程认证，未把这些情况计为成功。Antigravity 事件的审批 ID 已包含 Session 标识，避免不同会话内相同 ACP 数字请求 ID 相互清除；远程 Antigravity 本身仍待接入。

## DSH 真实工作流复测

在 mac-air DSH 0.2.1 的新测试 Session 中，先经桌面同一服务发送无工具提示并收到预期回复。该版本 `turn/end.reason.kind` 的成功值为 `completed`、中断值为 `interrupted`；转换器此前将这两种状态误判为失败，现已修正并以 journal 回归测试覆盖。

随后提示代理在测试会话内设置 Goal 和 Todo、提出结构化问答。一次运行中服务观察到 Goal、Todo 和问题请求，按选项回写，journal 的同一回合记录 `create_goal`、`todo_write`、`ask_user_question` 和包含指定标记的最终回复，结束状态为 `completed`。重新连接 Host 重放 journal 可恢复 Goal 和两条 Todo。该回合之后的新回合由 DSH 的 `source=goal` 内部消息触发，并非用户消息重复发送；测试 Host 关闭时该后续回合被中断，完整运行仍待验收。另一次复测在超时时只确认 Goal/Todo 已持久化，问答和回合完成未确认。

上述验证通过服务事件和回写进行，尚未用桌面 WebKit 真实点击验证；未验证权限审批、多选/自填、并发、重连、清除以及本机 DSH 的认证。测试在远端真实 DSH 数据目录创建了多个带测试提示的 Session，保留供核对，没有删除用户数据。

Antigravity 在独立测试 Session 中再次尝试诱发真实权限请求，47 秒内仍未收到请求，测试为跳过而非通过。

## DSH 自动后续回合与状态

对已保留测试 Session 的 journal 逐条核对：用户只提交一次工作流提示，第二回合结束前 DSH 将一条 `source=goal` 的消息放入 inbox，第三回合消费它；第三回合因测试 Host 退出而中断。桌面服务此前只跟踪由 Pharos 发起的回合，现已接收其他来源的 `turn/start`、流式增量和 `turn/end`，并避免前一个回合迟到的完成事件清除正在运行的新回合。远程真实 Session 测试使用 Host 独立启动一个回合，观察到开始、文本增量和完成；这验证通用事件路径，尚未证明真实 Goal 自动后续回合完整跑完。

另一个 Goal 专项 Session 的模型在同一回合调用 `create_goal` 和 `update_goal`，journal 中 Goal 状态从 `active` 变为 `complete`，该回合完成；没有产生后续回合。最初测试错误地要求必须产生后续回合并在超时时丢失已观察状态，已修正测试逻辑，不将该超时视为服务失败。后续真实 Todo 专项测试依次观察到 `[in_progress, pending]`、`[completed, in_progress]` 和 `[completed, completed]`；journal 与新 Host 重连快照一致。再调用 `todo_write` 清空，服务事件、journal 和重新加载均为空。完整测试为 `DshSessionHistoryReaderTests.testRemoteTodoLifecycleWhenEnabled`，使用 mac-air 的真实模型与新测试 Session。

## DSH 交互流补充验证

检查本机 DSH 0.2.2-rc.1 安装包：权限和结构化问答经 Host 的 `$events` waterfall 分发，`$events/result` 以 clientId 和 eventId 关联；问答答案区分选项标签与自填内容。权限的已知结果为 `allowed-once`、`rejected` 等，当前不支持持久授权；未识别或非本桌面会话的请求交回 Host 继续分发。Host 取消事件或交互连接结束时撤回界面中的请求；同一 Session 的请求排队，切回会话时从服务读取当前请求。

本轮以真实隔离 DSH Host 验证交互 WebSocket 握手及历史、发送、回合结束；以可控交互流 fixture 验证桌面服务接收问答和权限请求、问答多选与自填格式、权限拒绝结果及待处理快照。两种测试都通过，但 fixture 并非真实模型请求。该 Host 在请求过期时也可能对结果 RPC 返回成功，因此 HTTP 成功只证明结果提交被接收，不能单独证明代理采纳；须进一步对照 journal 的 `approval/decided` 或问答后续消息及会话继续。

仍待：用实际模型触发两类请求并通过桌面输入完成闭环；覆盖其他客户端抢先回答、超时、多个并发请求及断线自动重订阅。此段记录的是当时的行为；后续交互流已补充空闲自动重连，具体验证范围见 DSH 分项文档。问答拒绝使用 waterfall `next`，不是对问题的特定拒绝答案。完整测试套件尚未重跑通过。

## 本机探针

2026-11-07 在独立临时会话中测试 Codex CLI 0.166.0、DSH 0.2.2-rc.1、Antigravity 1.5.1。Codex 使用独立 stdio App Server、只读沙箱与临时会话，DSH 使用独立目录和随机 loopback 端口，Antigravity 使用独立 ACP 进程。记录仅保留版本、事件名和字段形状。

| 后端 | 实际观察 | 接口或组件可见 | 仍待验收 |
| --- | --- | --- | --- |
| Codex | Plan 模式发出 `item/tool/requestUserInput`。两道题各有两个选项，`isOther: true`。收到 `thread/tokenUsage/updated`，含 `last`、`total`、`modelContextWindow`。 | 本机生成的 schema 定义 `turn/plan/updated`、`thread/goal/get`、`thread/goal/updated`、`thread/goal/cleared`、文件变更、命令、补丁与审批。 | 临时会话的 Goal 查询返回 `-32600`。两次提示都未看到 Plan 通知。问答在收到请求后中断，未验证回答回写。本机 App Server schema 未找到通用的 Session 日程清单接口。 |
| DSH | 本地 Host 创建会话和接收 prompt 成功。历史中有 `request/context`，含 `contextWindow`、`model`、`provider`、`systemPromptUpdate`。本轮以 `error` 结束。独立 Host 的 `schedule/catalog` 返回 HTTP 200。 | 本机 DSH 的 journal 与界面有 `goal/change`、`todo/write`、权限、问答、附件和工具。上下文组件能从投影拆出消息、系统提示与工具等来源。日程 catalog 是 Host 级。 | 这次未看到实际 Goal、Todo、HITL 请求，未检查 catalog 条目与写入。 |
| Antigravity | ACP 握手为 v1，`session/new` 返回 `sessionId`、模型、模式和配置。收到消息、思考、`tool_call`、`tool_call_update`。另一次探针中 `Run schedule` 从 `in_progress` 变为 `completed`，prompt 以 `end_turn` 结束。 | ACP 定义 Plan、权限、工具及可选 `usage_update`。产品文档另有 `/goal`、带分类用量的 `/context`、状态行、artifacts 和 side panel。 | 这次未收到 ACP Goal、Plan、usage 或结构化问答，未独立核对定时触发回调。未验证持久日程、Sidecar 或 artifact 清单是否能通过当前 ACP 通道取得。 |

复测时要求 Agent 调用真实工具，并以事件验证。可以直接复用以下提示。

- Codex Plan 模式，要求调用 `request_user_input` 提出两道带两个选项且允许自填的问题，禁止运行命令、读写文件或创建日程。观察服务端请求，核对题目 ID、选项和 `isOther`。
- Codex 默认模式与 DSH，要求更新一个仅含两个临时步骤的真实计划或 Todo，DSH 再请求一道可自填的选项题。采集 `turn/plan/updated` 或 `todo/write` 和实际问答事件。
- Antigravity ACP，要求发出真实 Plan 和结构化问答。另开临时会话，要求三秒后只输出固定测试字符串的一次性会话内定时，不创建周期任务、Sidecar、文件或命令。核对工具调用与更新，并退出临时进程。

## 数据放在哪里

| 范围 | 展示 | 来源与边界 |
| --- | --- | --- |
| Session 输入框上方 | 阻塞的 HITL、当前 Goal、当前 Todo/Plan | 由后端事件驱动。Goal 和 Todo 独立显示，空状态保持隐藏。后端原始审批 ID、选项 ID 和回写方式需要保留。 |
| Session 右栏 | 身份、主机、工作区、模型、上下文使用、文件和会话内定时任务 | 用量只有在当前使用量和窗口大小同时可得时才显示比例。Codex 缓存输入与推理 token 是计算分类，DSH 的消息、系统、工具来源是上下文组成，Antigravity 的 TUI 数据需单独确认 ACP 可得性。保留来源和计量含义。 |
| Session 右栏的专有卡片 | DSH 上下文来源，Codex 推理与缓存明细，Antigravity side panel 产物 | 根据连接能力和实际字段显示。普通对话附件、文件补丁与各家专有产物可以在 Library 分组。 |
| 主机或全局 | 持久或周期日程、跨会话任务，按 Agent 与主机分组 | DSH Host catalog、Antigravity 会话内定时与持久 Sidecar、Codex 产品级 Automations 的所有权和生命周期不同。只有来源能确认所属范围时才归档。 |

本次新增了 DSH `goal/change` 和 `todo/write`、Codex Goal 和 Plan 通知、Antigravity ACP Plan 到规范化事件的映射。桌面已开始接入真实 Runtime，完整端到端验收仍在进行。桌面 DSH 服务已连接 Host 的 `$events` 及 `$events/result`；旧通用 Adapter 的审批方法仍未接入；远程 DSH 结构化问答已有真实服务层闭环，桌面操作与权限审批尚未验收。Codex shared daemon 会广播请求；生产服务仅回答自身发起的回合并等待请求关闭通知，不会替其他客户端抢答。Antigravity permission 回写已用模拟 ACP 请求和响应验收，仍需真实代理请求验证。生产验收要观察一次真实的请求、用户操作、后端确认、同一 Session 继续执行，并验证重连和并发会话的隔离。

## 数据链和验收

仓库已有三家 Adapter 和 MessageTranslator。它们把各家输入转换成 `CanonicalTurn`、`CanonicalStep`、`CanonicalBlock` 和流式事件，Session WebKit 消费统一结构。桌面入口现使用生产服务，本机 Codex 的服务层连接已经开始验证。

macOS 跑了 741 个通过的测试，4 个跳过，`LiveAcceptanceTests` 明确排除。WebKit 回归测试覆盖工具配对、表格横线、右栏主机和带选项与自填的提交 payload。另用 620×556 CSS 像素的相同内容渲染了 DSH 组件样式基准和 Pharos 幕布。iOS Simulator 目标构建成功并启动了 demo，群头像溢出截图来自 390px WebKit 视口。

## 验证总结与待验收清单

记录时间为 2026-11-07，工作树在 `integrate/mesh2-into-main`，基准提交 `1e25b4c`。本轮改动尚在工作树中。测试和截图使用的临时目录已清理，下面的数字与探针结果是当时的观察记录。截图保存在本机 Codex 可视化目录，目录不随 Git 提交。

### 已验证

- [x] macOS 执行 `swift test --skip LiveAcceptanceTests`，记录为 741 通过、4 跳过、0 失败。四个跳过项是需要显式开启的真实后端集成测试。测试主要使用模拟数据和模拟传输。
- [x] WebKit 测试检查 Session 正文、工具调用与结果配对、Markdown HTML 处理、表格横线、Session 主机、VNC 占位、Goal/Todo 展示，以及选项和自填答案进入 Swift bridge 的 payload。
- [x] 相同尺寸、相同示例内容的 DSH 组件样式基准与 Pharos 幕布截图已检查。基准由安装版 DSH 的组件 CSS 和构造的 HTML 生成。截图存在布局和图标差异，仍需真人验收。
- [x] 使用构造数据检查右栏打开时切换 Session，确认 Computer 区域更新为新主机，旧主机不再显示。
- [x] 检查桌面成员叠放、溢出列表最终状态和 390px WebKit 群头像截图。离屏 WKWebView 的动画时钟未推进，溢出列表截图通过将 CSS 动画推进到结束帧获得。
- [x] 录制了 Grok Bot SVG 头像的待机、视线移动和返回状态。该录屏针对头像内核，不覆盖所有交互和状态。
- [x] iOS Simulator 目标构建成功，demo 启动并显示会话。构建时修复了原有 iOS 编译错误，并在临时 DerivedData 内构建 SwiftTerm 插件所需的主机工具。
- [x] release 应用完成打包，WebCanvas 资源与工作树一致，应用签名检查通过。
- [x] 三家隔离探针实际观察到的事件、版本、失败和未捕获项记录在本页“本机探针”。这些观察与桌面端到端验收分别计数。

本机截图目录为 `~/.codex/visualizations/2026/11/07/01a1b530-dfc4-7f81-85f9-d98dc579685c/`。其中 `pharos-session-thread/01-session-dsh-comparison.png` 是幕布对照，`05-thread-overflow.png`、`06-thread-phone.png` 是 Thread 状态，`07` 至 `09` 是右栏和输入区。`pharos-web-fidelity/04-avatar-idle-gaze-return.mp4` 是头像录屏。

### 需要继续验证

- [ ] **真实数据链**。继续完善生产 `PharosClientService`，检查三家真实 Session 的发现、历史、流式消息、发送、停止和恢复。当前只有本机 Codex 的发现、历史与临时会话收发经服务层验证。
- [ ] **HITL 闭环**。对每家观察真实请求、题目和选项 ID、单选、多选、自填、拒绝、提交、后端确认及会话继续。检查连续请求、重复提交、切换会话、断线和失效请求。DSH 的真实结构化问答回写已在服务层观察到，桌面操作及权限审批尚未验收；Codex 自有回合的真实结构化问答已在服务层完成；旁观回合、命令/文件审批和真实桌面点击仍待验收。Antigravity 的 ACP 应答仍需真实请求验收。
- [ ] **Goal 和 Todo**。分别用真实事件验证新增映射的字段、完整快照替换、状态转换、清除、重连后的初始状态和并发 Session 隔离。Codex 临时 Session 不支持 Goal，持久测试 Session 已验证设置、读取、完成和清除；两次提示均未收到真实 Todo/Plan 原始事件。本机隔离 DSH 的 prompt 以错误结束，远程 DSH 已观察到 Goal 和 Todo 创建及重放。
- [ ] **Session 渲染**。用三家真实长会话核对分段、长思考、并发工具、工具失败、重试、流式增量、历史重放和滚动位置。对照 DSH 原应用进一步检查密集度、圆角、代码块和宽表。
- [ ] **输入能力**。逐家验证排队、steer、中断、换行、长输入、空输入、草稿切换、附件与错误恢复。使用真实数据检查多个 HITL 与展开的 Goal/Todo 在小窗口中可见、可滚动和可操作。
- [ ] **右栏**。用真实会话核对同名 Agent 在不同主机上的身份归属、模型和模式、工作区、状态、文件补丁、附件、终端输出和切换时的异步竞态。验证 Thread 右栏的成员、Library 和 Computer。
- [ ] **头像和响应式**。在可见的 macOS 应用中录制并检查成员依次飞入、鼠标移入移出、键盘聚焦、长名单滚动、减少动态效果和亮暗主题。头像内核录屏还需与 brainstorm 原 mockup 同尺寸逐帧比较。
- [ ] **原生 iPhone**。在实际 Room 列表中检查 0、1、2、3、4 和超过 4 人，同名不同成员、缺失成员和稳定 ID。检查触控、动态字体、旁白和深色模式。现有 390px 截图是 WebKit 视口，iOS demo 启动截图未覆盖 Room 列表。
- [ ] **回归与发布**。接入真实服务后重跑相关测试和有隔离环境的 `LiveAcceptanceTests`，核对打包应用的真实启动、重启和多窗口行为。复核本次为了构建 iOS 修复的 roster、节点命令和消息手势。

### 尚未实现或尚无证据

- [ ] VNC 当前只有主机绑定占位，尚无连接、认证、画面、输入或断线恢复。
- [ ] 上下文当前占用、来源比例和费用尚未接入右栏。Codex 用量字段、DSH 上下文来源以及 Antigravity CLI 分类统计的可用范围和语义需要分别核实，ACP 的可得性也待验证。
- [ ] 全局任务与日程、Session 定时任务、Agent 专有卡片和完整 artifact 清单尚未接入。需验证来源、所属主机或 Session、生命周期、刷新与重连。
- [ ] Codex Plan、DSH catalog 内容、Antigravity ACP Goal/Plan/usage/结构化问答尚未观察到；Codex Goal 的真实更新已在桌面验证。远程 DSH 的 Goal、Todo 与结构化问答已在后续复测中观察到，边界见上文。Antigravity 的一次性 schedule 工具完成不代表已观察到定时回调。
- [ ] 当前没有 iOS 原生群头像的视觉截图，也没有真实设备验收。桌面溢出动画没有可见窗口中的实时录屏。
- [ ] 后续复测的脱敏摘要已保存在 `internal/evidence/`；早期探针缺少完整原始事件，不能补称已验证。

2026-11-07 后续检查发现当前 Agent Runtime 已支持 Codex `session.discover`、`session.perform` 和部分 `codex.*` RPC。DSH `session/create` 缺少真实 ID 时已改为报错，审批应答未实现时也明确报错，防止界面误报完成。`swift test --filter TriBackendAdapterTests` 的 5 项通过。三家的真实数据链和 HITL、Goal、Todo 闭环仍待完成。

后续在独立只读、临时 Codex App Server 会话中完成一次真实问答闭环。实际收到一道两选项、允许自填的 `item/tool/requestUserInput`，按生成的 schema 返回自填答案，随后收到 `turn/completed` 且状态为 `completed`，同时收到 token 用量更新。这验证了独立连接的协议请求与回包，Pharos 桌面链路和共享 daemon 的审批所有权仍待验证。DSH 问答转换已补充当前版本的选项对象 `label` 和 `multiSelect`，对应翻译单测通过，真实 DSH 事件与回写仍待验证。

### 桌面生产服务的当前进度

桌面现默认使用 `LivePharosClientService`。本机共享 Codex daemon 的只读验收读取到 99 条 Session，抽查首条读取到 9 个回合。另在共享 daemon 创建一次只读、临时 Codex Session，经过服务发送 prompt，观察到流式增量和带实际助手文本的完成回合。临时 Session 无法从历史接口回读，完成内容现从实时 `item/completed` 事件组装。第一次实时测试因此失败，修正后通过。上述验收覆盖服务层，尚未从桌面 WebKit 进行端到端操作。

本轮完整回归记录为 742 项通过、6 项跳过，未运行 `LiveAcceptanceTests`。此后补充了运行中 Session 的 steer 状态、断线后重新连接及 Codex 思考和命令输出字段，并重跑服务测试和只读临时回合测试。release 应用重新打包并通过签名检查。

- [ ] 服务已接入本机三家、配置的远程 Codex 与 DSH、Thread 和 Projects；远程 Antigravity、完整交互和 UI 验收仍待完成。
- [ ] Codex 服务仅回答自身发起回合的审批；真实结构化问答服务层已通过，其他客户端回合、命令/文件审批及桌面点击仍未验收。
- [ ] Goal、Todo 实时通知已映射，真实更新、初始快照、断线重连与并发隔离尚未在桌面服务验证。
- [ ] 完成事件的实时组装还需验证多种工具、错误和重连，历史转换需覆盖各家富内容和长会话。

- [Codex App Server 文档](https://developers.openai.com/codex/app-server)
- [ACP Prompt Turn](https://agentclientprotocol.com/protocol/v1/prompt-turn) · [ACP Agent Plan](https://agentclientprotocol.com/protocol/v1/agent-plan)
- [Antigravity Context](https://www.antigravity.google/docs/cli/commands/context) · [Goal](https://antigravity.google/docs/commands/goal) · [Schedule](https://antigravity.google/docs/commands/schedule) · [CLI 状态行](https://antigravity.google/docs/cli/statusline/)
- [Pharos Backend Matrix](BACKEND-MATRIX.md) · [RFC-006](RFC-006-UNIFIED-CLIENT-AND-BACKEND-INTEGRATION.md)

2026-11-07：Antigravity 桌面服务补充当前连接的待处理权限快照和回合结束撤回；模拟 ACP 对端验证了快照与回复后清空，真实权限请求、异常撤回及跨进程恢复仍未验证。细节见 [Antigravity 记录](2026-11-07_antigravity-session-validation.md)。

2026-11-07：DSH 交互流断开后自动退避重连；真实隔离 Host 配合模拟交互流验证了撤回、重订阅和新请求回写，远程真实网络故障恢复尚未验证。见 [DSH 记录](2026-11-07_dsh-session-validation.md)。

2026-11-07：DSH Session follow 流增加重试与 journal 序号补读；模拟 Host 覆盖断线期间 Goal/Todo 更新与重复事件去重，真实远程读取未模拟网络故障。详见 [DSH 记录](2026-11-07_dsh-session-validation.md)。

2026-11-07：Thread 对已打开房间每 3 秒读取 Mesh roster，右栏显示其状态；隔离 Broker 测试验证 unknown→busy 自动刷新及 blocked 更新，WKWebView 分别验证渲染。状态来源、厂商上报和真实 Thread 消息链的边界见 [各 Agent 的 Thread 记录](agents/README.md)。

2026-11-07：mac-air 真实 DSH Session 经生产桌面 WKWebView 提问、选择并提交，助手正文与 journal 完成均已核对；Goal 和两项 Todo 实际显示。程序驱动 DOM，不等于物理鼠标；后续已验证权限拒绝和单次允许，网络恢复仍待验收；后续已验证真实桌面 Goal active→complete 和 Todo 全生命周期，Goal 清除仍未观察到。完整过程和首次测试选择竞态见 [DSH 分项记录](2026-11-07_dsh-session-validation.md)。

2026-11-07：本机 Codex shared daemon 的持久测试 Session 在生产桌面通过程序驱动 WKWebView 完成结构化问答、助手回复及持久历史确认；测试注入 Plan 模式。真实 Goal 在桌面显示，测试通过 API 设置完成和清除后，桌面均更新。Todo 原始事件、物理鼠标和桌面 Goal 操作仍未验收；详见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

2026-11-07：远程 Antigravity SSH ACP 发现及桌面 Session 路由已实现；模拟 ACP 端验证了带主机前缀的历史、Plan、审批和完成，mac-pro 真实 `session/list` 仍被拒绝，真实会话和 SSH 故障恢复未验证。细节见 [Antigravity 验证记录](2026-11-07_antigravity-session-validation.md)。

2026-11-07：Antigravity 真实权限事件的 JSON-RPC ID 为字符串；此前过滤整数导致被忽略，现已修复并保留类型。真实桌面 WKWebView 提交拒绝、ACP 回合结束已验证；两次服务和桌面运行未观察到拒绝后的助手正文。真实 Plan 模式未出现 Plan 更新。完整实验见 [Antigravity 记录](2026-11-07_antigravity-session-validation.md)。

2026-11-07：Antigravity 真实桌面单次允许精确匹配的安全命令，确认工具输出和助手正文显示；此前拒绝分支无后续正文仍单独保留。权限卡已按各后端可用选项展示按钮，详情见各 Agent 文档。

2026-11-07：DSH 远程真实权限请求经程序驱动桌面 WebKit 拒绝，journal 记录 rejected，助手确认并完成；后续安全命令单次允许也已验证，真实网络恢复仍未验收。详见 [DSH 记录](2026-11-07_dsh-session-validation.md)。

2026-11-07：DSH 真实 waterfall 与 journal 的 callId、工具名关联已核对；权限卡异步显示唯一匹配的命令，实际远程 WebKit 拒绝流程再次通过。取消及重复匹配由模拟测试覆盖；详见 [DSH 记录](2026-11-07_dsh-session-validation.md)。

2026-11-07：Projects 使用稳定项目 UUID，按本机 Host 及 checkout 路径关联已发现 Session；界面可打开关联会话，未把 unknown 状态统计成已知空闲。真实本机 Session 清单与隔离项目映射、模拟桌面跳转已验证；后续已接入远程 checkout 映射。详见 [Project 关联记录](2026-11-07_project-session-routing.md)。

2026-11-07：Projects 已只读获取配置 SSH Mac 的主机本地 UUID→checkout 映射，并按主机关联远程 Session；mac-air 真实路径和真实远程清单匹配通过，WebKit 跳转经模拟验证。不可用主机和断线不推断关联，详见 [Project 记录](2026-11-07_project-session-routing.md)。

2026-11-07：DSH 远程真实桌面已逐步验证 Todo 创建、推进、完成、清空及完成回合，桌面退出后独立 journal 重放通过；可见性使用程序展开，非物理鼠标。多 Host 争用和测试隧道边界见 [DSH 记录](2026-11-07_dsh-session-validation.md)。

2026-11-07：DSH 远程真实桌面 Goal active→complete 与问答回写已验证，随后清除请求未产生 clear 事件；独立 journal 和复现边界见 [DSH 记录](2026-11-07_dsh-session-validation.md)。

2026-11-07：隔离 Broker → Codex 定向投递已验证，但真实 Codex workspace-write 工具进程对隔离 Broker Unix socket 返回 EPERM，直接 CLI 回复失败；宿主进程能连接。后续已实现宿主侧关联、路由及幂等，本机隔离真实桌面往返通过；远程和分布式仍待验证，详见 [Codex Thread 记录](agents/codex/threads/2026-11-07_protocol.md)。

2026-11-07：本机隔离真实 Codex Thread 已经生产桌面 WebKit 发送并显示宿主转发回复，Broker 历史确认唯一回复和原消息关联；远程、分布式和界面引用展示仍待验证。详见 [Codex Thread 记录](agents/codex/threads/2026-11-07_protocol.md)。


## 2026-11-08 Session 输入能力新增要求

动态权限模式、模型目录与切换、图片及文档附件发送均加入待办，按真实 Session/主机及各家能力实现，不把当前硬编码控件视为完成。现状、逐家验收和公开协议研究起点见 [Session 输入能力清单](2026-11-08_session-composer-capabilities.md)。

2026-11-08：本机隔离真实 DSH Thread 经生产桌面 WebKit 发出定向消息，真实 Session 完成并经 Broker 返回唯一关联回复，桌面显示回复；此前仅验证 Broker 往返的状态由此更新。测试注入项目插件并隔离房间，远程、分布式、生产 profile 并存和真实断线仍待验收，详见 [DSH Thread 协议](agents/dsh/threads/2026-11-07_protocol.md)。
