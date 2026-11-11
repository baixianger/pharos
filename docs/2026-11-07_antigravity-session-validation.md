---
summary: Real Antigravity allow-once and rejection flow through desktop WebKit; approved command output and final reply are verified, while Goal/Todo and remote authentication remain open.
---

# Antigravity Session 接入与验证

## 环境与链路

2026-11-07 本机 Antigravity CLI 1.5.1，mac-pro 为 1.5.2。桌面通过 ACP `initialize`、`session/list`、`session/load` 和 `session/prompt` 访问本机会话；每个打开的 Session 拥有独立 ACP 子进程，接收 `session/update` 和 `session/request_permission`。审批 ID 包含 Session 标识和带类型的请求 ID，避免不同 ACP 子进程复用数字或字符串请求 ID 时相互干扰。

实现入口：[ACP 进程传输](../Sources/PharosRuntime/Adapters/Agy/AgyBackendAdapter.swift)、[会话服务](../Sources/PharosRuntime/Adapters/Agy/AgyLiveSessionService.swift)、[重放映射](../Sources/PharosRuntime/Adapters/Agy/AgySessionHistoryReader.swift)。跨后端任务见 [Session 总记录](2026-11-07_session-surfaces.md)。

## 已验证

- 本机 ACP 列表返回真实 Session；独立测试 Session 在新 ACP 进程中 `session/load`，重放真实用户和助手消息，并通过生产服务继续发送、收到真实回复及完成。
- 真实独立进程承载的模拟 ACP 对端验证了 Plan 快照、权限请求、`optionId` 回写和客户端/服务端数字请求 ID 碰撞。该 fixture 只证明协议实现，不证明真实模型会提出这些请求。
- 一次独立探针观察到会话内一次性 schedule 工具从运行到完成；没有验证到定时回调，也不能推断持久周期日程或 artifact 清单可通过 ACP 获得。

## 未验证与限制

- 早期两次权限探针未识别请求：后续原始流证明 Antigravity 使用字符串 JSON-RPC ID，而服务此前只接收整数。修复后真实权限拒绝经桌面 WebKit 回写并收到 `end_turn`；拒绝后的助手正文在服务和桌面两次运行均未观察到，仍未验证。
- 尚未观察到真实 ACP Plan、Goal、usage 或结构化问答事件；Goal/Todo 的实际创建、更新、清除和重连状态均待验证，不以 fixture 代替。
- mac-pro 1.5.2 ACP 初始化成功，但 `session/list` 返回 `-32000` 认证错误；检查的 CLI conversations 目录没有会话数据库。mac-air 未发现 Antigravity CLI。远程 Antigravity 的 SSH ACP 路由已实现，但 mac-pro 的列表请求仍被拒绝，尚无真实远程会话验收；没有更改远程认证。
- `steer` 尚未连接；进程异常后 UI 活动状态和重新连接、不同会话的并发审批需继续验收。

## 2026-11-07 待处理权限恢复

桌面服务现在可读取当前 ACP 连接中待处理的权限请求；已打开 Session 时切换回来可以恢复提示。回复后快照清空，回合结束或请求失败时撤回旧提示。`AgySessionHistoryReaderTests.testPermissionAndPlanThroughACPConnection` 通过模拟 ACP 对端核验请求快照与回复后清空；回合异常撤回和真实 Antigravity 权限对话仍需实测。此快照只存在于当前进程连接，重启后能否恢复取决于代理是否重新发送请求，尚未验证。

## 2026-11-07 远程 ACP 路由

桌面按 `hosts.json` 的 SSH 主机运行固定的 `agy acp --stdio`：ACP `session/list` 用于发现；每个打开的远程 Session 用 SSH stdio 的独立 ACP 子进程执行 `session/load`、`session/prompt` 和权限回写。Session ID 以主机和 `agy` 前缀隔离；工作目录采用远端清单中的 cwd，缺失时明确报错。一次远程清单失败保留已发现的快照和已打开的 ACP 连接，避免临时失败直接关闭正在运行的会话；改变同一主机的 SSH 目标时废弃该主机旧快照和连接。后续已为已缓存会话标注清单过期，并在首次清单失败时展示主机级不可用提示，详见 2026-11-08 补充。

`DesktopPharosClientServiceTests.testRemoteAgyDesktopRoutesACPWhenEnabled` 通过独立 Python ACP 模拟进程验证远程 Session ID、cwd、历史路由、Plan 更新、权限拒绝回写、回合完成及进度读取；`AgySessionHistoryReaderTests.testRemotePrefixedPermissionAndPlanThroughACPConnection` 验证远程前缀与交互映射。这些均未经过真实 SSH Agent。修改后真实 mac-air 的 Codex 和 DSH Session 发现、历史读取回归通过；mac-pro 使用新命令实测 `session/list` 被拒绝（之前的单独协议探针观察到认证错误），不能记为远程 Antigravity 端到端成功。SSH 意外中断、重连、退出清理、多个主机同 ID、真实权限与桌面操作均待验证。

## 2026-11-07 真实权限 ID 与桌面回写

先在独立 ACP 测试 Session 中使用 default 模式，要求计划和无副作用的 `printf`，对任何权限请求选择拒绝。前两次在 60 秒内只观察到工具 pending，未收到可识别权限事件；追加原始方法名观测发现服务端实际发出 `session/request_permission`。进一步核对请求字段：`params` 包含 `sessionId`、`toolCall`、`options`，Session 匹配，但 JSON-RPC `id` 是字符串。旧服务只接受整数 ID，导致真实请求被忽略并卡住；之前的“未诱发”结论因此不能成立。

服务现在保留整数或字符串 ID 的类型并原样回写，公开审批 ID 使用带类型标识的编码并含 Session 前缀；整数碰撞和远程字符串 ID 模拟测试通过。原始 ACP 探针选择 reject 选项后收到 `end_turn`，一次原始流有 assistant message。随后独立真实服务测试和生产桌面 WKWebView 测试均观察到权限卡、拒绝回写和 completed；这两次均没有观察到拒绝后的助手正文或正文增量，不能称为已验证拒绝后完整回复。桌面测试 Session `d8328d7a-d489-4b5b-a697-f958b141edfc` 保留。测试使用程序驱动 DOM，尚未实测物理鼠标、多请求、同意、过期和重连。

ACP `session/new` 实测声明 `default`、`accept-edits`、`plan` 模式。显式切换 plan 并提示使用真实计划工具后，回合 `end_turn`，但只见普通消息、思考和模式更新，没有工具调用或 `plan` 更新；该探针跳过，不能推断 Plan/Todo 不支持或已通过。桌面当前尚未提供模式切换。测试日志保存在 `internal/evidence/`；其余原始应用日志未纳入版本库。

## 2026-11-07 真实单次允许与选项

本机 1.5.1 新建持久测试 Session `9032460c-1163-43af-a254-d42035f105dc`，用生产桌面服务及程序驱动 WKWebView 诱发权限。测试在批准前严格核对实际工具参数为无副作用的 `printf PHAROS_PERMISSION_TEST`（只接受精确的等价引号形式），且后端确实提供 `allow_once`；不匹配时跳过而不批准。本次实际选项为 reject 和 allow once，界面提交单次允许后服务收到 resolved 与 completed，规范化工具结果含命令输出标记，助手最终正文标记在桌面显示。此前拒绝运行的回合结束但未观察到后续助手正文，两种结果不混为一谈。真实测试 Session 保留供检查，非物理鼠标操作。

权限规范化请求新增 `availableChoices`：Antigravity 按 ACP options 提供的种类映射，Codex 按可识别的 availableDecisions 映射，DSH 只暴露已实现的拒绝与单次允许；Codex 结构化问题只显示提交。WebKit 根据提供的选择显示按钮，老消息缺少字段时沿用原有默认；不可映射的后端选项不会伪造支持。真实多请求、持久授权及不同厂商所有选项仍需验证。


## 2026-11-07 第二种真实 Plan 提示

本机 CLI 1.5.1 的隔离 ACP Session 再次切换 `plan` 模式，以虚构疏散演练要求通过结构化计划分别发布 Assess、Report 的状态，禁止命令、文件、网络和外部更改。实际回合返回 `end_turn`，观察到 user/agent message、thought、可用命令和配置更新，没有 `plan`、工具调用或权限请求；测试明确标记 skipped，不把 XCTest 退出码视作通过。脱敏结果见 `internal/evidence/2026-11-07_agy-plan-alt.log`。这只能说明该次提示没有暴露结构化数据，不能证明所有 Antigravity 模型或 ACP 版本均不支持；真实 Goal/Todo 的创建、更新和重连仍不可验证。

### 2026-11-08 本机 1.5.3 复查与受控完整流程

在独立配置和工作目录中，真实 `agy 1.5.3` 宣告 `plan` 模式并接受设置；要求使用计划工具发布并推进两项纯心算任务，不运行命令或访问文件和网络。回合返回 `end_turn`，有消息、思考和配置更新，但没有 `plan`、工具或权限事件，测试明确 skipped（`internal/evidence/2026-11-08_agy-plan-current-live.log`）。这更新了版本范围，但仅代表该次提示，不能断言该 Agent 永不支持或发出计划。

另用独立 Python ACP 模拟进程，通过生产桌面服务和程序驱动 WKWebView，发送四个受控回合，逐项验证完整计划替换：进行中/待办 → 完成/进行中 → 两项完成 → 空列表；在完成及清空后分别以新模拟 ACP 进程重载，确认对应快照（`...agy-plan-lifecycle-fixture.log`，含相关回归共 17 项）。这些是 fixture 数据，不是实际 Antigravity 发出的计划、持久化或重连结果。ACP [Plan 规范](https://agentclientprotocol.com/protocol/v1/agent-plan)要求每次更新提供完整列表，并定义 priority；priority 的后续接入见下文。真实 Goal/Todo 和远程验收仍未完成。

后续将 ACP Plan 的 `priority` 按原值加入规范化 Todo 并在输入区显示；缺失时留空，未知字符串保留，不为 DSH 或 Codex 推断优先级。独立模拟 ACP 的 high/low 在创建、更新、完成及新进程模拟重载后均与界面一致；空列表无优先级。旧版无该字段的数据仍能解码；其他厂商、计划隔离和 Session 回归见 `internal/evidence/2026-11-08_agy-plan-priority-regression.log`、`...agy-plan-priority-final.log`。这不改变尚未观察到真实 Antigravity Plan/priority 的结论。


## ACP 请求报错结束回合

模拟 ACP 在审批等待期间返回 prompt 错误，修复前没有回合结束，修复后验证同 ID 的失败回合、部分内容、审批撤回和内存历史；本地与远程前缀的现有权限测试通过。此处为模拟 JSON-RPC 错误，非真实断网或进程崩溃；后续受控 ACP 子进程退出测试验证已到达 transport 的 recording 会保留；真实断网和尾部读取竞态仍未验证。详见 [Antigravity Session 协议](agents/antigravity/sessions/2026-11-07_protocol.md)。


## Thread 发起的真实权限回合

本机真实 ACP Session 的 Thread 定向消息触发安全命令权限请求；在该 Session 经桌面程序驱动 WebKit 单次允许后，观察成功工具输出、completed 回合以及原 Thread 唯一关联回复。详见 [Thread 验证](agents/antigravity/threads/2026-11-07_protocol.md)；拒绝、远程、断网等未由此次测试覆盖。


本机 Thread 成员离开与重新加入后的 Runtime 上下线已通过真实桌面测试；进行中离开仅经模拟 ACP 事件验证，见 [Thread 文档](agents/antigravity/threads/2026-11-07_protocol.md)。


## 2026-11-08 远程 Antigravity 清单失败与缓存

桌面远程 Antigravity 的 ACP 清单请求失败时，保留同一主机最后一次成功清单和已打开 ACP 服务，但将缓存 Session 的状态设为 unknown 并标注 `inventoryStale`；Session 和 Project 列表显示清单不可用。恢复成功用新清单替换缓存，成功空清单移除原会话；SSH 目标变化清除旧服务和旧缓存。共享 SSH 建立失败时也保留同目标旧清单并标记过期；此时原服务已关闭，对该 Session 的读取明确报后端不可用，而不是假装能连接。错误诊断仅记录错误域及代码，不保存 ACP 输出。

受控 Python ACP 对端测试在清单故障前加载会话、故障后继续完成 Plan 和权限拒绝回写，证明服务未因单次清单失败被销毁；恢复后标记消失。随后使用隔离 hosts 文件配置无效 SSH 目标，让实际桌面刷新走共享 SSH 建连失败分支，检查 Session 仍在清单且标记过期、读取明确不可用；改变目标后旧 Session 不再可访问。相关测试及 DSH 既有回归通过（`internal/evidence/2026-11-08_agy-inventory-stale-real-refresh.log`）；随后补充成功空清单撤销旧绑定并回归通过（`...agy-inventory-stale-final.log`）。程序驱动 WebKit 使用 Antigravity 缓存行，验证 Session 和 Project 展示过期标记（`...agy-inventory-stale-ui.log`）。这些是模拟 ACP 和受控 SSH 失败，不是 mac-pro 真实认证恢复。

mac-pro 以前的 ACP 列表仍有认证拒绝的实测记录；本次没有改变远端认证，也没有证明真实远程 Antigravity Session 恢复。首次发现失败时的主机级提示见下一节；真实远程 HITL、Goal、Todo 和断线恢复仍待验收。


## 2026-11-08 首次清单失败提示

桌面服务以主机和 Agent 返回清单不可用状态，即使该主机从未取得任何 Session，也可在 Session 侧栏显示 `Antigravity sessions unavailable · <host>`；成功刷新或移除主机后清除状态。提示只表明清单不可用，不推断是 CLI 未安装、认证、网络或其他原因；收起侧栏时以带可访问标签和悬停文字的提示符显示。已有缓存行仍单独标记过期。当前主机级提示仅覆盖远程 Antigravity，DSH/Codex 首次发现失败尚未接入这一提示。

隔离桌面服务测试对无缓存的测试主机模拟 SSH 建连失败，确认返回主机级状态；另验证 ACP 成功后状态清除。使用模拟服务和程序驱动 WKWebView，在零 Session 时观察提示、切换 Thread 时隐藏、模拟恢复后下一轮刷新清除（`internal/evidence/2026-11-08_agy-inventory-status-final-retry.log`）。这不是远程认证恢复或物理操作验收。中断前最后一次测试只完成构建，进程和句柄均已结束，随后重新执行并通过。

只读重查 mac-pro 的 `agy acp --stdio`：共享 SSH 建立后 `session/list` 仍被拒绝，探针明确 skipped（`internal/evidence/2026-11-08_agy-inventory-real-recheck.log`）。此次没有获取具体认证错误，不将拒绝直接归因于认证；未更改远端认证，真实远程 Session 与 HITL、Goal、Todo 仍未验证。


2026-11-08 本机 CLI 已为 1.5.3：隔离 ACP Session 的初始化、创建和重载实际返回图片/嵌入上下文声明、动态模型、模式和配置；生产服务已保留打开时按 Session 隔离的能力快照。`plan` 设置响应成功后重载仍为 `default`，没有证明其生效或持久；输入 UI、实时变更、实际附件发送和远程验证仍待完成。版本、证据和限制见 [Session 协议](agents/antigravity/sessions/2026-11-07_protocol.md)。


2026-11-08 桌面输入区已按 Antigravity ACP 动态 select 配置显示和提交选项，处理 Session 配置通知；真实本机 ACP 隔离测试经生产 WKWebView 切换 `plan` 和另一模型，服务响应及界面一致，无新增模型回合。测试使用固定模拟清单与本地 ACP，不代表远程 SSH、推理实际生效或模式持久化；细节见 [Session 协议](agents/antigravity/sessions/2026-11-07_protocol.md)。
