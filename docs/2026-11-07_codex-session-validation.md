---
summary: Local and remote Codex Goal protocol and desktop display are verified in test Sessions; structured Todo remains unverified.
---

# Codex Session 接入与验证

## 2026-11-08 远程 Goal 创建、展示和清除

在 mac-air 上新建专用持久 Session `01a1bb52-85f7-7ce3-97ac-0223b4405e8c`，只读沙箱内完成无工具种子回合；通过远程 App Server `thread/goal/set` 创建 paused Goal、读取、标记 complete、清除，生产 Session 服务的进度与后端结果一致（`internal/evidence/2026-11-08_codex-remote-goal-probe.log`）。这是协议主动设置，不是模型主动创建 Goal。

随后在同一测试 Session 再建 paused Goal，生产桌面从真实远程 Session 清单发现并打开，程序操作 WKWebView 核对初始 Goal；通过共享 SSH 上的独立协议连接依次标记 complete 和清除，桌面观察到两次更新，服务独立读取一致（`...codex-remote-goal-desktop.log`）。测试没有从桌面输入控件创建或修改 Goal，也不证明物理鼠标操作。第三次独立 SSH 连接恢复同一 Session，Goal 为空且种子回复在历史中（`...codex-remote-goal-replay.log`）；测试 Session 保留。mac-air 当前 CLI 显示 `codex-cli 0.162.1`，已有 App Server 进程的确切构建版本未单独验证。

此前本记录的“远程 Goal 尚未验证”仅反映当时状态；本次已验证上述远程协议和桌面显示，真实模型主动发起 Goal、断网恢复及不同远程版本仍未验收。

## 环境与链路

2026-11-07 本机 Codex CLI 0.166.0；mac-air CLI 0.162.1。桌面生产服务使用现有 shared daemon 的 Unix socket，读取 `thread/list` 和 `thread/read`，通过 `turn/start` 发送并订阅通知。远程 Codex 使用 SSH 将同一用户的远端 socket 转发到权限为 0700 的本地临时目录；Session ID 包含主机前缀，避免不同主机碰撞。只遍历用户在 `hosts.json` 配置的 SSH 主机，不代表 Mesh 全部节点。远端没有部署或升级。

实现入口：[本地 Session 服务](../Sources/PharosRuntime/LivePharosClientService.swift)、[远程连接](../Sources/PharosRuntime/Adapters/Codex/RemoteCodexTransport.swift)、[桌面路由](../Sources/Pharos/UI/Shell/DesktopPharosClientService.swift)。总任务与证据范围见 [Session 总记录](2026-11-07_session-surfaces.md)。

## 已验证

- 本机生产服务读取列表和历史，在只读沙箱的临时 Session 发送提示，接收真实文本增量与完成事件。
- mac-air 经 SSH 读取 7 个 Session 和其中一个的 12 个历史回合；独立临时只读会话的真实发送、回复和完成事件通过。`LivePharosClientServiceTests.testRemoteCodexReadOnlyWhenExplicitlyEnabled`、`testRemoteCodexDisposableTurnWhenExplicitlyEnabled` 为显式启用的真实探针。
- 独立 stdio App Server 的临时会话真实发出 `item/tool/requestUserInput`；测试按问题 ID 回写自填答案，收到 `turn/completed`。
- shared daemon 的两个连接都能收到同一个服务端请求；由 Pharos 发起回合的连接回写后观察到 `serverRequest/resolved` 和 `turn/completed`。生产 `LivePharosClientService` 真实问答闭环通过；模拟广播测试确认旁观服务不会显示或回写不属于自己发起回合的请求。
- 持久测试 Session 的 Goal 设置为 paused 后，可通过服务读取；随后设置为 complete 并清除，服务读取分别返回完成状态与空 Goal；模拟慢旧快照与新事件交错的测试确认旧快照不会覆盖新 Goal。临时 `ephemeral` Session 的 Goal 查询明确不支持；不应将其误判为所有 Session 均不支持。
- 用量通知可观察 `last`、`total` 和 `modelContextWindow`，但桌面右栏聚合与计量含义仍需实测。

## 未验证与限制

- 只允许处理 Pharos 自己通过该连接发起的回合；正在由其他客户端运行的会话仍只能旁观，不会抢答。请求通过 JSON-RPC 回写并等待 `serverRequest/resolved`；该通知也可能表示其他客户端已回答或请求已清除，因此并发抢答时不能仅凭它证明本客户端的选择生效。数字及字符串请求 ID 均有覆盖（真实 daemon 与模拟服务分别验证）。程序驱动的真实桌面 WebKit 问答、命令审批取消和文件审批拒绝已通过；物理鼠标、实际允许、问答取消、并发和重连仍未验收。
- 持久 Session 的 Goal 测试使用独立 stdio App Server；本机 shared daemon 的真实桌面 Goal 读取、完成和清除显示已通过；远程 Goal、模型主动创建 Goal 和 Todo/Plan 通知尚未验证。两次明确提示调用 `update_plan` 的真实测试均正常结束，但原始事件没有 `turn/plan/updated`，未证明代理调用该工具；不能称为 Todo 已通过。临时 Session 返回 `-32600`。
- SSH 健壮性、断线恢复、多主机并发、与实际桌面 WebKit 的闭环尚未验收；远程 DSH 和 Antigravity 能力各自独立，不由 Codex 结果推断。

## 2026-11-07 审批所有权与测试

1. 独立 App Server 可拥有并回答自己发起的真实结构化问答；但尝试在 shared daemon 仍持有写入权时用另一个 App Server 恢复同一持久 Session，服务端返回 `already has an active writer`。因此生产路径没有尝试强行接管其他客户端的会话。
2. shared daemon 将请求广播给多个订阅连接。桌面服务只接受其 `turn/start` 返回的 `turnId` 所属请求，按 Session 和请求 ID 排队；监听者不属于回合时既不展示可回答请求，也不写回。缓冲 `turn/start` 响应前到达的事件，避免快速请求丢失。
3. 支持结构化答案、命令与文件变更审批的协议回写，数字和字符串请求 ID 均保留类型；问答取消、其他未覆盖的 server request 类型仍明确未接入。提交后等待请求关闭通知；超时报告已发送但未确认，避免自动重试。请求结束或回合结束时撤回未决 UI。
4. `PHAROS_CODEX_OWNED_TEST=1` 下的 `testLiveServiceOwnedQuestionWhenEnabled` 和 `testDaemonQuestionOwnershipWhenEnabled` 观察真实请求、回写、服务端关闭和正常完成；`testOnlyInitiatingServiceCanResolveBroadcastRequest` 为模拟隔离测试；`testPersistentCodexGoalWhenEnabled` 为持久测试 Session 的 Goal 验证。这些测试创建临时或持久测试 Session，后者保留供检查。

[OpenAI Codex App Server 文档](https://developers.openai.com/codex/app-server)说明审批由服务端请求、客户端回写，并以 `serverRequest/resolved` 表示请求被回答或清除；具体多连接行为以上述本机 daemon 实测为准。

## 2026-11-07 真实桌面问答和 Goal

`WorkspaceWebViewTests.testCodexRealQuestionThroughDesktopWhenEnabled` 经本机 0.166.0 shared daemon 新建持久测试 Session 并完成只读种子回合，再通过生产 `DesktopPharosClientService`、`PharosMainShellView` 和 WKWebView 打开该 Session。测试通过传输包装器为新回合指定 Plan 模式，诱发真实 `request_user_input`，通过 WebKit 选项提交；助手正文显示标记，`thread/read` 确认同一回合 completed。最终测试 Session 为 `01a1b750-8aa2-7160-8a5b-df59efe4abb5`，保留供检查。测试使用程序驱动 DOM，不是物理鼠标；Plan 模式由测试注入，当前桌面没有提供 Plan 模式选择，不能推断普通模式必然出现问答。

同一测试先通过真实 daemon API 设置 paused Goal，桌面输入区显示其 objective；再由测试调用 API 设置 complete 和 clear，观察到两个事件分别使桌面显示完成并移除 Goal。它验证读取与事件渲染，不表示桌面已有创建、完成或清除 Goal 的用户操作，也不代表模型主动创建 Goal。Codex Todo 两次探针未观察到真实 `turn/plan/updated`，仍待验证。

2026-11-07：结构化问答仅显示当前服务支持的提交操作；命令/文件权限按可识别的 `availableDecisions` 显示相应选项。此为适配逻辑和模拟测试，真实命令/文件审批尚未验收。

2026-11-07：列表状态依据本机生成的 App Server schema 映射；`notLoaded`、`systemError` 和缺失状态显示 unknown，而不是假定 idle。此为协议映射与测试，未提供错误根因详情。


2026-11-07 隔离 Mesh Broker 和 Rust Runtime 定向消息已进入真实 Codex 持久 Session 并观察到助手正文及 completed；这不是桌面 UI 或自动回复 Thread 的验证。临时 Session 的 `thread/read(includeTurns: true)` 不受支持，故不能用其读取结果证明完成。详见 [Codex Thread 验证](agents/codex/threads/2026-11-07_protocol.md)。

## CLI 命令审批：取消回合

2026-11-07，本机 Codex CLI 0.166.0 的独立 stdio App Server、只读沙箱和 `on-request` 策略下，以安全 `printf` 请求命令审批。真实协议提供 `accept`、`acceptWithExecpolicyAmendment` 和 `cancel`，未提供 `decline`。此前适配器遗漏 `cancel`，导致无法提供取消动作；现区分 `cancel`（拒绝并中断回合）与 `decline`（拒绝但继续），只显示实际提供的动作，不把未知动作当作允许。`testRealCodexCommandApprovalRejectionWhenEnabled` 观察到真实请求、`cancel` 回写、服务端确认和 cancelled 回合；没有助手后续正文符合回合取消。原始输出保存在 `internal/evidence/2026-11-07_codex-cli-approval-cancel.log`，诊断结果在 `internal/evidence/2026-11-07_codex-cli-approval-wire.log`。

`testCodexCancelTurnIsDistinctFromDecline` 用模拟协议验证选项区别及回写；`WorkspaceWebViewTests.testCodexCancelTurnApprovalIsPresentedAndForwarded` 用模拟数据验证 WebKit 按钮和消息。真实 `decline`、命令允许、文件审批、远程审批均未由这组测试证明。

## 真实桌面命令审批

`WorkspaceWebViewTests.testRealCodexCommandCancelThroughDesktopWhenEnabled` 使用本机 CLI 0.166.0 shared App Server 创建独立持久 Session，先完成只读种子回合，再由生产桌面服务和 WKWebView 选中该会话并发送请求。测试在原始事件中确认审批命令含安全 `printf PHAROS_CODEX_UI_APPROVAL_TEST` 且实际提供 `cancel`，以程序操作 WebKit 的取消按钮；审批卡消失、运行指示停止，同一 turn 的服务端历史为 cancelled。Session `01a1b7bd-d42a-72f3-9969-54658a30243b` 保留供检查；原始输出为 `internal/evidence/2026-11-07_codex-command-desktop-seeded.log`。这是程序驱动 UI，不是物理鼠标，也不证明允许或普通拒绝流程。

首次创建会话后未发送任何回合，测试在 70 秒内没有在桌面列表找到它，未进入审批阶段；记录 `internal/evidence/2026-11-07_codex-command-desktop.log`，Session `01a1b7bc-474c-7553-a05d-29ab682bc6c6`。后续种子回合后列表可见；尚未确认空会话不显示的具体原因，不能将其归因于某个组件。

## 真实文件变更审批与详情（2026-11-08）

本机 Codex CLI 0.166.0 的独立 App Server 在只读临时工作区发出 `item/fileChange/requestApproval`；生产 Session 服务对该请求回写 `decline`，收到同一审批的 resolved 通知，回合 completed，测试文件未创建（`internal/evidence/2026-11-08_codex-file-approval-shape.log`）。真实事件中，请求包含 `threadId`、`turnId` 和 `itemId`，而拟议文件路径和 patch 在此前 `item/started` 的 `fileChange.changes`；该次事件观察到一个变更且 item ID 匹配。

桌面服务现按同一 Session、turn 和 item ID 将此前的变更详情带入审批卡；没有匹配详情时保持不可用，不借用其他回合或 Session 的内容。真实 shared daemon 的专用持久 Session `01a1ba82-3a16-7703-897b-fde1c8a1366b` 经程序驱动生产 WKWebView 触发文件审批，卡片实际显示测试文件名及拟议内容，点击拒绝后收到同一审批 resolved、回合结束且文件未创建（`...codex-file-approval-details-final.log`）。受控事件验证跨 Session 和旧回合的隔离以及旁观连接不能抢答（`...codex-file-approval-isolation.log`）。测试工作区已清理，专用持久 Session 仍保留并引用该临时路径。

该阶段验证拒绝路径，后续单次允许实验见下；远程文件审批、多文件与大 patch、缺少或乱序 `item/started`、多人并发以及真实断网仍未验收。审批 resolved 表示服务端关闭该请求，在多客户端并发情况下不单独证明是谁作出决定。

### 单次允许及文件变更历史（2026-11-08）

独立临时只读工作区中，对真实文件审批做严格预检：只有一项变更，规范化路径精确指向测试目录中的 `approval-probe.txt`，类型为 `add`，拟议内容完全等于专用标记，文件此前不存在，且后端提供单次允许，才提交 `allowed_once`；所有其他请求只拒绝或取消。服务层实际观察到允许确认、completed，以及测试目录内唯一文件的精确内容（`internal/evidence/2026-11-08_codex-file-allow-service.log`）。

首次预检误以为新增文件的 `diff` 必须是带 `+` 的统一 diff，因此两次拒绝并 skipped，未创建文件（`...codex-file-allow-real.log`、`...codex-file-allow-shape.log`）。实际本版本 `add` 的 `diff` 是原始文件内容；严格比较整个内容后才允许。首次桌面测试未收到文件审批、未创建文件（`...codex-file-allow-desktop.log`）；明确提示调用 `apply_patch` 后，生产 WKWebView 单次允许、对应请求确认、文件实际内容和完成回合均通过（`...codex-file-allow-desktop-retry.log`）。再次运行同一桌面流程并额外检查历史，专用 Session `01a1ba8b-8138-7c13-9fe1-709b2a7d830c` 通过预检、完成写入且 `thread/read` 保留正确路径、新建类型和内容（`...codex-file-allow-history-final.log`）。测试专用工作区及文件已清理，持久 Session 保留并引用临时路径。

排查时受控多文件 `fileChange.changes` 复现旧转换只产生一个空路径、空内容的 patch（`...codex-file-history-before.log`）。桌面服务现在将每个变更映射为独立块，识别 `add`/`delete` 类型，并保留原始 item；受控完成事件、历史重读及相关 26 项回归通过（`...codex-file-history-replay-regression.log`）。真实实验仅覆盖一个新建文件，未验证多文件真实写入、覆盖或删除、远程审批、断网和并发审批。

真实拒绝回合的文件 item 状态为 `declined`；历史显示现保留并展示 Codex 文件变更的完成、拒绝、失败或进行中状态，缺失状态不推断为成功。专用 Session `01a1ba8e-4f97-7ff1-98ac-ff81043a9cf1` 经真实桌面拒绝后，后端历史、界面 `Declined` 和文件未创建均核对；受控 UI 对照 completed 及无状态数据，连同相关回归共 19 项通过（`internal/evidence/2026-11-08_codex-file-status-final.log`）。不同 Codex 版本的其他状态保留原字符串显示，尚未逐项真实验收。

## 2026-11-08 Codex 计划与回合边界

### 真实多步骤执行再次探测

本机新建 ephemeral、只读沙箱 Codex Session，提示使用 `update_plan` 创建并推进 Inspect/Report，同时只允许运行指定的 `printf` 命令；实际回合 completed，原始事件中有 `commandExecution`，但没有 `turn/plan/updated`，生产服务也没有 Todo 快照（`internal/evidence/2026-11-08_codex-plan-tool-probe.log`）。测试标记 skipped，日志仅记录 item 类型，没有核对实际命令文本或输出；不能视为 Todo 验证通过，也不能据此断言其他模型、模式或版本不支持。当前本机 CLI 为 0.166.0，已有 shared daemon 的确切构建版本未复核。此前真实 `plan` 文本 item 的显示与历史证据独立成立，不等于结构化 Todo。

后续 Codex 输入框已接入原生 Goal 命令，最新实现与验证见下节；命令发现仍待实现。

### Codex Goal 输入命令接入

参照 [OpenAI Goals 文档](https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex)及本机 0.166.0 生成的 App Server schema，桌面将 `/goal`、`/goal <目标>`、`/goal pause`、`/goal resume`、`/goal clear` 路由到精确 Session 的 Goal RPC，用户写操作带 `origin=user`；已有 Goal 会在创建前拒绝替换。该检查与写入非原子，其他客户端并发创建仍有竞态。后端错误和不匹配的响应可见并保留草稿，不启动模型回合；不相关斜杠文本仍走原路径。

mac-air 专用 Session `01a1bb52-85f7-7ce3-97ac-0223b4405e8c` 的真实远程生产桌面验证 `/goal` 查询、对已存在目标的拒绝及草稿保留、对已暂停目标再次执行 `/goal pause`、`/goal clear`、Goal 展示与后端读取一致，前后回合数不变（`internal/evidence/2026-11-08_codex-goal-command-remote-ui-verified.log`）。受控对端覆盖创建、暂停、恢复、清除、目标保护及远程 ID/用户来源（`...codex-goal-command-regression-final.log`）；真实主动创建/恢复的后续结果见下段，并发及断网未验收。中途发现后台 Mesh 错误遮住 Session 命令错误，现优先显示当前会话错误；两次失败与一次连接 `InvalidTransition` 均保留日志，异常后只清理测试 Session 的专用 Goal，并经真实远程复测。非当前会话的后台错误仍待进一步分域处理。

后续使用同一只读沙箱专用 Session，以禁止工具、文件和网络访问的目标，经远程真实 Session 服务依次验证创建、暂停、恢复、清除（`internal/evidence/2026-11-08_codex-goal-commands-remote-live.log`）；另经生产桌面、程序操作 WKWebView 的输入框完成同样四步并核对命令输出（`...codex-goal-ui-active-live.log`）。第三次独立 SSH 连接确认 Goal 为空、已有种子回复存在，历史共 6 个回合、无运行中回合、规范化历史中无工具调用、终端命令或文件变更块（`...codex-goal-ui-active-replay-final.log`）。测试没有对照每个回合的来源，不能将 6 个回合都归因于本次创建/恢复，也不证明底层没有被规范化器遗漏的其他事件。真实物理输入、断网、多客户端并发和 Objective 创建原子性仍未验收；测试 Session 保留。

本机 CLI 0.166.0 shared daemon 的两个新建 ephemeral Session，分别以默认模式和显式 plan 模式请求代理调用 `update_plan`，执行仅需心算的分阶段任务，不运行 shell、读取或写入文件或访问网络。两次回合均 completed，但目标 Session 均未出现 `turn/plan/updated`；日志分别为 `internal/evidence/2026-11-08_codex-plan-staged-live.log` 和 `...codex-plan-explicit-mode-live.log`，均明确 skipped。不能从这两次推断所有模型不支持，也不能说真实 Todo 流程已通过。

当前 [OpenAI App Server 文档](https://developers.openai.com/codex/app-server)将计划更新归于 turn，并将计划模式中的 `plan` 文本 item 与结构化计划更新区分；本机 0.166.0 生成的 `TurnPlanUpdatedNotification` schema 要求 `threadId`、`turnId` 和 `plan`，状态为 `pending`、`inProgress`、`completed`（`internal/evidence/2026-11-08_codex-plan-schema-summary.json`）。文档的事件摘要未列出 `threadId`，此处按已安装版本生成的 schema 与真实连接的边界处理。

受控通知先复现旧回合计划在新回合出现后覆盖当前计划：`...codex-plan-turn-scope-before.log`。桌面服务现按 Session 和 turn ID 限定更新，在新回合开始时清除上一回合 Todo，延迟到达的旧计划不能覆盖新回合；其他 Session 的计划不受影响。修复后模拟事件及相关 17 项回归通过（`...codex-plan-turn-scope-after.log`）。这是按当前协议进行的受控事件验证，不是代理真实产生 Todo 的端到端证据；真实计划创建、更新、持久化和远程行为继续待验收。

### Plan 文本 item 不再丢失

本机 0.166.0 使用显式 plan 模式，在只读测试 Session 请求为虚构应用提供计划；真实 App Server 发出 `item/completed` 的 `plan` item，但修复前规范化回合没有其文本，见 `internal/evidence/2026-11-08_codex-plan-item-before.log`。受控事件还复现 `item/plan/delta` 未展示（`...codex-plan-delta-before.log`）。

桌面服务现将计划增量作为实时助手文本，并将最终 `plan` item 的权威文本保留为助手块，原始类型仍在 vendor payload；不会将自由文本伪造为 Todo。真实 ephemeral Session 复测观察到计划并在完成回合中保留（`...codex-plan-item-after.log`）；随后真实持久测试 Session `01a1ba69-26ff-74c2-9cb0-285a7a5bd4ff` 的完成回合和 `thread/read` 历史均保留同一计划文本（`...codex-plan-item-persistent.log`），该 Session 保留。模拟事件确认最终内容可不同于增量。真实测试通过生产 Session 服务，显式 plan 模式由测试传输注入，不是桌面模式选择或物理鼠标验收；结构化 Todo 的真实创建、状态更新、清除与远程行为仍未验证。

随后新建持久测试 Session `01a1ba6b-fba3-7381-86f6-43d4ea58b35f`，经生产桌面服务与程序操作 WKWebView 输入规划请求；原始事件观察到最终 `plan` item 和 803 个计划增量，界面实际显示了实时文本及完成计划标记，`thread/read` 的规范化历史保留与最终 item 相同的文本（`internal/evidence/2026-11-08_codex-plan-desktop-real.log`）。测试固定注入该 Session 的清单，plan 模式由测试传输指定；不是物理操作、正常列表发现或桌面模式选择验收。计划文本不是结构化 Todo，模型何时生成哪类事件仍不保证。

另一次新持久 Session `01a1ba6d-7680-79d3-a095-ab2163b98902` 加强对照：真实后端发出 879 个计划增量，程序采样到的界面实时文本经去空白和标点后与最终计划内容匹配；最终标记可见，规范化历史与原始最终 item 一致。该测试及 16 项相关回归通过（`internal/evidence/2026-11-08_codex-plan-desktop-stream-final.log`），同样使用注入清单和 plan 模式；两个专用 Session 保留。

## 远程 Codex 结构化问答（2026-11-08）

真实 mac-air 共享 daemon 的只读 ephemeral Session，经 SSH 和生产 Session 服务发起结构化提问、提交答案，观察到同一请求确认、回合 completed 与助手回复标记（`internal/evidence/2026-11-08_codex-remote-hitl-service.log`）。测试为回合注入 plan 模式，不代表桌面模式选择已经接入。

另建远程持久测试 Session `01a1ba92-0173-7751-b0ba-e97ac21db57e`，以隔离主机配置经桌面正常发现、打开并读取种子回复；随后程序提交提问提示，在等待期限内界面未出现结构化问答，测试标记 skipped（`internal/evidence/2026-11-08_codex-remote-hitl-desktop.log`）。原因尚未确认，不能判定是模型未发起还是界面/数据链问题，也不能称为远程桌面 HITL 通过；需补充事件与回合状态诊断后继续验证。该专用 Session 保留。

后续诊断发现该 Session 已在远端运行，但桌面连接未收到其协议事件；服务此前仅对 `notLoaded` 的 Session 调用 `thread/resume`。已加载不等于当前连接已订阅：[OpenAI App Server 文档](https://developers.openai.com/codex/app-server)明确 `thread/read` 不订阅事件，而继续已有 Session 使用 `thread/resume`。现对从清单发现的 Session，在当前连接第一次发送前恢复；恢复失败直接报告，不发送。再次发现其已卸载时清除已恢复标记。该更改不在仅读历史时自动恢复，旁观 Session 的实时订阅和底层连接重连后的恢复仍需另验。

修复后第一次远程桌面尝试收到了 `turn/started` 与 `turn/completed`，但模型未发出问答，仍标记 skipped（`internal/evidence/2026-11-08_codex-remote-hitl-desktop-resume.log`）。第二次在 mac-air 新建专用持久 Session `01a1ba9c-ae7a-7611-8ce7-80f0fb6aa917`，经真实 SSH、生产桌面服务和程序操作 WKWebView，观察原始 `item/tool/requestUserInput`，界面显示问题和选项、提交后同一请求 confirmed，助手继续，界面显示回复且历史回放保留，同一回合 completed（`internal/evidence/2026-11-08_codex-remote-hitl-desktop-resume-retry.log`）。测试用隔离主机配置，plan 模式由测试传输注入，非物理鼠标或普通桌面模式选择验收；测试 Session 保留。先前两个仍运行的专用测试回合已分别中断并只读确认 interrupted，其余专用回合 completed。真实拒绝、多问题、并发、重连及其他远程权限流程仍待验证。

相关回归运行 53 项，其中 30 项通过、23 项按环境条件跳过、0 项失败；包含已加载 Session 先恢复后发送的受控测试（`internal/evidence/2026-11-08_codex-resume-regression.log`）。跳过的真实环境测试不计为通过。

## 远程 Codex 命令审批取消（2026-11-08）

mac-air 共享 App Server 的专用持久 Session `01a1bba6-6395-70f2-b93c-d7ecaf3e3ffe` 使用只读沙箱和 `on-request` 审批策略，先完成不使用工具的种子回合。生产桌面从真实远程清单打开它，程序操作 WKWebView 请求包含 `PHAROS_REMOTE_COMMAND_APPROVAL` 标记的 `printf` 审批；测试核对真实请求类型、命令包含该标记及存在 `cancel` 选项后，通过审批卡选择取消。收到同一审批 resolved、卡片消失、服务事件和历史中同一回合均为 cancelled（`internal/evidence/2026-11-08_codex-remote-command-approval-desktop.log`）。测试没有批准任何命令；校验是标记包含检查，不是整个命令字符串的精确匹配。

独立 SSH 连接重读该专用 Session，确认种子历史、一个 cancelled 回合及零运行中回合；同次桌面取消卡受控回归通过（`...codex-remote-command-approval-replay.log`）。远程 `/opt/homebrew/bin/codex --version` 为 0.162.1，但没有核对既有共享 daemon 的实际构建版本。此验证是程序操作而非物理鼠标，仅覆盖取消，不证明远程允许、文件审批、实际命令输出、多客户端并发或断网恢复；该 Session 保留。

## 连接代次与重连边界（2026-11-08）

Codex UDS 客户端现在为打开或丢弃的连接维护代次；清单中 Session 的恢复记录绑定代次，后续发送遇到连接变化会重新 `thread/resume`。通知批次在同一连接锁内记录来源代次，远程转发保留该信息；旧连接迟到的事件被丢弃。关闭连接时清除尚未分发的通知缓冲，避免把旧消息归到新连接。

审批记录也绑定代次；重新查询或尝试回答时撤回过期请求。UDS 写入审批响应与代次检查在同一锁内执行，不能把已知旧请求发到新连接。若回合运行时连接变化，服务不把新连接上收到的旧回合审批视为当前连接所拥有；再次发送前读取历史，只有明确看到原回合已结束才解除占用，正在运行或历史中找不到原回合均拒绝发送。受控测试覆盖旧请求、旧事件、回合未完成阻止发送及确认完成后再次恢复。过期审批当前在查询或操作时撤回，并非连接断开即主动通知界面。

真实本机 shared daemon 的专用 Session `01a1baa6-9892-78c1-8a62-ceea0d6b9a6c` 在两次已完成回合之间，只关闭测试客户端自己的 UDS 连接；连接代次变化，下一回合再次收到完成事件和回复标记。mac-air 真实 Session `01a1baa7-08dd-7462-aedc-0b1b27f67745` 随后经桌面 WebKit 完成结构化问答、确认、回复和历史重读，plan 模式由测试注入（`internal/evidence/2026-11-08_codex-connection-generation-real-final.log`）。这两项分别验证本机客户端连接替换和远程正常问答，并非远程 SSH 断网或问答进行中断线验收。

相关回归共 63 项，其中 39 通过、24 因环境条件跳过、0 失败（`internal/evidence/2026-11-08_codex-connection-generation-regression-final.log`）。恢复 RPC 与下一次发送之间尚非单个原子操作；该间隙断线、远程网络故障、运行中断线的事件补全与审批恢复、旁观会话订阅及 UI 主动失效提示仍待验证或实现。测试专用 Session 保留。

### 恢复与发送间的连接竞态

受控测试先复现：`thread/resume` 返回后连接发生变化，旧代码读取新代次并在未订阅的新连接上启动回合（`internal/evidence/2026-11-08_codex-resume-start-race-before.log`）。现由 UDS 客户端在同一连接锁内返回每次 RPC 实际使用的代次；恢复成功后记录该代次，`turn/start` 在锁内确认当前连接与它一致才发送，连接变化则报错，不自动重试可能已发送的请求。回合所有权同样绑定 `turn/start` 实际使用的连接。远程 SSH 转发和测试用 plan 模式装饰器保留这些代次。

本机真实 shared daemon 专用 Session `01a1baaa-ba2b-7792-945d-ef8e8e71bbb2` 中，测试在成功恢复后只关闭自己的客户端连接，再以旧代次请求启动回合；收到预期错误，前后历史回合数量一致。随后该 Session 的两次正常回合也完成，第二次前再次更换测试客户端连接。mac-air 专用 Session `01a1baab-34f2-7113-a7f2-93202d3c5c4c` 的桌面结构化问答、确认、回复和历史重读回归通过（`internal/evidence/2026-11-08_codex-resume-start-race-real.log`）；plan 模式由测试注入。另有受控测试覆盖启动响应后连接立即变化时不会把新连接的审批误认作原回合所拥有。

上述测试覆盖本机客户端断开与远程正常问答，不代表真实远程网络在该间隙断开已验收；发送后但响应丢失时的结果仍不确定，不应盲目重试。进行中回合/审批断线、旁观订阅和主动失效提示仍待完成。普通纯文本输入在发送失败时的草稿保留也需单独修复和验证。
