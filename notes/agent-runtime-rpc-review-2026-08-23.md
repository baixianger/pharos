# Agent Runtime RPC 控制面 Review + dsh 插件迁移回滚记录

> 2026-08-23 · macbook-air（本机）· 分支 `feat/agent-sidebar-shell`（与 mac-mini 同步，工作区逐字节一致）
> 范围：codex 在 mac-mini 上的最近一轮 session 产出 —— 提交 `546e265 Merge broker-dsh`、`2e3ae8b feat: establish agent runtime control plane` 及未提交的 agent-runtime 工作区。

## 1. 架构概览

五层控制面（RFC-003/004）：

```text
Pharos Broker（durable routing / mailbox / idempotency / cross-host identity）
   └─ Pharos Host Runtime（pharos-meshd：registry / queue / events / Unix RPC）
        └─ AgentRuntimeDriver（Codex App Server / Claude channel / DSH Cordis）
             └─ Presentation surfaces（Pharos UI / native TUI / vendor web）
```

关键新增（SwiftPM + Rust 双栈迁移中）：

| 层 | 位置 | 作用 |
|---|---|---|
| 契约 | `Sources/PharosAgentCore/AgentContracts.swift` | 状态机 / ownership / delivery / action availability |
| Rust 运行时 | `rust/crates/agent-runtime`（bin `pharos-meshd`） | registry、串行 worker 队列、事件 journal、Unix socket + stdio RPC |
| Codex 适配器 | `rust/crates/adapter-codex`（bin `pharos-codex-adapter`） | 起 App Server daemon、原生 WebSocket 升级 + 帧编码、JSON-RPC |
| Swift 门面 | `Sources/PharosRuntime/`、`Sources/PharosCodexAdapter/` | `CodexAppServerDriver` 起 `pharos-meshd --stdio` 的薄 IPC 客户端 |
| DSH 原生驱动 | `integrations/dsh-plugin-pharos/` | 注册 driver/conversation、轮询 delivery、`agent.followup()` 唤醒 |
| 群聊唤醒桥 | `Sources/PharosRuntime/MeshRuntimeDeliveryBridge.swift` | Broker 路由 → 本地 `delivery.submit-member` RPC |

## 2. 测试结果（全绿）

| 套件 | 结果 |
|---|---|
| `swift build` | 90 targets，成功（133s） |
| `swift test` | **228 tests，0 失败，1 skip**（`AgentAdapterTests` 3/3、`MeshRuntimeRoutingTests` 2/2） |
| `cargo test` | **12 tests，0 失败**（agent-core 2 / agent-runtime 7 / adapter-codex 3） |
| `node --test`（integrations/shared） | **3 tests，0 失败** |

> 工具链注：workspace 声明 `rust-version = "1.95"`，本机原为 1.94.1 导致 cargo 直接拒绝；已 `rustup update stable` → 1.98.0。

## 3. Review 发现（按严重度，均不阻塞）

1. **`integrations/shared/pharos-runtime-client.mjs` 的 `registerConversation` 丢 `memberID`**（低）：调用方（DSH 驱动）显式传 `memberID`，但解构时丢弃。目前被 Rust `delivery_submit_member` 的兜底（`member_id.is_none() && vendor_session_id == member_id` 时匹配并回填）掩盖 —— DSH 恰好 `vendorSessionID == memberID` 才没炸。建议显式透传。
2. **`Sources/PharosCodexAdapter/CodexAgentAdapter.swift` `perform(.archive)` 用 `fatalError("Handled above")`**（低）：库代码应 `throw`/`return`，守卫一变就是崩溃。
3. **`CodexAppServerDriver.didTerminate` 遍历 `pending` 字典时对其赋值**（低）：当前 Swift 容忍但脆弱。
4. **`delivery.submit-member` 返回形状嵌套**（低）：`result.delivery.id` 与 `delivery.submit`/`delivery.poll` 的平铺不一致，缺文档（e2e 首跑即被坑）。
5. **旧 `dsh-plugin-pharos/index.js` 仍是「每 3s 轮询 + fork CLI」桥**（迁移点，RFC 自认）：生产 mesh 里 30 个 `dsh-*` 成员**无 `state` 字段**，正是新 runtime 驱动尚未部署的证据。

## 4. 真实 agent 实测

**Agent 状态管控（DSH subagent）**
- 拉起 3 个 subagent → `running`；全部正确完成（5050 / Fibonacci 前 20 项 / 25 质数）。
- 中断运行中的 `sleep 40` agent → 回执 "was stopped before it finished"；**重复 interrupt 幂等**。
- `send_message` 恢复 → `ready → running → completed("resumed ok")` 闭环。

**群聊唤醒**
- DSH 群聊：create → invite 3 session → `chat_send` @all → `delivered: 3`，两个 session 被唤醒后各自 ack。
- Pharos mesh（实弹）：`@mention` → 进 mailbox 且可 `recv` 排空；**无 mention 纯广播 → `(no unread)`**，即「mention 才投递、普通消息只进 transcript」语义成立。

**控制面 e2e（`pharos-meshd` 起 socket 实测）**
`driver.register → conversation.register(带 memberID) → conversation.state(running/idle) → delivery.submit-member(幂等，重复返回同 id) → delivery.poll → delivery.ack(queued→consumed) → 再 poll 为空`，完整走通。

**生产 mesh 现状**：`mesh who --json` 拉取 41 成员（11 codex + 30 dsh，跨「白富贵」与「Xiang's Mac mini」）；codex 成员带 `state`（7 gone / 2 idle），dsh 成员无 `state`；累计 131 条未读。

## 5. pharos ↔ dsh 插件的「共享内容」

不是共享代码文件，而是**协议/契约层的隐式耦合**（各处手写重复、需人工同步）：

1. **Runtime RPC 方法名**：`driver.register / conversation.register / conversation.state / delivery.poll / delivery.ack / delivery.submit-member` 在 Rust（实现）、Swift（`AgentRuntimeRegistry` + `MeshRuntimeDeliveryBridge`）、JS（`pharos-runtime-client.mjs`）三处各写一份。
2. **投递信封 schema**：`{body, room, messageID, sender, replyToID}` 在 Swift `Envelope`、`mesh-delivery.mjs`、`deliveryText` 三处重复解析。
3. **CLI 契约**：旧插件全程 fork `pharos mesh join/send/recv/who/leave/unread --kind dsh --member --limit --json`（这些 flag 是 Pharos 专为 DSH 加的）。
4. **会话身份约定**：`memberID = agent.session.id`、nick = `sha256(sessionID)[0:12]`，两侧各实现一份。

唯一字面共享模块：`integrations/shared/`（仅 `claude-channel/server.mjs` import 了 `mesh-delivery.mjs`；`pharos-runtime-client.mjs` 是孤儿文件，且 DSH 插件自带一份 `runtime-client.mjs` 副本 —— 已出现两份实现分叉）。

## 6. dsh 插件迁移与回滚

- 迁移：`dsh-plugin-pharos/` → `~/personal/deepseek-harness/` 并提交 `7e94e54`（5 文件 601 删除）；`integrations/dsh-plugin-pharos/` → `deepseek-harness/dsh-plugin-pharos-runtime/`。
- 回滚：`git reset --mixed HEAD~1` 撤销提交 + 两个 `mv` 移回原处。
- 理由：
  1. 它是 **Pharos 的适配器**，不是 DSH 自身生态（`deepseek-harness/` 放的是 dsh-core/chat/bridge/weave/ios/network + awesome-dsh-plugin）。
  2. 契约仍在演进（RFC-003/004 未定稿、整片 agent-runtime 未提交），同仓改契约是原子提交，拆出去变跨仓契约。
  3. 切断 git 历史（插件历史留在 pharos，文件进非 git 目录）。
  4. 「移除不彻底」会把整体撕两半（插件在外、`AgentKind.dsh` 43 处仍在内）。
- 现状：**无净变化**，pharos 工作区与 mac-mini 一致。

## 7. 结论 / 建议

1. **DSH 插件现阶段留在 pharos 是对的**；等 agent-runtime 契约稳定、插件成为独立发布物（独立版本号 + 发布流程）后再考虑迁 `deepseek-harness`。
2. 优先修第 3 节 #1–#4（低危但都是以后会咬人的点）；#5 是迁移节奏问题，跟随 RFC-003 的「DSH 参考驱动」路线自然收敛。
3. 若要「彻底移除 DSH」，需先区分 **vendor-neutral runtime（留）** 与 **DSH 专属痕迹（`AgentKind.dsh` 等 43 处，移除）**，勿一刀切误伤 Codex/Claude。

## 8. 修复记录（2026-08-23 晚）

针对第 3 节发现，已修复并回归（均为未提交改动，与当前分支一致）：

| # | 文件 | 修改 | 回归 |
|---|---|---|---|
| 1 | `integrations/shared/pharos-runtime-client.mjs` | `registerConversation` 透传 `memberID` | node 3/3 |
| 2 | `Sources/PharosCodexAdapter/CodexAgentAdapter.swift` | `.archive` `fatalError` → `throw` | swift 228/0 |
| 3 | `Sources/PharosCodexAdapter/CodexAppServerDriver.swift` | `didTerminate` 改 `mapValues` 重建，不再遍历中改字典 | swift 228/0 |
| 4 | `rust/crates/agent-runtime/src/main.rs` | `delivery.submit-member` 顶层补 `deliveryID` | cargo 12/0 |

> 更正：#1 实际影响的是孤儿文件 `integrations/shared/pharos-runtime-client.mjs`（无人 import）。DSH 插件实际用的 `integrations/dsh-plugin-pharos/runtime-client.mjs` 是 `registerConversation(params)` 透传、memberID 正确转发。真正的隐患是「runtime-client 有两份实现、已在分叉」，留作后续整理。

## 9. DSH 群聊通道核实（重要更正）

此前报告把 `chat_*` 与 `pharos_mesh_*` 混为一谈，现纠正：DSH 里是**两套并存、互不共享状态**的通道。

| 通道 | 工具 | 底层 | 范围 |
|---|---|---|---|
| DSH 原生群聊 | `chat_create/join/invite/send` | `dsh-chat` + `dsh-bridge`（`agent.followup()`） | DSH 本机、进程内 |
| Pharos mesh | `pharos_mesh_send/recv/who` | `dsh-plugin-pharos` → pharos CLI → broker | 跨 vendor、跨主机 mailbox |

`~/.dsh/profiles/web/package.json` 的 bundles 同时装了 `dsh-plugin-pharos` / `dsh-bridge` / `dsh-chat`（还有 dsh-codex / dsh-weave / dsh-network）。`dsh-chat/lib/room-store.js` 内部调用 `bridge.deliverExternal(...)`，即 dsh-chat 的投递底层就是 dsh-bridge。

**路由是「随通道自选」而非随机**：每条通道的唤醒指令显式点名回复工具 —— dsh-chat 注入「call chat_send …」，pharos 插件注入「Run pharos_mesh_recv … then pharos_mesh_send」。实测两条通道消息都能送达；重叠属有意设计，保持现状。

## 10. 结论（更新）

- 4 个代码问题已修并回归全绿（Swift 228 / Rust 12 / Node 3）。
- 群聊双通道并存为有意设计，无需改动。
- 剩余建议不变：runtime-client 双实现分叉待合并；DSH 插件暂留 pharos。

## 11. DSH 归档状态对接（跨 session 闭环）

`session-fa7abebf` 指出：dsh 的「归档」是 workspace 注册表里的持久化集合 `archivedSessionIds`，语义是「从列表隐藏」而非终止——归档会话可能仍在后台跑。监控归档不能看进程存活，要看这个集合。

三路信号（fa7abebf 提供精确定位）：
1. 进程内 `ctx.on('domain/changed')`（domain='workspace'、table=''、operation='put'，逐字段 diff archivedSessionIds）
2. RPC/远端 `host/archived-sessions-changed`（payload 全量 archivedSessionIds）
3. `ctx.dshBridge.status(sessionId)` → `{state:'archived', live:false}`（rc.9+ 归档优先、rc.10+ 投递拦截）

Pharos 修复（`integrations/dsh-plugin-pharos/index.mjs`）：
- `archivedSessionIDs()` 读 `ctx.workspaceRegistry.archivedSessionIds`（pull）
- 归档会话报 `persistence:'archived'` + `presence:'offline'`
- 投递前拦截，归档时 `ack failed`（"archived and cannot receive messages"）
- `domain/changed` 事件驱动即时刷新（30s 归档感知 dedup 保底）
- 本机实装 dsh-bridge rc.13（≥rc.10），status()/target() 归档拦截均生效

## 12. Codex 归档结论

Codex 不需要 DSH 这套修复：归档语义是「历史/完结」（非「隐藏仍运行」），无「归档≠下线」投递陷阱，`presence:'offline'` 已够用。两个次级缺口（缺功能、非盲点）：
1. `CodexAgentAdapter.perform(.archive)` 是空壳（返回 "accepted, owner pharos-registry"，不落地）
2. `SessionsService` 不读 `~/.codex/archived_sessions`，UI 归档区不反映 Codex 自身归档标记
