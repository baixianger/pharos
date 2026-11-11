---
summary: Remote DSH question, permission rejection and allow-once, Goal and Todo creation passed real desktop WebKit workflows; network recovery remains open.
---

# DSH Session 接入与验证

## 环境与链路

2026-11-07 本机 DSH 0.2.2-rc.1；mac-air DSH 0.2.1-rc.2。桌面从 ACP `session/list` 发现会话；远端经配置的 SSH 主机启动 loopback DSH Host 并转发连接，不依赖远端 Pharos 节点。token 只留在内存。远端旧版本的历史从 `session/follow` 的 snapshot 取 `throughSeq`，再分页 `session/page`；交互和 Session 逻辑流复用同一个 `/api/remote.mux` WebSocket。测试完成后检查远端临时 Host 已退出。

实现入口：[桌面路由](../Sources/Pharos/UI/Shell/DesktopPharosClientService.swift)、[Host](../Sources/PharosRuntime/Adapters/Dsh/DshWebHost.swift)、[会话与交互](../Sources/PharosRuntime/Adapters/Dsh/DshLiveSessionService.swift)、[远程多路流](../Sources/PharosRuntime/Adapters/Dsh/DshRemoteMux.swift)、[历史映射](../Sources/PharosRuntime/Adapters/Dsh/DshSessionHistoryReader.swift)。跨后端的任务清单见 [Session 总记录](2026-11-07_session-surfaces.md)。

## 实测结果

| 能力 | 可复核证据 | 边界 |
| --- | --- | --- |
| 列表、历史 | mac-air ACP 列出 155 个 Session；桌面服务读取一个有 3 个回合的真实 Session。 | 只覆盖 `hosts.json` 配置的 SSH 主机；真实网络故障恢复未验收。 |
| 发送与事件 | 新测试 Session 发送无工具提示并收到目标回复；另一次外部启动的真实回合观察到 start、文本增量和 completed。 | 断线重订阅、并发、多客户端抢答待验证。 |
| 结构化问答 | 真实远程测试经桌面 WKWebView 选项提交，同一回合 journal 记录最终回复及 completed。 | 实际鼠标、多选、自填、拒绝和过期请求待验收。`$events/result` 即使过期也可能返回成功，需以代理继续和 journal 为准。 |
| 权限审批 | 远程真实模型发出工具权限请求；桌面拒绝及单次允许后，journal、助手回复和 completed 均已核对。 | 物理鼠标、过期与并发尚未验收；不支持未提供的 always-allow。 |
| Goal | 真实桌面 Session 经 Goal 创建、完成和清除；自动后续回合已在服务、桌面和独立 journal 验证；两个远程 Session 的服务、桌面切换及 journal 隔离已验证。 | 不同主机、并行写入、真实断网和其他版本待验证。 |
| Todo | 真实工具依次发出 `[in_progress, pending]`、`[completed, in_progress]`、`[completed, completed]`；服务事件、journal 重放和新 Host 恢复一致。下一回合调用 `todo_write` 清空；事件、journal 和重新加载均为空。 | 真实桌面已核对创建、更新、完成和清空；小屏显示、会话切换、并发和断线恢复待验证。 |

上表对应 `DshSessionHistoryReaderTests.testRemoteTodoLifecycleWhenEnabled`、`testRemoteWorkflowJournalWhenEnabled`、`testRemoteGoalFollowupJournalWhenEnabled`、`testRemoteExternalTurnWhenEnabled` 和 `DesktopPharosClientServiceTests.testRemoteSessionRoutingWhenEnabled`；真实测试均需显式环境变量，部分会在远端真实 DSH 数据目录创建可见测试 Session，已保留供核对。普通离线测试跳过这些探针，不能视作实测。

## 已知细节与待办

- DSH 的 `turn/end` 原始 `completed` 映射完成，`interrupted` 映射取消；这两个值曾被误判为失败，已有回归测试。
- Goal 可以将 `source=goal` 的内部消息放入队列并启动后续回合，不是客户端重复发送。早期测试 Host 退出时后续回合被中断；后续已验证真实自动回合完成及桌面显示，详见下文。
- 用户 Session 正在进行中时，慢历史回填、断线和事件并发仍需验证。交互流断开后撤回待处理请求并自动重试；真实网络断开后的恢复及会话 journal 流重放仍未验证。
- 本机隔离 Host 的模型曾以 error 结束；远程实测成功不能替代本机模型配置的验收。VNC 与丰富上下文指标不属于上述 Session 闭环结果。

## 2026-11-07 交互流断开恢复

桌面 DSH 服务在交互流结束或初次连接失败时重试，间隔从 1 秒递增至最多 30 秒；失效请求先撤回，恢复后接收新的请求。远程复用 WebSocket 已关闭时，下次连接会重新创建它。`testQuestionRequestAndResponseThroughServiceWhenEnabled` 以真实隔离 DSH Host 加模拟交互流验证：请求待处理时断流、撤回、第一次重新连接模拟失败后继续退避重试，以及恢复后另一个权限请求的拒绝回写。`testRemoteHostHistoryWhenEnabled` 在 mac-air 验证修改后正常连接并读到 2 个回合。模拟交互流不等于真实网络断开：远程 WebSocket 重建、断线期间丢失的请求是否重发、会话 journal 订阅及状态补齐仍需实测；当前不能保证断线期间的交互一定恢复。

## 2026-11-07 Session journal 恢复

打开的 Session 的 follow 流结束后退避重连；收到新 snapshot 后重新读取 journal，以事件序号补发上次观察之后的 Goal、Todo 和回合事件，并丢弃重复序号。历史读取期间若收到较新的进度事件，不用旧快照覆盖进度。`testFollowReconnectReplaysMissedJournalWithoutDuplicates` 用模拟 Host 验证断线期间的 Goal/Todo 更新、重连和重复事件去重；实际 mac-air 读取历史、隔离 Host 交互回归通过。此测试没有中断真实网络；实时回合完整重建、历史读取失败后补读、并发分页和桌面 UI 恢复仍需验收。

## 2026-11-07 真实远程桌面问答与进度

`WorkspaceWebViewTests.testRemoteDshRealQuestionThroughDesktopWhenEnabled` 在 mac-air DSH 0.2.1-rc.2 新建测试 Session，释放创建它的 Host 后，由真实 `DesktopPharosClientService` 在生产 `PharosMainShellView` 中发现并加载；测试通过 WKWebView DOM 提交提示、选择真实问答选项并提交，再检查助手正文和另一个只读 Host 的 journal。最终 Session `session-4e4a3dd6-f5cc-4bc2-8efc-69cc718df515` 观察到问题、助手标记、同一回合 completed，journal 有 `goal/change`、`todo/write`，输入区显示目标以及 Inspect、Report 两项。此前另一次真实桌面问答与 completed 同样通过，但当时只确认进度非空；最终测试分别核对 Goal 和 Todo 文本。这是程序控制 WebKit，尚不是物理鼠标验收；Goal 完成和 Todo 全生命周期仍以服务层验证为准。测试 Session 保留，不删除远端数据。

测试发现选中行可先于对应 Session 视图模型加载，过早提交可能被忽略；现在输入区在加载完成前禁用并提示加载。WKWebView 回归覆盖禁用状态。第一次探针在未确认目标行已选中时提交：目标测试 Session journal 没有用户消息，无法确定是否提交到了之前选中的会话；该测试提示明确禁止命令、文件、日程及会话外更改。随后测试先确认目标行和输入就绪。另一次诊断因两个 Host 同时拥有同一会话返回 RPC 错误；释放创建 Host 后真实闭环通过，不能推断所有并发情况都已解决。初版测试还误把用户提示里的标记当作回复，现仅检查助手正文并核对 journal 完成。

2026-11-07：桌面权限卡根据规范化的可用选项显示拒绝与单次允许，不再展示 DSH 未实现的始终允许；此选项映射经模拟测试验证；后续真实权限拒绝结果见下文。

## 2026-11-07 真实远程桌面权限拒绝

mac-air DSH 0.2.1-rc.2 新建 Session `session-7872a9f8-0765-41e1-a265-e2346181656a`，释放创建 Host 后通过生产桌面服务和 WKWebView 选中并发送测试提示：调用仅输出标记的 `printf`，显式要求 `sandbox_permissions=danger-full-access` 并提供 justification，不运行其他命令或修改文件。真实模型发出权限 waterfall；测试以程序操作 WebKit 选择拒绝。随后另一只读 Host 的 journal 含 `approval/decided`、`outcome=rejected`；助手确认标记显示在界面，含该回复的同一回合状态为 completed。该测试未授予提升权限，也不是物理鼠标测试；测试 Session 保留。

`WorkspaceWebViewTests.testRemoteDshRealQuestionThroughDesktopWhenEnabled` 通过 `PHAROS_DSH_UI_PERMISSION_TEST=1` 选择此分支，未收到权限请求则明确跳过；测试核对 journal 决策和助手正文，避免仅凭结果 RPC 成功判定代理采纳。一次性允许及权限请求失效、并发与重连仍需实测。当前版本的 waterfall 请求可能只提供工具名和原因而不含命令参数，界面不得假定它已展示完整命令；精确关联工具调用及参数仍需增强。

对上述保留 Session 的只读 journal 复核：`tool/call` 含 `callId`、`name`、`arguments`，`approval/asked` 含 `callId`、`id`、`reason`、`toolName`，`approval/decided` 含 `id`、`outcome`。这些字段为后续关联审批与命令参数提供候选路径；只核对字段存在，尚未验证实时 waterfall、journal 到达顺序和 ID 实际相等。

## 2026-11-07 权限请求与工具参数关联

mac-air 的真实权限 waterfall 实测含 `request.callId`；同一 Session journal 中唯一的 `tool/call` 和 `approval/asked` 与此 callId 一致，工具名一致，参数是需解析的 JSON 字符串。waterfall 的 `eventId` 与 journal `approval/asked.id` 在两次观测中不同，因此不能混用。`testRealRemotePermissionCorrelationWhenEnabled` 在请求待处理时读取 journal，核对 callId、工具名和测试命令标记，再拒绝并观察 rejected；真实测试 Session 保留。

桌面收到权限时先显示已有原因，并异步按同一 Session、callId 和工具名查找唯一 journal 调用，将匹配参数加入同一请求；既支持 JSON 字符串也支持对象。待处理请求消失、连接更换、正在提交、匹配不唯一或解析失败时不补入参数。若 journal 事件晚到，会重新尝试；若历史读取失败且没有后续事件，详情可能仍不可用。`approvalUpdated` 只更新现有卡片，不能让已撤销卡片复活。WKWebView 同时显示原因和参数。

真实远程桌面 Session `session-f61ade36-fb72-401b-a401-ec51e0dc20da` 验证命令标记在卡片显示，拒绝后 journal 为 rejected，助手确认并 completed。模拟测试另覆盖请求先于工具事件、不同工具同 ID、同 Session 重复匹配、取消后迟到，以及事件编码；断线、多个主机和真实并行工具调用仍待验收。测试为程序操作 WebKit，未授予提升权限。


## 2026-11-07 真实远程桌面单次允许

mac-air DSH 0.2.1-rc.2 的隔离 Session `session-88ad31dc-b31e-4152-878e-c6e86b8a56ff` 经生产桌面服务及 WKWebView 发出真实 bash 权限请求。测试先确认目标 Session 已选中，且完整工具名和命令精确匹配仅输出标记的 `printf PHAROS_DSH_PERMISSION_TEST`，权限卡显示该命令，才程序提交单次允许；不匹配则拒绝。远端 journal 记录 `approval/decided: allowed-once` 和成功工具结果，工具输出包含标记；助手的最终标记在桌面显示，同一回合 journal 状态为 completed。测试允许了该明确匹配命令请求的提升权限，没有允许其他命令。测试结束后远端临时 Host 的进程计数为 0；远端 Session 保留。日志为 `internal/evidence/2026-11-07_dsh-ui-allow.log`。

复现：设置 `PHAROS_REMOTE_DSH_UI_TEST=mac-air`、`PHAROS_DSH_UI_PERMISSION_TEST=1`、`PHAROS_DSH_UI_ALLOW_ONCE=1` 并运行 `WorkspaceWebViewTests/testRemoteDshRealQuestionThroughDesktopWhenEnabled`，需同时隔离项目 registry 和 Mesh 路径。测试通过 WebKit DOM 而非物理鼠标；它没有验证并发审批、请求过期、断线恢复或不同命令。


## 2026-11-07 真实远程桌面 Todo 全生命周期

mac-air DSH 0.2.1-rc.2 的持久测试 Session `session-e0f53de1-5e1c-4d57-934b-e208484dbd73` 经生产桌面服务和 WKWebView 在四个独立真实回合分别调用 `todo_write`：`[in_progress, pending]`、`[completed, in_progress]`、`[completed, completed]`、清空。每一步展开 Todo，检查可见条目的名称及状态标签、助手标记和空闲输入；同一桌面 Host 的历史确认四个回合 completed，最终进度为空。桌面 Host 退出后另启只读 Host，独立重放 journal 并确认四个状态和四个完成回合。证据在 `internal/evidence/2026-11-07_dsh-ui-todo-final2.log`、`internal/evidence/2026-11-07_dsh-ui-todo-final2-replay.log`。这是程序操作 WebKit，未验证物理鼠标、窄屏、会话切换或真实网络故障。远端测试 Session 保留。

另一次 Session `session-68f267ef-26ae-4db2-aca4-5a3ebb80cf9b` 四个展开状态均可见，但测试在桌面 Host 仍占用会话时启动第二个 Host，读取报 `InvalidTransition ... failed(deinit)`；桌面测试进程退出后独立 journal 重放通过。其后两次只读重试曾报 SSH 隧道不可用，清理能够确认属于测试的孤儿隧道后重试通过；这不能证明隧道残留就是失败根因。新测试复用桌面 Host 读取最终历史，再单独重放保留 Session。此前还发现若干归属不明的 SSH 隧道未清理，后续需明确应用和测试的子进程生命周期，避免错误中断其他工作。

复现桌面测试需隔离 registry/Mesh 并设置 `PHAROS_REMOTE_DSH_UI_TODO_TEST=mac-air`，运行 `WorkspaceWebViewTests/testRemoteDshTodoLifecycleThroughDesktopWhenEnabled`；完成后设置 `PHAROS_DSH_UI_TODO_SESSION` 为输出的 Session ID，运行 `DshSessionHistoryReaderTests/testRemoteDesktopTodoJournalWhenEnabled`。模型未按提示产生状态时测试会报告 skipped，不可把 skipped 当通过。


## 2026-11-07 远程子进程生命周期复核

在 mac-air 以保留的 Todo Session 做只读测试：独立 `DshLiveSessionService` 加载真实历史和事件流后释放最后的引用，weak 引用清空，期间启动的两个直接子进程（Host 和 SSH 隧道）均退出。另一个测试在生产桌面 `PharosMainShellView` 打开相同 Session，关闭并释放测试窗口后，桌面服务 weak 引用清空，期间新增的三个直接子进程均退出。测试按本进程前后子 PID 差异检查，退出前还会清理该测试拥有的残留；不触碰既有进程。结果分别见 `internal/evidence/2026-11-07_dsh-process-lifecycle.log` 和 `internal/evidence/2026-11-07_desktop-process-lifecycle-fixed-probe.log`。这证明正常释放路径在本机这次测试成立，不能证明应用被强制退出、崩溃或所有多窗口情形都能清理，也不能解释先前 SSH 隧道错误。

桌面生命周期探针最初在测试进程收到 signal 11；加 `NSZombieEnabled` 后证据显示 `NSWindow` 在 `close()` 释放后又被 ARC 释放。测试窗口设置 `isReleasedWhenClosed = false` 后恢复正常；这属于测试窗口所有权错误，不作为产品崩溃根因。证据位于 `internal/evidence/2026-11-07_desktop-process-lifecycle-zombie.log`。之前强制清理过能够确认属于本轮测试的孤儿隧道；其余归属不明的进程没有操作。

复现分别运行 `DshSessionHistoryReaderTests/testRemoteServiceReleasesOwnedProcessesWhenDropped`（设置 `PHAROS_REMOTE_DSH_LIFECYCLE_TEST` 和 `PHAROS_DSH_LIFECYCLE_SESSION`）与 `WorkspaceWebViewTests/testRemoteDesktopReleasesOwnedProcessesWhenViewCloses`（设置 Session ID 并隔离 registry/Mesh）。桌面测试目前使用上述 Todo Session 的最终标记确认选中，须提供包含该标记的保留测试 Session。


## 2026-11-07 真实远程桌面 Goal 与清除探针

mac-air DSH 0.2.1-rc.2 的隔离 Session `session-82435bee-cce5-469f-adaf-95d4d4d46503` 经生产桌面 WKWebView 让真实模型调用 `create_goal`、提出结构化问题；测试在界面展开并确认 Goal `active` 后选择 Continue。模型调用 `update_goal`，桌面显示 `complete`，服务收到 `active`、`complete` 更新，助手标记及同一回合 completed 均通过 Host 历史核对。先前独立 Session `session-7c716163-a8d8-4aa9-b895-8c3d2889598e` 也验证了该流程。

后续在同一测试 Session 请求模型调用真实工具清除已完成 Goal；该回合正常回复并 completed，但桌面与服务仍显示 complete。桌面 Host 退出后独立读取 journal：Goal 事件只有 active、complete，没有 clear；工具依次为 `create_goal`、`ask_user_question`、`update_goal`、`get_goal`。因此清除**未观察到**，不代表所有 DSH 版本均不支持清除。测试将清除作为观测分支，不将 active→complete 测试通过误记为清除通过。日志位于 `internal/evidence/2026-11-07_dsh-ui-goal-clear.log` 和 `internal/evidence/2026-11-07_dsh-ui-goal-replay.log`，远端 Session 保留。

复现时隔离 registry/Mesh 并设置 `PHAROS_REMOTE_DSH_UI_GOAL_TEST=mac-air`，运行 `WorkspaceWebViewTests/testRemoteDshGoalLifecycleThroughDesktopWhenEnabled`；在桌面测试退出后，将输出的 Session ID 设为 `PHAROS_DSH_UI_GOAL_SESSION`，运行 `DshSessionHistoryReaderTests/testRemoteDesktopGoalJournalWhenEnabled`。问答和状态检查为程序操作 WebKit，不是物理鼠标；真实断线恢复、并发和 Goal 自动后续回合仍待验证。


## 项目插件的真实 inbox 记录

本机 DSH CLI `0.2.2-rc.1` 的真实 Host 经临时 overlay 加载项目插件，Runtime 确认领取；journal 以 `agent/inbox/spliced` 在 `turn/start` 前保存指定消息。历史读取已根据来源精确映射；该回合以 error 结束，模型输出和 Thread 回复未证明。依赖版本、测试 Session 和失败记录见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。


DSH v4 真实对照已精确复现通用 plugin 来源被持久化格式拒绝；改用 `pharos-mesh` 后，禁用具体工具的真实 Host 测试观察助手标记和 completed。一次此前不受控测试使用旧工具向默认 `pharos` 房间发送了测试消息，记录未删除；安全措施和完整边界见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。


真实本机 DSH `0.2.2-rc.1` 在具体工具禁用的测试环境中完成来自隔离 Broker 的定向回合；插件宿主按消息和 turn 关联并写回唯一回复，Runtime completed，未发生模型工具调用。详见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。


## 2026-11-08 真实远程 Goal 原生命令清除

在 mac-air 的 DSH 0.2.1-rc.2 上，对此前创建且确认已完成的两个专用测试 Session `session-82435bee-cce5-469f-adaf-95d4d4d46503` 和 `session-7c716163-a8d8-4aa9-b895-8c3d2889598e`，分别通过 Web Host 的 `commands/execute` 执行 `/goal clear`。首个测试确认 journal 新增一次 `goal/change` clear、当前 Goal 消失且没有新模型回合；第二个在执行前订阅真实桌面服务事件，观察到对应 Session 的 Goal 更新为 nil，服务进度及 Host 历史均无 Goal。Host 关闭后另启只读重放，确认两个 journal 各有一次 clear 且无当前 Goal。日志分别为 `internal/evidence/2026-11-08_dsh-native-goal-clear.log`、`...dsh-native-goal-clear-event.log`、`...dsh-native-goal-clear-replay.log`。

这补充了此前让模型自行清除未成功的探针；当时它只验证原生命令和服务事件。后续桌面输入与清除闭环见下一节。写入测试只适用于清除前状态，两个测试 Session 已清除；只读重放可再次运行。真实网络故障、Goal 自动后续回合仍待验证。只读 `/goal` 的真实响应含 `commandId` 和嵌套 `result.kind=success`，见 `internal/evidence/2026-11-08_dsh-native-command-response.log`。


## 2026-11-08 桌面原生命令与 Goal 清除

桌面 DSH Session 输入将以 `/` 开头的普通发送交给该 Session 所在的本地或远程 Host 的 `commands/execute`；原生命令返回的文本显示在 Session 内，RPC 业务结果不是 success 时显示错误。其他 Agent 沿用原有发送路径，steer 沿用既有语义。命令不伪造模型回合；展示内容保留换行。当前仅显示最近一次命令结果；失败草稿保留见下节，附件与命令发现未接入。不可将 `/goal` 的当前版本行为推广到所有 DSH 版本。

mac-air DSH 0.2.1-rc.2 真实桌面服务及程序驱动 WKWebView，使用此前专用 Session `session-82435bee-cce5-469f-adaf-95d4d4d46503`，提交只读 `/goal` 后显示结果，再提交不存在的命令显示错误；两次前后模型回合数不变，见 `internal/evidence/2026-11-08_dsh-native-command-desktop-fixed.log`。随后另一此前专用 Session `session-4e4a3dd6-f5cc-4bc2-8efc-69cc718df515`，预检 completed Goal、完成回合及测试标记，桌面执行 `/goal clear`，Goal 卡片消失、命令结果可见、服务进度为空且模型回合数不变，见 `...dsh-goal-ui-fixture-preflight.log`、`...dsh-native-goal-clear-desktop.log`。桌面服务退出后以独立 Host 重放三个专用 Session journal，各有一次 clear 且当前 Goal 不存在，见 `...dsh-native-goal-clear-desktop-replay.log`。这些 Session 保留；清除测试有严格前置条件，成功后不可对同一状态重复执行。

此前 `testRemoteDshGoalLifecycleThroughDesktopWhenEnabled` 的模型提示清除分支已改为桌面 `/goal clear` 断言；这一新建 Session 的完整单次流程尚未重跑。本次创建/完成与清除分属不同专用测试 Session，不能称同一 Session 已完成创建到清除的完整闭环。真实断网、物理鼠标及自动后续回合仍待验证。

### 同一 Session 的完整流程（2026-11-08 补充）

在 mac-air DSH 0.2.1-rc.2 的专用 Session `session-ddbfc060-7a3d-42cf-bab9-59e3148ca389`，通过程序操作生产 WKWebView，实际看到 Goal active、选择结构化问答、看到 Goal complete 和最终回复，随后在输入框提交原生 `/goal clear`，界面卡片消失、服务进度为空且模型回合数未增加（`internal/evidence/2026-11-08_dsh-goal-single-session-retry.log`）。桌面退出后由独立 Host 重放同一 journal，观察到 `create`、`complete`、`clear` 顺序及完成回合，当前 Goal 为空（`...dsh-goal-single-session-replay.log`）。这更新上段当时尚未重跑的结论；测试 Session 保留。

首次运行在创建空 Session 后、发出提示之前因 XCTest 非应用 bundle 调用系统通知中心而崩溃（`...dsh-goal-single-session-lifecycle.log`）；随后禁用通知并复用该专用空 Session 成功。测试代码现在在运行期间禁用通知并恢复环境变量。程序操作 DOM 不等于物理鼠标；真实断网、自动后续回合及并发仍未覆盖。

## 2026-11-08 真实远程 Goal 自动后续回合

mac-air DSH 0.2.1-rc.2 的专用 Session `session-c6d5e41d-5287-4e23-8333-9139b561d246` 使用真实生产 `DshLiveSessionService` 创建 Goal，提示明确限制只使用 Goal 工具、不运行命令、不访问文件或网络、不调度任务。journal 观察到 `source.kind=goal` 和随后的两个 completed 回合，服务发布两次完成事件和一次开始事件；Goal 达到 complete 后，测试通过该服务发送 `/goal clear`（`internal/evidence/2026-11-08_dsh-auto-goal-followup.log`）。首次证据只记录了事件数量，没有保存开始事件与后续回合 ID 的对应关系。

测试 Host 退出后另启独立只读 Host，重放同一保留 Session，确认 Goal 来源、两个 completed 回合、clear 事件以及最终 Goal 为空（`...dsh-auto-goal-followup-replay.log`）。这是服务和 journal 验证，不是桌面 UI 或真实断网验收；一次测试不能保证 Agent 每次都产生自动后续回合，提示诱导失败应记录为未取得，不强判为不支持。此前自动后续回合尚未完整运行的记录由此更新。

随后使用另一专用 Session `session-bcdc7097-5378-483f-9fe7-aef9497d01f5` 重测，并将 journal 中 Goal 来源回合的 ID 与服务的 `turnStarted`、`turnCompleted` 分别匹配：均指向同一自动后续回合；两个 journal 回合 completed，服务也发布两次完成，Goal 最终 complete 并由测试清除（`internal/evidence/2026-11-08_dsh-auto-goal-followup-exact-events.log`）。独立 Host 重放该 Session 再次确认 Goal 来源、两回合完成、clear 和 Goal 为空；同次断流重放的模拟回归通过（`...dsh-auto-goal-followup-exact-replay.log`）。模拟断流不是实际网络故障，桌面 Goal 自动后续回合的实时展示仍未验收。两个专用 Session 均保留；复现使用 `PHAROS_REMOTE_DSH_AUTO_GOAL_TEST` 创建新会话，重放需显式提供 `PHAROS_REMOTE_DSH_AUTO_GOAL_REPLAY` 和 `PHAROS_REMOTE_DSH_AUTO_GOAL_SESSION`。探针限制 75 秒并尝试清除专用 Goal；失败日志若提示清除失败，应先检查该明确 ID 的会话。

桌面后续验证：mac-air 专用 Session `session-76b72780-7326-48e3-8b10-4c9c5f846cb5` 从真实远程清单打开后，程序操作生产 WKWebView 发送 Goal 提示，界面先观察到 active，后观察到 complete 和自动回合回复标记；服务的开始与完成事件匹配该回复所在回合 ID，两个回合 completed（`internal/evidence/2026-11-08_dsh-auto-goal-desktop-live.log`）。测试随后直接调用生产桌面服务执行 `/goal clear` 并等待服务状态为空；这一步不是通过输入框操作。桌面退出后独立 Host 重放精确确认 Goal 来源的 completed 回合包含同一标记、clear 已记录且 Goal 为空（`...dsh-auto-goal-desktop-replay.log`）；该次还包含模拟断流重放等 3 项通过。此测试使用程序驱动 WebKit、隔离注册表和指定 SSH 主机，不代表物理鼠标、真实断网或其他版本；专用 Session 保留。复现设置 `PHAROS_REMOTE_DSH_AUTO_GOAL_UI_TEST` 和隔离的 registry/preferences/hosts/Mesh，重放另设 `PHAROS_REMOTE_DSH_AUTO_GOAL_REPLAY`、`PHAROS_REMOTE_DSH_AUTO_GOAL_SESSION` 和 `PHAROS_REMOTE_DSH_AUTO_GOAL_MARKER`。

## 2026-11-08 真实远程 Goal 跨 Session 隔离

mac-air 的两个新建专用 Session `session-497658fe-ed49-4f88-896f-4b1901acc2d1` 和 `session-d83f56fd-bc27-411d-a02c-6551f6799579` 同时由一个生产 `DshLiveSessionService` 观察。先让第一个创建并完成目标 A，核对第二个服务快照和 journal 均无 Goal；再让第二个创建并完成目标 B，核对第一个目标未变化、事件中的 Session ID 与目标内容未串用。清除第一个 Goal 后第二个仍保持原目标，随后清除第二个（`internal/evidence/2026-11-08_dsh-goal-session-isolation.log`）。提示限制不运行命令、不访问文件或网络、不调度任务；每个目标使用真实 Agent 和 Goal 工具，不是模拟计划。

测试 Host 退出后，独立 Host 分别重读两个保留 Session：各自存在自己的 complete Goal，不含对方 Goal，均有 clear 且最终 Goal 为空；模拟断流重放回归也通过（`...dsh-goal-session-isolation-replay.log`）。这验证同一服务实例、同一远程主机的两会话状态和事件，不证明桌面会话切换、多主机、并行 Goal 写入或真实断网。复现新测试使用 `PHAROS_REMOTE_DSH_GOAL_ISOLATION`；只读重放使用 `PHAROS_REMOTE_DSH_GOAL_ISOLATION_REPLAY`、`PHAROS_REMOTE_DSH_GOAL_ISOLATION_FIRST`、`PHAROS_REMOTE_DSH_GOAL_ISOLATION_SECOND`，只提供明确属于测试的 Session。

随后在 mac-air 新建另外两个专用 Session `session-2f6041f5-744d-4491-8d27-a50a19ae5d6c` 和 `session-070b1ec5-ecec-408e-b5eb-20131f11cc80`，程序驱动生产 WebKit：第一个创建并显示完成的 Goal A，切换到第二个确认初始无 Goal，再创建并显示 Goal B；切回第一个确认 Goal A，输入 `/goal clear` 清除后切回第二个，Goal B 仍在，随后通过输入框清除 Goal B（`internal/evidence/2026-11-08_dsh-goal-desktop-switch.log`）。独立 Host 重读两份 journal，确认各自目标完成、无对方目标及最终均清除；同次输入草稿切换回归也通过（`...dsh-goal-desktop-switch-replay.log`）。这是程序操作桌面、同一主机上的一组顺序操作；不证明物理鼠标、跨主机、并行目标更新或真实断网。测试 Session 保留，专用 registry 和配置已清理。复现设置 `PHAROS_REMOTE_DSH_GOAL_SWITCH_UI` 并隔离 registry/preferences/hosts/Mesh；重放仍使用前述明确 Session 的参数。


## 2026-11-08 命令草稿与异步反馈

Session 的普通斜杠输入在结果到达之前留在输入框，提交成功才清除仍与提交时一致的原文；失败保留草稿。每个 Session 按请求 ID 关联反馈，等待期间改写的文本不会被迟到的成功结果清除；切换到另一 Session 后的草稿不会被前一 Session 的结果覆盖，同一 Session 的重复斜杠提交在结果返回前不再次投递。非斜杠输入沿用原处理；非 DSH 的斜杠输入仍走该 Agent 原有发送路径。

mac-air 的真实 DSH 只读 `/goal` 显示结果并清空草稿，不存在的命令显示错误并保留草稿，前后模型回合数不变（`internal/evidence/2026-11-08_dsh-command-draft-desktop.log`）。程序驱动 WKWebView 的受控反馈测试覆盖失败保留、等待时编辑、切换 Session 后结果到达以及成功清空原会话草稿；连同 14 项 Session 流式回归共 15 项通过（`...dsh-command-draft-regression.log`）。受控测试不是远程断网或物理操作验收；命令附件、自动补全、发现、重启后草稿和跨窗口仍未验证。


2026-11-08 真实远程 DSH 目录和 Session next selection 已接入桌面输入区的只读快照；真实 Host 和程序操作 WebKit 验证了 provider/model 展示，模型切换尚未接入，因为上游选择可能同时更新默认模型。探针两次发现额外 journal 记录，后一次为 `session/end-seed`，因果未明；未观察模型选择或新回合。版本、对照日志与限制见 [DSH Session 协议](agents/dsh/sessions/2026-11-07_protocol.md)。


2026-11-08 DSH 输入区随后接通精确 provider/model 切换，显示可能更新新 Session 默认值的提示。独立 DSH_HOME 和 mock provider 下，生产 WKWebView 切换写入 Session 模型记录和隔离 profile 的默认值；固定默认的 patch 对照未观察默认值变化。真实推理和远程切换尚未验收，证据见 [DSH Session 协议](agents/dsh/sessions/2026-11-07_protocol.md)。


2026-11-08 DSH 权限预设已按真实 Host 目录和 Session 投影接入桌面输入区，独立本机真实 Host 已验证只读、完全权限确认/取消和恢复，默认权限不变；mac-air 只读目录通过，未更改远程权限。详细证据、测试 WebKit 求值问题及未验证项见 [Session 协议](agents/dsh/sessions/2026-11-07_protocol.md)。


2026-11-08 隔离 DSH Host/Session 服务已通过文件暂存回执提交文本文件与 PNG（均为普通 file 内容），核对存储字节、Session journal 和附件元数据回放；跨 Session/Host 使用在客户端被拒绝。停止并重新启动独立 Host 后读回文件 ID 和名称；重启后的文件下载尚未验证。mock 模型未运行，UI 选择及远程仍未完成；证据见 [Session 协议](agents/dsh/sessions/2026-11-07_protocol.md)。

2026-11-08 随后在 mac-air 真实 DSH 专用 Session 验证跨 SSH 上传小文本文件、模型复述文件内随机标记及完成回合；新 Host 可重放附件记录和完成回复。图片视觉、桌面入口、下载与异常恢复尚未验收；版本和证据见 [Session 协议](agents/dsh/sessions/2026-11-07_protocol.md)。
