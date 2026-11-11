---
summary: 接手 Pharos 间远程接入迁移；三家 Host Session 适配和部分 Peer 路由已通过受控测试；Thread、Projects、真实远端和逐家验收仍待完成。
---

# 远程接入改造交接与验收

## 目标和范围

每台机器由自己的 Pharos 管理本机 Agent 和项目；访问远程资源时，本机 Pharos 与资源所属机器的 Pharos 通信，后者调用本机 CLI 或明确支持的协议并返回 Pharos 数据。先打通两端通信，再迁移 Codex、DSH、Antigravity 的 Session、Thread 和 Projects，最后用真实远程机器逐项验证。

用户确认保留现有 SSH 直连研究和实现作为备用：实际使用的路径必须可识别，不能在一次请求可能已被远端接受时自动用另一条路径重发。只支持 CLI 或协议明确支持的 Session，不研究或接入第三方桌面客户端的私有 GUI 状态。

当前名称仍为 Pharos；Amigents / Afriends 仅讨论过，用户没有授权改名。VNC 是 Session 所属机器档案的未来预留功能，不属于这次远程协议验收。

## 工作区和交接边界

- 本机目录：`/Users/baixianger/personal/pharos`；分支 `integrate/mesh2-into-main`，当前 HEAD `1e25b4c`。工作区有大量已修改和未跟踪文件，其中 `.agy-tasks/PLAN.md` 已暂存；这些包含此前持续工作的成果，不要清理、覆盖或假定都属于本次握手。
- 本交接及许多 Session / Agent 文档目前也是未跟踪文件；仅切换分支、推送现有 HEAD 或交付 commit **不会**携带这些内容。交接人应先检查 `git status --short` 和具体 diff，与用户商定交付方式；未经许可不推送、rsync、删除或改写历史。
- Codex Peer 路由当前依赖 `~/.config/pharos/hosts.json` 的 `peerDeviceIDs`，把已有主机标签显式映射到配对设备 UUID，例如 `"peerDeviceIDs": {"mac-air": "<paired-device-uuid>"}`；可同时配置 `ssh` 作为备用。设备 UUID 必须从当前可信设备信息确认，不按显示名猜测。尚无图形配置入口，配置或身份重复时不应将 SSH 路径称为 Peer。
- 本文是任务入口和验收清单；历史细节、各项早期验证和长期队列仍保留在 [现有交接](handoff.md)，避免破坏其他文档对其条目的引用。架构边界、逐条源码审计见 [RFC-006](RFC-006-UNIFIED-CLIENT-AND-BACKEND-INTEGRATION.md#remote-pharos-boundary-and-current-deviations)。
- 逐家协议和测试边界见 [Agent 文档索引](agents/README.md)，每家均有 `sessions/` 和 `threads/`；输入框能力单见 [Session 输入能力清单](2026-11-08_session-composer-capabilities.md)。每次新验证应更新对应 Agent 文档，原始输出与截图放 `internal/evidence/`，不得记录凭据。

## 当前事实

| 项目 | 状态和证据边界 |
|---|---|
| Pharos 间握手 | **本机受控验证通过**。分布式 Mesh 新增 `host.runtime.hello.v1`，仅已配对 controller 可查询；Host 查询本机 Runtime 私有 socket，回复有限长度的能力并校验目标主机 ID。见 `Sources/PharosMeshProtocol/ReplicaRPCSchema.swift`、`Sources/PharosMeshReplica/MeshReplicaRPC.swift`、`Sources/PharosRuntime/MeshHostRuntimeBridge.swift`。 |
| 通用 Host Session RPC | **受控 Iroh 验证通过**。定义通用协议操作 `host.session.query.v1`、`host.session.action.v1`、`host.session.events.v2`；Host 侧通过 `MeshHostSessionServer` actor 维护私有适配器所有权、幂等去重缓存及基于游标的有界事件环形缓冲区（仅缓冲区尚保留且进程未重启时可续传；缺口和重启会报告，不能称无损）；客户端侧实现 `MeshRemoteHostSessionClient`（遵循 `PharosClientService`）透明处理远端 Session ID 前缀映射与游标轮询。见 `Sources/PharosMeshProtocol/HostSessionSchema.swift`、`Sources/PharosRuntime/MeshHostSessionBridge.swift`、`Sources/PharosRuntime/MeshRemoteHostSessionClient.swift`。 |
| Codex 垂直切片 | **受控 Iroh 验证通过**。串联 `CodexTransportFixture` → `LivePharosClientService` → `MeshHostSessionServer` → `MeshReplicaRPCServer` → loopback Iroh QUIC → `MeshReplicaRPCClient` → `MeshRemoteHostSessionClient`，端到端闭环验证会话列表发现、历史查询、消息发送、流式审批请求接收及 HITL 单次允许决议回写。见 `Tests/PharosTests/MeshHostSessionRPCTests.swift`。 |
| 接线和诊断 | `pharos-mesh` 的分布式 `sync-serve --host` 和应用内分布式服务接入了握手 provider；`pharos-mesh distributed host-runtime-hello --peer DEVICE-UUID` 可供已配对设备诊断。需要远端 Host 的 Runtime 可用。 |
| 生产路由 | **未迁移**。Host 启动代码已接三家本机 Session 适配器；后台服务新增本地 Session RPC 转发和明确设备 UUID 映射，受控 Unix socket 测试通过。默认仍是旧 Broker/Node；桌面已对显式映射的 Host 逐家优先 Peer、标记链路，并在此前未建立 Peer 时允许 SSH 备用；真实 SSH 备用和后台至远端的完整转发尚未验收；单家发现不可用且无既存 Peer Session 时才允许该家使用 SSH。 |
| 远端实测 | **新路径未验证**：尚未向真实远端部署新版本或进行跨机器新握手。mac-air 上可见旧构建和测试进程，但不能假定支持新协议或擅自重启、覆盖。已有真实 SSH 测试只证明旧路径。 |
| SSH 备用 | **设计要求，尚未完成**：现有 SSH 是当前实现，尚未实现按 peer 优先、明确展示备用路径、安全切换和未知结果对账。 |
| Session / Thread / Projects | **新路径进行中**。Codex 会话垂直切片及 DSH / Antigravity 的基本交互通过受控 Iroh 测试；真实 Peer 链路、三家完整交互和 Thread / Projects 迁移仍待完成。 |

主要旧路径：`DesktopPharosClientService.swift` 管理远程 Session；DSH 经 SSH 使用 ACP 与 DSH Web；Antigravity 经 SSH 使用 ACP；`RemoteCodexTransport.swift` 转发远程 App Server socket；`RemoteProjectPaths.swift` 经 SSH 读取远端偏好。旧 Broker 的部分 Thread 经远端 Pharos Node 调用其本地 Runtime，但 Session 发现、身份与三家绑定仍有缺口。详见 RFC 审计表，保留这些实现供备用。

## 已运行的验证和复现

针对性测试已全部通过以下集，覆盖握手、可信配对、Loopback Iroh 真实传输、通用 Host Session RPC 及 Codex 垂直切片（证据保存在 `internal/evidence/2026-11-08_host-session-rpc-verified.log`）：

```bash
swift test --filter 'AgentAdapterTests/testMeshHelloCrossesIrohToHostRuntime|DistributedMeshStoreTests/testAuthenticatedReplicaRPCRoutesSyncBlobsCommandsAndRevocation|IrohMeshTransportTests/testAuthenticatedReplicaRPCUsesConnectionEndpointIdentity|MeshHostSessionRPCTests'
```

- `testCodexVerticalSliceOverIroh`：`CodexTransportFixture` → `LivePharosClientService` → `MeshHostSessionServer` → `MeshReplicaRPCServer` → Loopback Iroh QUIC → `MeshReplicaRPCClient` → `MeshRemoteHostSessionClient`，验证会话列表发现、历史重读、发送消息、流式接收审批请求以及 HITL 决议回写。
- `testHostSessionActionSendMessageAndApprovalOverIroh`：真实 Iroh RPC 消息发送与审批决议；验证 `idempotencyKey` 幂等缓存，重放相同请求不重复触发底层动作。
- `testHostSessionEventsResumptionOverIroh`：验证单调自增游标在环形缓冲区中的记录，以及通过 `afterCursor` 验证缓冲区仍保留数据时按游标续传；不证明溢出或重启后无损。
- `testHostSessionQueryListHistoryAndProgressOverIroh`：验证 `listSessions`、`sessionHistory`、`sessionProgress` 在 Iroh 上的查询编解码与分发。
- `testHostSessionQueryRejectionForUnpairedOrNonController`：验证未配对或非 controller 角色的节点被拒绝 (`peer-not-trusted`)。
- `testMeshRemoteHostSessionClientEndToEndOverIroh`：验证客户端对 `PharosClientService` 的完整实现及 Session ID 跨机前缀透明映射。
- `testMeshHelloCrossesIrohToHostRuntime`：两个本机 Iroh 端点、可信配对、服务端 RPC、本机私有 Runtime socket 和实际 Runtime 握手串联。
- `testAuthenticatedReplicaRPCRoutesSyncBlobsCommandsAndRevocation`：包含握手正常路径、错误主机 ID、未配对和非 controller 拒绝，以及既有权限 / epoch 测试。
- `testAuthenticatedReplicaRPCUsesConnectionEndpointIdentity`：使用实际 loopback Iroh 连接核对设备身份并请求握手。

另有 `AgentAdapterTests/testMeshHostHelloReadsItsLocalRuntimeSocket` 单独验证本机 Runtime socket。最近测试构建成功；没有声称全量测试通过。测试依赖环境变量覆盖私有 socket，运行时勿并发启动会修改相同进程环境的测试。接手人应检查实际测试输出中对应测试数和结果，而非只看命令退出码；改动后重跑受影响测试和 `swift build`，必要时扩大范围。

## 建议执行顺序

1. 检查工作树、既有设计和以上测试；确认服务生命周期、当前默认模式与分布式 Iroh 配对方式。将握手变为可由生产客户端使用的设备能力发现与明确版本兼容结果，覆盖离线、旧版本和 Runtime 不可用。
2. 建立远端 Host 持有的 Session 服务和 Pharos 契约，包括按设备 / Agent / Session 的稳定身份、只读数据、事件订阅与恢复、发送与审批的请求标识。将既有本机适配器放到 Host 所有权之下，不把远端厂商协议或本地文件路径直接交给调用方。
3. 逐家接入 Session，保留真实能力差异，逐家完成 Thread 的成员绑定、投递和回复，再接入 Host 项目 / checkout 与 Session 的关联。切换生产路由时先保证当前功能有明确可用状态和错误呈现。
4. 设计并实现可见 SSH 备用：只有能确认请求未提交或已经安全对账时才允许重试；无法确定的结果保持 unknown，保留原请求身份并供用户或系统对账。不能把 Runtime 接收视为 Agent 已消费或已回复。
5. 在用户允许的真实远程环境完成双端部署与测试。按项目规则，涉及远端部署、`rsync` 或其他需许可的外向动作前，先准备具体方案再取得许可；不要停止或修改归属不明的服务和 Session。

## 功能验收标准

### 设备与通信

- [ ] 真实两台机器上分别运行 Pharos Host，以已配对身份建立连接；客户端可确认目标设备身份、服务版本及已公布能力。未配对、撤销、过期 epoch、权限不足、目标不匹配均拒绝。
- [ ] 旧版本、不兼容版本、Host 离线、Runtime 未启动、超时和重连均有可区分的状态；数据不可用时不呈现为已成功或新鲜。停止 GUI 后按产品设计验证独立 Host 生命周期，不能只用测试进程代替。
- [ ] 远程请求、事件、审批和附件的 Host 与 Session 归属贯穿全链路；同名设备、相同路径、不同机器上相同 Session ID 不发生串线。

### 每家 Agent 的 Session

对 Codex、DSH、Antigravity 分别记录版本、能力、实际测试及不支持 / 拿不到的数据：

- [ ] 经生产客户端对真实远端列出 / 打开指定 Session，核对 Host、Agent、历史及流式回复、思考和工具调用；不是经旧 SSH 厂商直连冒充 peer 通过。
- [ ] 发送与 steer、完成 / 错误、并发及重新打开正确；事件中断后能恢复或明确说明缺失，历史与可见状态一致，不产生重复请求或重复回合。
- [ ] 真实 HITL 从 Agent 请求、UI 展示、用户提交到 Agent 恢复完整闭环；验证支持的允许、拒绝、取消、过期和连接恢复。不可取得的类型按实际结果记录，不能通过 mock 声称厂商支持。
- [ ] Goal / Todo 逐项核对产生、变化、完成 / 清除、历史与重连快照；明确区分 Agent 原生不支持、未暴露和尚未观察到。保留各家特点，不把缺失映射为虚构数据。
- [ ] 输入框的权限 / 模式、模型和附件按 Host 与 Session 的实际能力动态显示；选择后验证真实生效和错误。图片及文档分别验证跨机字节传输、类型 / 大小、失败 / 重试、归属和历史；不把本机路径当作远端文件。

### Thread 和 Projects

- [ ] 每家 Thread 显式绑定目标 Agent Session 和所属 Host；验证真实 Agent 收到、消费并回复，区分排队、已送达、已消费、已回复及未知结果。断线、重复请求、多成员同名或相同 ID 时无错误投递。
- [ ] Projects 经所属 Host 的 Pharos 返回项目与 checkout 映射；按项目稳定 ID 与 Host 关联 Session。同路径跨机不自动等同；缺失映射、离线和陈旧数据可见，实际项目跳转指向正确主机和目录。

### SSH 备用与界面边界

- [ ] 能明确识别 peer 与 SSH 备用及其不可用原因；模拟 peer 不可用时确认支持的备用操作仍可用。已提交但回应丢失时不自动在 SSH 重发；对账后才能安全恢复。
- [ ] Session 右侧档案保留并显示实际所属 Agent 和机器；不要丢失 Thread / Session 的右侧 panel。输入框上方的 HITL、Goal、Todo 按数据状态显示，使用各家真实能力。
- [ ] 保持已有视觉要求：外层参考 brainstorm Grok Bot mockup、SVG 头像动效，Session 中间内容参考 DSH 的密集回复 / 思考 / 工具调用和输入；本次远程改造不以重做界面为由丢失已有视觉成果。此前要求的同尺寸截图与头像录屏对照仍按 [现有交接](handoff.md) 跟进，不得将功能测试当视觉验收。

## 测试标准与交付证据

1. **自动化**：覆盖协议编解码及边界、可信权限、Host / Session 路由、各家适配器、事件恢复、重复 / 超时 / 未知结果、备用选择和 UI 状态；测试须能在错误路由或重复执行时失败。优先针对受影响路径，记录实际执行测试名称、数量和结果；集成前运行适用的构建与回归集，标记 skipped 和未运行项。
2. **真实双机**：记录两端 Pharos 版本 / 构建、系统、Agent 版本、目标设备、连接路径、测试会话及测试时间；核对远端 Runtime / Agent 日志或 Session 历史与客户端显示。使用用户授权的测试数据，避免输出密钥及敏感内容；测试完成后仅清理明确属于测试且已获授权清理的资源。
3. **故障注入**：至少分别覆盖服务停止、网络中断与恢复、回复前断线导致结果未知、过期 / 撤销权限、并发和进程重启；观察真实 Host 端执行次数与客户端状态，不能仅以 UI 可点击或请求返回成功判定无重复。
4. **逐家记录**：将每个验收项记为通过、失败、未测或厂商不支持 / 数据不可得，写明证据路径、限制和原因；真实结果、受控模拟和推测分开。审批、Goal / Todo 或附件无法诱发时保留请求、响应及版本边界，不能填通过。
5. **交付判断**：只有三家可支持能力的生产 peer 路径、Thread / Projects、SSH 备用和真实远端测试满足上述清单，才可称整体完成。剩余缺陷、无法验证和需要用户操作的事项必须列出，不用握手成功替代整体验收。
