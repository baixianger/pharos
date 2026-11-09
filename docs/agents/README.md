---
summary: Agent 文档按 Codex、Antigravity、DSH 分为 Session 协议和 Thread 状态通信，验证证据另见各家记录。
---

# Agent 协议文档

| Agent | Session | Thread |
| --- | --- | --- |
| Codex | [Session](codex/sessions/2026-11-07_protocol.md) | [Thread](codex/threads/2026-11-07_protocol.md) |
| Antigravity | [Session](antigravity/sessions/2026-11-07_protocol.md) | [Thread](antigravity/threads/2026-11-07_protocol.md) |
| DSH | [Session](dsh/sessions/2026-11-07_protocol.md) | [Thread](dsh/threads/2026-11-07_protocol.md) |
| Cursor CLI | [Session](cursor/sessions/2026-11-09_protocol.md) | （未接入 Thread） |

这些页面区分当前源码路径和真实验证结果；详细测试及未取得数据以各家的验证记录为准。不要将设计稿或模拟测试当成生产闭环。

分布式 Thread 稳定回复（2026-11-08）：`DistributedChatRegistry.replyOnce` / `DistributedAgentChat.replyOnce` 的同机共享连接与离线双副本冲突边界已受控通过 4 项测试（证据 `internal/evidence/2026-11-08_replyonce-conflict-boundaries.log`）。

Host-owned Thread 绑定（2026-11-09）：`MeshHostThreadBinder` + Host Session RPC `bindThreadMember` / `threadBindingInspect` + 桌面分布式本机绑定入口已落地；queued/consumed/replied/unknown 映射与 loopback Iroh 对等绑定受控通过。不等于真实 Agent 消费、Runtime 队列生产投递或跨机 Peer；详见 [交接](../handoff.md)。


## 接入边界

按用户确认，接入范围是各 Agent 的 CLI 或其协议明确支持的 Session；不以桌面客户端界面自动化、私有 GUI 实现或猜测其本地状态作为接入方式。Pharos 自己的 macOS/WebKit 界面可用于验证这些数据。DSH 的 `dsh web --no-open` 是 CLI 启动的本地服务，本机 CLI 虽位于 DeepSeek Harness.app 包内，也不等于通过 GUI 自动化接入。Codex 使用 shared App Server 的公开协议，该服务的返回值可能包含来自不同客户端的会话，当前列表没有按 `sourceKinds` 过滤，不能把所有结果称为 CLI 创建或保证其他客户端会话可由 Pharos 控制。来源不清或协议能力未验证时应标为未验证。

远程接入以 Pharos ↔ Pharos 为主路径：远端 Pharos 负责适配其本机 Agent。本机当前的多条 SSH 直连厂商协议及读取私有偏好路径尚不符合主路径边界，用户确认将其保留为明确标识的备用方案；逐项源码审计与迁移验收见 [架构决策](../RFC-006-UNIFIED-CLIENT-AND-BACKEND-INTEGRATION.md#remote-pharos-boundary-and-current-deviations)。
