---
summary: Historical WIP research and validation from before the Rust migration; current implementation may differ.
---

# 持续推进目标 — 本地 Cursor CLI

授权更新：2026-11-09 00:15 Europe/Copenhagen。用户要求设置目标持续推进：继续把 DSH、Antigravity 和远程主机的真实 Session 接进来，补上 Thread 和 Projects，然后逐家完成 HITL、Goal 和 Todo 的端到端验证；拿不到的数据记录下来，不强求；有时间加入 Cursor CLI。

## 执行方式
在当前 Mac mini 本地 pharos-dev-cursor 会话继续，不启动云端、Codex 或第二个 writer；agy 保持 STOP。本文件是原 handoff 的范围扩展，不是定时任务或无限重试。先核对 docs/handoff.md 最新事实、docs/2026-11-08_remote-pharos-handoff.md、RFC-006、docs/agents/ 和输入能力清单，保留既有架构和视觉成果。发现文档冲突明确记录，不默改 RFC。按阶段自行规划、实施、验证、checkpoint，然后立即进入下一个安全阶段，不在每个小阶段总结后等用户再次说继续。

## 优先范围与完成条件
1. 从当前稳定回复边界之后继续 Host-owned Session identity/binding/生产投递桥，接通真实 DSH、Antigravity Session；已有 Codex 作为回归基线。按设备/Host/Agent/Session 精确归属，历史、发送、事件和恢复有真实可用状态。
2. 远程资源通过所属 Pharos Host 调用其本机 Agent，保留明确可见且安全的 SSH 备用；未知结果不自动跨路径重发。只使用此前明确授权且可访问的测试端点，不把同进程或 loopback 测试称为跨机。
3. 补 Thread 显式成员绑定、定向投递和唯一关联回复，区分 queued、delivered、consumed、replied、unknown，避免 legacy 唤醒重复；补 Projects 稳定 ID、Host checkout 映射、Session 关联及正确跳转，离线/陈旧/缺失可见。
4. 按每家实际支持的协议逐项端到端验证 HITL 请求→展示→允许/拒绝/取消→Agent 继续，以及 Goal/Todo 创建、变更/进度、完成/清除、重读/重连/恢复。核对真实 Agent 历史、日志与生产界面；受控 fixture、真实本机、真实远端、UI 证据分别列出，不混报。不能诱发的数据、厂商未支持/未暴露的能力记 unsupported/unknown/not-tested，并写版本、原因、证据，不伪造能力、不无限重试，继续其他安全独立阶段。
5. 核心目标推进后若时间/能力允许，调查并加入 Cursor CLI 适配，仅用正式支持且文档可核实的 CLI/协议；不能凭空假设 ACP/API，不读取其私有数据库/凭据或桌面 GUI 状态。能力不足则记录限制，不阻塞核心目标。

## 安全与授权边界
- 所有真实测试消息、Session fixture、runtime/socket 测试资源只在 ~/personal/pharos-msg-test 隔离环境；不向正常房间或他人发送。HITL 测试仅精确匹配无副作用命令，不能自动批准未知/破坏性命令。
- 不使用用户 dsh 3080、ipc.sock、~/.gemini/dsh、私人 app/workspace 状态或 secrets；不读认证 token，不使用公司 Pro，不干扰正常服务。
- 远程集成目标不等于任意部署/重启/rsync/新主机访问许可；仅用已授权测试端点。需新部署、未知远程变更、认证或扩大权限时停止该动作、记录具体所需授权，并继续不依赖它的安全工作。
- canonical 插件源码仅 ~/personal/deepseek harness/dsh-plugin-pharos；树内 integrations 包是不同包装，先核对差异，不能互相覆盖或改用户 profile 链接。DshBackendAdapter 保持 thin client。
- 保存既有大量未提交/未跟踪成果和 .agy-tasks/PLAN.md 暂存；不要 blanket add、清 staging、reset/rebase/force-push、删除用户工作或杀未知进程。允许仅自己本轮可清晰分离的 focused local commits；若不能避免带入既有成果则不 commit，记录待整理。禁止 push/PR。

## 每阶段持久记录与停止条件
更新 docs/handoff.md 及相关 Agent 文档：实际代码变化、执行的测试名称/数量/结果、证据路径、真实/模拟边界、失败与不可得数据、下一阶段。原始非敏感证据可写 internal/evidence/；时间用 Europe/Copenhagen。先复用已有证据并仅重跑受影响测试，按需要 swift build/回归，不把无测试执行当通过。
在每阶段 checkpoint 后继续下一阶段；整体目标完成、真实安全/授权/认证阻塞或竞争 writer 时才停止相应动作。无依赖的工作继续；全部剩余阶段均阻塞时给出准确 blocker 清单及可复现状态，不把仅首个小阶段完成当整体完成。

## 2026-11-09 11:50 Multi-host addendum

用户于 2026-11-09 11:47（Europe/Copenhagen）明确授权：把 mac-air 和 grok-bot 作为真实远程 Pharos Host/Peer 使用，并允许在这两台上安装、运行无界面的 Agent 后端（只在 tmux 中运行，不用桌面 app）。本节扩展上文「远程集成」授权范围，仅限下列三台；其他主机、部署方式仍按原规则需单独授权。

### 三台 tailnet 主机（版本已对齐、均已登录）
四个 CLI 在三台上版本一致：Codex 0.167.0、agy 1.5.3、Cursor agent 2026.11.05-86047df、dsh 0.2.2-rc.1。
- **mac-mini**：本地主机，Pharos 在这里运行（当前机器）。
- **mac-air**：`ssh mac-air`，macOS。通过 SSH 运行 Cursor `agent` 时必须设置环境变量 `AGENT_CLI_CREDENTIAL_STORE=file`（SSH 下登录钥匙串锁定）。
- **grok-bot**：Grok Bot 的 Linux box，tailnet 名 `grok-bot.tail849fa3.ts.net`。IP 会变，一律用名字，不写死 IP。目标入口是 `ssh box@grok-bot`。
  - 2026-11-09 11:50 实测：从 mini 访问失败，`grok-bot` 和 `grok-bot.tail849fa3.ts.net` 都无法解析，box 上也没有运行 sshd。**当前记为 unavailable**；不要绕过（不改 DNS/hosts、不写死 IP、不装隧道）。可达后再纳入；在此之前跨机验证以 mini ↔ air 为准。

### 优先级
(a) 真实远程 Host Peer：mac-mini、mac-air、grok-bot 之间使用真实 peerDeviceIDs；Codex、dsh、agy、Cursor CLI 的跨机 Session。
(b) 新路径：Host binder → Runtime submit → product replyOnce，用真实 agy/dsh 验证（不是 legacy Broker）；然后补 DSH/Codex Thread 投递桥。
(c) 跨 Peer 的 Projects。
(d) 每家后端的 HITL、Goal、Todo 端到端验证。
(e) Cursor CLI 作为第四个后端接入。
拿不到的数据记为 not-tested，并写明原因、版本、证据；不强求，不无限重试，继续做其他独立阶段。

### 硬规则（全部保留）
- 真实消息只发在 ~/personal/pharos-msg-test；远程主机上同样建一个镜像测试工作目录（如 ~/personal/pharos-msg-test），只在里面测。
- 不碰 mac-pro（公司 MacBook Pro）。
- 不碰用户 3080 端口上的 dsh Host、它的 token 和 ipc.sock，不碰 ~/.gemini app 状态和 dsh workspace.json。
- 不打印 token/密钥/登录链接。
- 不 push、不 force-push、不改写历史，不开 PR。
- dsh Thread 闭环只在 ~/personal/deepseek harness/dsh-plugin-pharos 里修；DshBackendAdapter 保持 thin client，不做假成功。
- agy（pharos-dev-agy）保持 STOP，不要第二个 writer。
- 按小阶段本地 commit（只提交本轮可清晰分离的改动，保留既有未提交成果和 PLAN.md 暂存），每阶段写诚实的证据日志和阶段报告。

### 2026-11-09 12:05 Update: grok-bot box now reachable
- Tailscale SSH enabled on the Grok Bot box (user approved 12:02). From the mini: `ssh box@grok-bot-1` works (hostname grok-bot-vm-…, user box).
- The box is an ephemeral tailnet node: its name may be `grok-bot` or `grok-bot-1` and its IP changes. Resolve it at test time with `tailscale status | grep grok-bot` (pick the online one); never hard-code the IP.
- The box has Codex 0.167.0, agy 1.5.3, Cursor agent 2026.11.05 and dsh 0.2.2-rc.1, all logged in. It is now usable as the third real host for priority (a). Don't touch anything on the box's port 3080 (another dsh web) or its tailscale config.
- The old agy process (PID 13952) in pharos-dev-agy was stopped at 12:03; the session shell is kept. agy stays stopped as a writer.

### 2026-11-09 12:10 Update: Pharos (Grok Bot) plays the human in tests
- User authorized (12:09): for E2E tests, the PM agent Pharos (on the grok-bot box host) acts as the human. It may open and control Threads and Sessions, post, reply, and approve or reject HITL. This unblocks HITL/Goal/Todo E2E without the real user present.
- Protocol: when a test needs a human action, write a request file `~/personal/pharos-msg-test/human-requests/<timestamp>_<slug>.md` stating what is needed (thread/session id, action, expected outcome, and a timeout). Pharos picks it up, performs it, and writes `<same-name>.done.md` with what it did. If Pharos can drive it directly from the grok-bot host via the CLI/mesh as a human node, prefer that and document the command.
- Evidence logs must label these actions as `human=pharos-proxy`, never as the real user. Test workspaces only.
