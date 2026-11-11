---
summary: 2026-11-11：跨 Host 会话（host.session.query/action）Rust 端到端落地（XHOST-DONE）；三个已验收 Rust 流（hitl-persist / web-real-sessions / thread-autoreply）已 --no-ff 合入 rust/integrate-dsh3。见本文件顶部。
---
# 活跃任务交接

**STATUS: XHOST-DONE — 689f3d1**
**分支/worktree**：`rust/cross-host-sessions`，worktree `/workspace/pharos-rust/2026-11-11_dsh-wave2/wt/cross-host-sessions`，base `integrate/mesh2-into-main @ 54c6ff6`（= `rust/integrate-dsh3`，已含 hitl-persist / web-real-sessions / thread-autoreply 三流）。未 push、未 force/rebase/amend、未改写任何已有提交；只 `git fetch --all` 读过远端 ref。只在本 worktree 内改代码；未触碰其它 worktree/主 checkout，未碰 3080 dsh Host、其 token/ipc.sock/state、`~/.gemini`，未 ssh 到任何 Mac。团队：本流 Lead（protocol + replica 分发/授权 + loopback E2E + 集成 + 门禁 + 交接）、teammate `impl-client`（task-1：pharos-session 远端客户端/host bridge + pharos-http 合并服务）、teammate `impl-host`（task-2：agent-runtime mesh bring-up）。上面 STATUS 的 `689f3d1` 是最后一个代码提交；本交接为紧随其后的 docs-only 提交。**未改任何 Swift / `Sources/` / `webui/` / WebCanvas 资源**（`git diff --name-only 54c6ff6..HEAD` 只有 `rust/`）；未改 `pharos-http/src/router.rs`、`pharos-hitl`、`integrations/dsh-plugin-pharos`；`asset_sync` 测试仍绿。**Swift 未在 Linux 编译验证**（本机无 Swift；本流未触碰 Swift）。

**做了什么（跨 Host 会话：一台 Host 经 Mesh 查询/操作另一台 Host 上的会话；对应 WIP salvage gap "Host session query/action：Missing end-to-end"）**
1. **版本化 wire contract（`pharos-protocol`，additive，未 bump `CONTRACTS_VERSION=0.1.0`）**：新增 `pharos_protocol::host_session`。`host.session.query.v1`：`listSessions` / `getSession` / `sessionHistory`；`host.session.action.v1`：`sendMessage` / `steer` / `resolveApproval` / `stop`。请求/响应均带 `payloadVersion=1`（未知版本显式 `invalid-request`）、camelCase 字段与 WIP Swift `HostSessionSchema`/`queryKind`/`actionKind` 字符串对齐；session/approval/turn/message 上限校验；结构化错误体 `{code,message}`，错误码明确为 `unauthorized`（未配对/allowlist/trust group 不符）、`unknown-session`、`host-unreachable`（仅调用方本地合成）、`adapter-unavailable`、`invalid-request`、`unsupported-operation`、`internal`。hello 能力名 `host-session-query-v1` / `host-session-action-v1`。
2. **被调 Host 侧分发 + 授权 + 审计（`pharos-replica` / `pharos-mesh`）**：`ReplicaHandle` 新增 `host.session.query/action` 分发；应用层通过新增 `HostSessionHandler` trait 注入（Rust 适配器保持很薄：不含 Thread 闭环，闭环仍在 `integrations/dsh-plugin-pharos`）。授权沿用既有 trust group + membership epoch，并新增 paired-peer allowlist（`pharos-mesh::open_handle` 从 `<data-dir>/peers.json` 载入 endpoint 列表；无 peers 时保持旧 trust-group 语义；不在 allowlist 的 peer 得到结构化 `unauthorized`）。动作幂等：`ActionReplayCache` 以 (peer endpoint, idempotencyKey) 为键、按"效果"（host+session+typed payload，忽略每次重试的 actionId）判定——同 effect 重试复用上次响应不重复执行、同 key 不同 payload 显式 `invalid-request`、失败不缓存、容量 256、跨 peer 隔离。审计 `HostSessionAudit` 只记录 operation/hostDeviceId/remote endpoint/sessionId/outcome，**不含消息正文、approval 内容或密钥**。新增 `MeshIrohEndpoint::close` + `ReplicaHandle::shutdown`，使"Host 离线"可在测试中确定性复现。
3. **调用方（Rust）：远端会话客户端 + 本机会话列表合并（`pharos-session` / `pharos-http`）**：`pharos_session::remote` 提供 `RemoteSessionSource` trait 与 `MeshRemoteHostSessionSource`（经 `peer_host_session_query/action` 做 list/get/history/send/steer/approval）；远端会话 ID 命名空间为 `peer:<hostDeviceId>:<sessionId>`（响应里 `machine_id`=远端 host、`connection_route="mesh"`，避免与本地 ID 冲突）；错误映射显式：未授权→`OperationFailed("unauthorized: …")`、未知会话→`SessionNotFound`、Host 离线/超时→`BackendUnreachable{backend,reason}`、适配器不可用→`OperationFailed("remote host adapter unavailable: …")`、unsupported→`OperationFailed`。`pharos_session::host_bridge::SessionServiceHostHandler` 把 mesh 请求转给本机同步 `SessionService`（`stop` 明确 `Unsupported`，**绝不伪造成功**）。`pharos_http::services::RemoteSessionMergedService` 在现有 HTTP `SessionService` trait 层组合"本地 + 远端"：`GET /api/v1/sessions`、`GET /{id}`、`/history`、`POST /messages`、`/steer`、`/approval` 原路由直接复用（**没有新增/修改 `router.rs`**）；远端不可达使合并列表/库存返回 502 `backendUnreachable` 而不是静默丢弃或空成功；未知 `peer:` host→404；远端 progress 明确 `OperationFailed("remote session progress is not available")`。
4. **daemon 侧接线（`agent-runtime`，最小改动）**：`--mesh-data-dir` / `--mesh-relay-disabled` 最小追加；`mesh_bridge::spawn` 起独立线程 + tokio runtime，经 `open_handle_with_host_sessions` 安装 `SessionServiceHostHandler`，返回 online 的 deviceId/endpointId，失败 exit 1（无静默成功）；`session_service::local_session_service` 默认接显式 `UnavailableSessionAdapter`（live 操作全部显式 AdapterError、读为空、history not-found），仅 `PHAROS_MESH_SESSION_ADAPTER=codex` 时接真实 Codex App Server，goals 落盘。`pharos-mesh-node` CLI 新增 `host-session-query` / `host-session-action` / `save-peer`，用于真机跨机验证与 allowlist 配置。

**改了哪些 crate/文件（26 files, +5705/−44，全部在 `rust/`）**
- `pharos-protocol/src/host_session.rs`（新，869 行）、`lib.rs`（模块声明）。
- `pharos-replica/src/host_session.rs`（新：Handler trait/Fault/审计/replay cache）、`handle.rs`（分发+授权+幂等+审计+peer 方法+能力）、`rpc.rs`（`ReplicaRpcError::{HostSession,Unreachable}`）、`lib.rs`（导出）。
- `pharos-mesh/src/lib.rs`（`open_handle_with_host_sessions`、`paired_peer_endpoint_ids`）、`src/bin/pharos_mesh_node.rs`（3 个新子命令 + 单测）。
- `pharos-iroh/src/transport.rs`（`close`/`shutdown` + 离线测试）。
- `pharos-session/src/{remote.rs,host_bridge.rs}`（新）、`lib.rs`、`Cargo.toml`；`service.rs` 仅把 trait bound 改为 `Send + Sync`（HostSessionHandler 需要 `Arc<dyn SessionService>`）。
- `pharos-http/src/services/remote_session.rs`（新）、`services/mod.rs`（导出）。
- `agent-runtime/src/{mesh_bridge.rs,session_service.rs,replica_bridge.rs}`、`main.rs`（仅追加 ~30 行）、`Cargo.toml`。
- `rust/Cargo.lock`（经 cargo 更新）。
- 未改：`pharos-api` 冻结 contracts、`router.rs`、`pharos-web`、Swift/WebCanvas/webui、`pharos-hitl`、dsh 插件。

**新增测试（80 个新 test fn；workspace 222→303）**
- `pharos-protocol/src/host_session.rs`：12 个 serde/校验测试（query/action 各 kind roundtrip、tagged response、payloadVersion 拒绝、sessionId 规则、text 上限、错误码 kebab 稳定性与结构体、summary/turn 映射名）。
- `pharos-replica/src/host_session.rs`：7 个（replay 精确重试、新 actionId 重试、同 key 不同 payload 冲突、跨 peer 不串用、容量淘汰、审计行不含正文、Fault→Code）。
- `pharos-iroh/src/transport.rs`：+1（关闭 endpoint 后 exchange 失败）。
- `pharos-mesh/tests/host_session_smoke.rs`（新，4）：A 经 loopback iroh 列 B 会话/读历史/get/发消息到 B（B handler 收到）/steer/approval、retry 不重复投递、同 key 不同 payload 冲突、stop 显式 unsupported、错误 hostDeviceId 拒绝；allowlist 外 peer 与异 trust group 均 unauthorized；未启用 host session 的 host 显式 unsupported；B 关闭后 A 得 `Unreachable`（非空成功）。
- `pharos-mesh/tests/remote_session_bridge.rs`（新，3）：生产 `MeshRemoteHostSessionSource` + `SessionServiceHostHandler` 全链路（列表/读史/发消息落 B 本机 SessionService、`peer:` 前缀/machine_id/connection_route、retry 幂等、steer/approval）、adapter 不可用 host 显式报错、离线 host → `BackendUnreachable`。
- `pharos-mesh` bin：+2（approval decision 解析、endpoint id 解析）。
- `pharos-session`：+24（remote 前缀/映射/错误映射、host_bridge query/action/stop/错误映射）。
- `pharos-http`：`tests/remote_sessions.rs`（新，11，黑盒 `api_router` tower oneshot：合并列表前缀、history/messages/get、list 与 inventory 远端不可达 502 `backendUnreachable`、未知 peer host 404、远端 progress 显式 502、本地路由不受影响）+ 合并服务 lib 测试 9。
- `agent-runtime`：+8（5 session_service：不可用 adapter 显式报错、goals 缺失降级等；2 replica_bridge；1 mesh_bridge 真实 loopback iroh：spawn 后 peer listSessions 返回本机服务会话）。

**门禁结果（`rust/` 下，`CARGO_BUILD_JOBS=3`，最终代码 `689f3d1`）**
- `cargo fmt --all -- --check` → **PASS**（exit 0，无输出）。
- `cargo clippy --workspace --all-targets -- -D warnings` → **PASS**（exit 0，0 warning）。
- `cargo test --workspace` → **PASS**（exit 0，**303 passed / 0 failed / 0 ignored，60 suites** 含 doc-tests；base `54c6ff6` 为 222）。本流关键 crate：pharos-protocol 15、pharos-replica 11、pharos-iroh 5、pharos-mesh 11（lib 1 + bin 2 + host_session_smoke 4 + remote_session_bridge 3 + peer_rpc_smoke 1）、pharos-session 26、pharos-http 64（lib 40 + approvals_api 9 + real_state_http 4 + remote_sessions 11）、agent-runtime 40、pharos-web 28+…（含 `asset_sync` 1 绿）。其余既有 crate 数字与 base 一致（hitl 19、adapter-codex 19+8、adapter-agy 4+1、adapter-cursor 8+2、adapter-dsh 9+1、thread 5、goals 1+1、grokbot 4+1、codex_hitl_live 1、store-schema 2、api 5、agent-core 2）。
- 额外：本 worktree `git status --porcelain` 干净；`git diff --name-only 54c6ff6..HEAD | grep -v '^rust/'` 为空（未触碰 Swift/WebCanvas/webui）。

**没做/未验证**
- **真实跨机（mini↔Air）未验证**：规则禁止 ssh 到 Mac，本流只在 Linux loopback iroh（`RelayMode::Disabled` 直连）验证。Mac 上验证步骤见下（数据目录只用 `~/personal/pharos-msg-test/xhost-*`，绝不发到真实房间/3080 Host）：
  ```bash
  # 两台 Mac 各自 `cd rust && cargo build -p pharos-mesh -p pharos-agent-runtime`
  # --- B 机（被调 Host，例：mini）---
  B=~/personal/pharos-msg-test/xhost-b
  ./target/debug/pharos-mesh-node init --data-dir "$B" --name mac-mini
  ./target/debug/pharos-mesh-node print-endpoint --data-dir "$B"   # 记下 endpointId / endpointAddr；cat "$B/node-identity.json" 记 deviceId/trustGroupId
  # 启动被调 Host（同 LAN 用 --mesh-relay-disabled 直连；跨网去掉该 flag）
  PHAROS_MESH_SESSION_ADAPTER=codex ./target/debug/pharos-meshd \
    --mesh-data-dir "$B" --mesh-relay-disabled \
    --data-dir ~/personal/pharos-msg-test/xhost-b-agent \
    --thread-data-dir ~/personal/pharos-msg-test/xhost-b-thread
  # 期望 stderr: "pharos-agent-runtime: mesh host online device=… endpoint=…"
  TICKET=$(./target/debug/pharos-mesh-node invite --data-dir "$B" --endpoint-id <B endpointId> --address-ticket '<B endpointAddr>')
  # --- A 机（调用方，例：Air）---
  A=~/personal/pharos-msg-test/xhost-a
  ./target/debug/pharos-mesh-node accept --data-dir "$A" --invitation "$TICKET" --name mac-air
  ./target/debug/pharos-mesh-node print-endpoint --data-dir "$A"   # 记 A 的 deviceId/endpointId 回填到 B
  # --- 回 B：把 A 记为 paired peer（启用 host session allowlist）---
  ./target/debug/pharos-mesh-node save-peer --data-dir "$B" --peer-device-id <A deviceId> --peer-endpoint-id <A endpointId> --name mac-air
  # --- A 查询/操作 B 的会话 ---
  ./target/debug/pharos-mesh-node host-session-query  --data-dir "$A" --peer-endpoint <B endpointId> --peer-addr '<B endpointAddr>' --host-device-id <B deviceId> --kind list
  ./target/debug/pharos-mesh-node host-session-query  --data-dir "$A" --peer-endpoint <B> --peer-addr '<B addr>' --host-device-id <B deviceId> --kind history --session <sessionId>
  ./target/debug/pharos-mesh-node host-session-action --data-dir "$A" --peer-endpoint <B> --peer-addr '<B addr>' --host-device-id <B deviceId> --session <sessionId> --action send --text 'hello from air'
  ./target/debug/pharos-mesh-node host-session-action ... --action steer --text 'focus on tests'
  ./target/debug/pharos-mesh-node host-session-action ... --action approve --approval-id <approvalId> --decision allowedOnce
  ./target/debug/pharos-mesh-node host-session-action ... --action stop    # 期望明确的 unsupported-operation，而不是成功
  # 离线语义：停掉 B 的 pharos-meshd 后重跑 --kind list，期望 "peer unreachable"，而不是空列表
  ```
  说明：`invite` 需要 controller role（`init` 默认给 controller/host/replica）；若 B 的 `peers.json` 非空则只有 allowlist 内 peer 可访问（可用 `save-peer` 配置第二个空 peers 的 B 目录做对照）；`/kind list` 需要 B 侧 live adapter 才有非空会话（`PHAROS_MESH_SESSION_ADAPTER=codex` 且本机有 codex CLI；否则列表为空但历史/动作显式报 adapter 不可用）。
- **live Codex adapter 路径未验证**：`PHAROS_MESH_SESSION_ADAPTER=codex`（真实 Codex App Server 会话的远程 list/send）仅编译通过，未在本机 spawn vendor 进程验证；默认 `UnavailableSessionAdapter` 路径已测（显式报错、不伪造）。
- **pharos-web 二进制未接线远程合并**：`RemoteSessionMergedService` 已在 Service 层可用并有 HTTP 黑盒测试，但默认 `pharos-web` 不打开 mesh handle / 不配置远端 host，所以真实 HTTP 进程的跨 Host 列表尚未接上（见"需要人决定"）；也未新增/修改路由。
- **未做**：`host.session.events.v2` 事件流、远端 progress/configuration/attachment/approval-snapshot 查询（v1 契约不含；远端 progress 显式 unavailable）、`stop` 的实际执行（Host 明确 unsupported）、OpenAPI stub 追加、`CONTRACTS_VERSION` bump。
- Swift ClientKit 的远端会话模型/前缀迁移未做（Linux 无法编译 Swift）。
- 真实跨机时 iroh relay/NAT 行为、Mac launchd 托管、双机 token/信任撤销未验证。

**需要人决定**
1. `pharos-web` 二进制是否/如何接线远程 Host 会话（需要 mesh identity/data-dir、peer 端点与 endpointAddr 配置 UX；且当前"任一远端离线即整体 502"的诚实语义会让默认列表受远端可用性影响）。
2. 合并列表语义：任一远端不可达即整体 502（当前，绝不静默丢 host）vs 部分列表 + 按 host 状态/错误字段（需要 `pharos-api` 契约变更）。
3. `stop`：wire 契约已含 `stop`，但本机 `SessionService` 无 stop，Host 如实返回 `unsupported-operation`；是否实现真正 stop/interrupt 语义（adapter `interrupt` + 状态收敛）。
4. 会话 ID 命名空间：本流用 `peer:<hostDeviceId>:<sessionId>`；WIP Swift 用 `peer:<host>:codex:` 等 agent 后缀。Swift ClientKit 迁移时需统一（以及 approval/turn id 前缀规则）。
5. allowlist 的配对闭环：`accept` 只在 accept 侧写 inviter peer，inviter 记录 accepter 目前靠手工 `save-peer`；是否加配对回执自动落 `peers.json`，以及是否把"无 peers = 仅 trust-group"收紧为必须 allowlist。
6. 是否把新 operation/能力写进 `pharos-api` OpenAPI stub、是否 bump `CONTRACTS_VERSION`（当前对 Phase 0 是 additive，未 bump）。
7. 远端会话的 progress/goal/todo 与 approval 快照是否纳入下一版 wire 契约（当前 HTTP 侧显式 unavailable）。

# ---- web-endpoints 流交接（合并保留）----
# 活跃任务交接

**STATUS: WEBAPI-DONE — dac9f1447d7edb674c54bccae94a6bf1252307ac**
**分支/worktree**：`rust/web-endpoints`，worktree `/workspace/pharos-rust/2026-11-11_dsh-wave2/wt/web-endpoints`，base `integrate/mesh2-into-main @ 54c6ff6`（= `rust/integrate-dsh3`，已含 hitl-persist / web-real-sessions / thread-autoreply 三流）。本 handoff 提交之前共 26 个提交，未 push、未 force/rebase/amend、未改写历史；只改本 worktree，未触碰其它 worktree（cross-host-sessions / live-e2e 保持原 tip）与主 checkout。团队：Lead（契约、pharos-hitl 决定模型、SessionService 能力扩展、router/handlers/openapi、HTTP 集成测试、门禁、真实二进制 smoke、handoff）、teammate `server-impl`（持久化 stores、fake/real 能力实现、pharos-web 双模式接线、真实 HTTP e2e 测试）、teammate `frontend-impl`（webui+WebCanvas 接线、node 测试、独立复核）。

**做了什么（补齐 docs/2026-11-11_wip-salvage-gaps.md 的 "Unavailable workspace operations"）**
- **统一契约**：新增 `docs/2026-11-11_web-endpoints-api.md`（路由/JSON 形状/持久化文件/错误码/测试矩阵）；`docs/2026-11-11_wip-salvage-gaps.md` 增加"Update 2026-11-11 — web workspace endpoints"段，声明上述不可用项已被本流取代。所有新路由都挂在 `api_router`（`app_router_with_token` 的 bearer 层覆盖全部 API，`/health` 与静态资源仍免鉴权），并补进 `/openapi.json`。
- **（1）Thread↔会话绑定**：`GET/PUT/DELETE /api/v1/threads/{id}/bindings[/{member}]`、`GET /api/v1/threads/{id}/members`。持久化 `thread-bindings.json`（version 1，temp+fsync+rename 原子写；损坏/空/未知 version 启动即报错，绝不静默重置）；binding key=(threadId,member)，upsert 全量替换；PUT 校验 Thread 存在、member 名 `[A-Za-z0-9_-]{1,40}`、session 在现有 inventory 中；新增的成员名即"绑定即成员资格"（WIP UI "add existing local Session" 流程），`members` 返回 replica 成员 ∪ 已绑定成员 + 每成员持久化设置。只读 binding 列表即投递路由可消费的接口（本流不改 agent-runtime 投递逻辑）。
- **（2）会话配置读写**：`GET/PATCH /api/v1/sessions/{id}/config`（model/mode、supportedFields、models/modes、capabilities{attachments,commands,stop,revive}、readonly）。诚实语义：适配器无法报告配置 → 空的 `supported:false` 视图（不发明 model/mode）；无法应用字段 → `502 unsupportedField` 带 `error.field`，绝不报告为已保存。当前无适配器声明可写配置（真实后端诚实 502；fake 测试服务覆盖成功路径）。
- **（3）问卷回答 + 取消型审批决定**：`pharos-hitl` 新增 `StoredDecision`（含 `cancelled`）与 `QuestionnaireAnswer`，仍存于既有 `pending-approvals.json`（version 保持 1，旧记录可加载；旧三值 camelCase 序列化不变）。既有 `POST /api/v1/sessions/{id}/approval` 请求体成为线上兼容超集（`questionnaireAnswers` 可选、`decision` 可为 `cancelled`；仅当 adapter 的 `availableChoices` 含 `cancelled` 时接受，否则 400 且不消费审批）。沿用 hitl-persist 的 first-wins 幂等、45m 过期、downstream 派发失败 revert 保持可重试；问卷答案随决定持久化并可在重启后读回。
- **（4）成员设置/头像**：`GET/PATCH /api/v1/members/{id}`、`GET/PUT/DELETE /api/v1/members/{id}/avatar`。`member-settings.json` + `avatars/<sha256>.<png|jpg>` 持久化在 data dir，重启后仍在；头像仅 png/jpeg、1..=512 KiB，非法类型/超限/base64 损坏 → 400；`member-settings.json` 损坏启动硬报错。成员视图含 `bindings`（跨 Thread 绑定汇总）。
- **（5）附件上传**：`POST /api/v1/sessions/{id}/attachments`（base64 JSON，content-type 白名单、解码后 1..=10 MiB；axum body limit 放宽到 16 MiB 后由 handler 精确判 400）、`GET /api/v1/attachments/{id}[/content]`、`GET /api/v1/sessions/{id}/attachments`；`POST /sessions/{id}/messages` 增加可选 `attachmentIds`（冻结请求的超集，空=原样字节不变），引用必须存在且属于该 session；适配器不支持附件时 `502 unsupportedField{field:"attachments"}`，绝不当成已发送。
- **（6）stop/revive**：`POST /api/v1/sessions/{id}/stop|revive`；无真实适配器声明该能力时明确 `502 unsupportedOperation{field}`（fake 测试服务覆盖成功路径）。
- **（7）前端**：`webui/` 与 `Sources/Pharos/Resources/WebCanvas/` 同步改并逐字节一致（`asset_sync` 绿，`diff -r` 无输出）：refresh 读 config/members/bindings/identity/attachments，dispatch 把原先"不可用"按钮接到新接口（sessionConfig/model/mode、bindThreadSession、avatar/resetAvatar→PATCH /members/human、附件先上传再 attachmentIds、问卷/取消、stop/revive）；所有失败显示服务器错误文本、失败不更新本地状态；能力未建立（capabilities false）的控件保持禁用；会话命令（`/…`）与项目创建仍诚实显示不可用。`Tests/WebCanvas/transport.test.mjs` 14 项覆盖 fetch 路径/方法/请求体/诚实错误。
- **未改**：`pharos-api` 冻结契约枚举（扩展错误码 `unsupportedField`/`unsupportedOperation`/`threadBindingNotFound`/`attachmentNotFound`/`memberNotFound` 放在 HTTP 层 `pharos-http/src/error.rs`）、`pharos-protocol`/`pharos-replica`/`pharos-mesh`、agent-runtime、integrations/dsh-plugin-pharos、pharos-adapter-dsh（保持薄）、任何 `.swift`（本机无 Swift，未编译验证）。

**改了哪些 crate/文件**
- `rust/crates/pharos-hitl/`：`src/decision.rs`(新)、`src/approval_store.rs`、`src/lib.rs`（+8 tests）。
- `rust/crates/pharos-http/`：`src/error.rs`（扩展错误码枚举 + capability marker 映射）、`src/router.rs`（**新增路由集中在一个块** + openapi additive）、`src/web_routes.rs`(新，全部新 handler + 严格 base64)、`src/services/{persist,bindings,member_settings,attachments}.rs`(新持久化 stores)、`src/services/{mod,state,real,real_session,fake,session,approval}.rs`、`tests/web_endpoints.rs`(新，14 HTTP 集成测试)。
- `rust/crates/pharos-web/`：`src/lib.rs`（real/fake 两模式都接 file-backed bindings/member settings/avatars/attachments；损坏 store 启动硬错）、`tests/web_endpoints_e2e.rs`(新，6 真实 socket 测试)。
- `webui/`、`Sources/Pharos/Resources/WebCanvas/`、`Tests/WebCanvas/transport.test.mjs`。
- `docs/2026-11-11_web-endpoints-api.md`(新)、`docs/2026-11-11_wip-salvage-gaps.md`、`internal/evidence/2026-11-11_rust-web-endpoints.md`(新)、`internal/evidence/2026-11-11_rust-web-endpoints-verify.md`(新，独立复核)。

**新增测试**
- `pharos-hitl`：decision 模型（legacy 序列化兼容、cancelled 仅当被 offer、问卷 question/option/重复校验、tool permission 不接受 answers）+ store（cancelled 持久化与重放 first-wins、未 offer 的 cancelled 不消费、问卷答案随决定持久化且 revert 清除、旧 JSON 记录可加载）。
- `pharos-http`：三个持久化 store 的单测（原子写/重启/损坏硬错/校验/共享 blob、attachments 索引与 blob、成员设置校验、base64/SHA-256 向量）；`tests/web_endpoints.rs` 14 个（bindings CRUD+重启+400/404、thread members 合并与设置、config 读写+非法输入+404、unsupported 502 三件套、stop/revive、附件上传/内容/列表/引用/重启/超限/类型/404、成员设置+头像重启+校验+bindings、cancelled 持久化/幂等/未 offer 400、问卷答案持久化/重放/非法 question 400、派发失败 revert 可重试、legacy approval body + openapi 新路径）。
- `pharos-web`：`tests/web_endpoints_e2e.rs` 6 个真实 HTTP socket 测试（fake 组合全量 round-trip + 全量重启持久化、每个写 body 的 400、404 扩展码、诚实 502、bearer 矩阵 401/200+Bearer+?token=、real 模式 member+avatar 重启、损坏 member-settings.json 拒绝且坏字节保留）。
- 前端：`Tests/WebCanvas/transport.test.mjs` 14 passed。

**门禁结果（在 `rust/` 下，`CARGO_BUILD_JOBS=3`，源码 HEAD `f9d5a9d`；其后的提交只改 docs/internal evidence，独立复核已确认 `git diff --stat f9d5a9d..00dd178` 无 Rust/前端改动）**
- `cargo fmt --all -- --check` → **PASS**（exit 0，无输出）。
- `cargo clippy --workspace --all-targets -- -D warnings` → **PASS**（exit 0，0 warning）。
- `cargo test --workspace` → **PASS**（exit 0，**301 passed / 0 failed / 0 ignored，59 个 test suite**，doc-tests 0）。关键计数：pharos-http lib 79 + approvals_api 9 + real_state_http 4 + web_endpoints 14；pharos-web lib 31 + web_endpoints_e2e 6 + asset_sync 1；pharos-hitl lib 27；agent-runtime 32；adapter-codex 19+8；对比基线 222 tests → +79。
- 额外：`node --test Tests/WebCanvas/transport.test.mjs` → 14 passed / 0 failed；`diff -r webui Sources/Pharos/Resources/WebCanvas` → 无输出；`git status` 干净（handoff 提交前）。
- 独立复核（teammate `frontend-impl`，证据 `internal/evidence/2026-11-11_rust-web-endpoints-verify.md`）：三条门禁以相同数字复跑 PASS（301/59）；真实二进制 `pharos-web`（temp data dir + 随机高位端口 27138 + 随机 token，`--fake`，从未碰 3080/~/.dsh/ipc.sock/~/.gemini/user data）：**77/77 smoke 断言 PASS**，含 auth 矩阵、member/avatar 写入+重启后仍在、config/stop、附件上传/内容/列表/引用、binding+members、openapi 新路径、400 invalidRequest/404 sessionNotFound/404 attachmentNotFound、token 不入日志；事后进程 SIGTERM、端口关闭、temp dir 删除。
- Lead 另做一次独立真实二进制 smoke（同一模式，端口 39319）：全部通过，data dir 落盘文件为 `attachments/<id>`、`attachments/index.json`、`avatars/<sha256>.png`、`member-settings.json`、`thread-bindings.json`；重启后 member 设置/头像字节/binding/附件索引仍在（fake 会话 config 重播种为 safe，属 in-memory fake 的预期行为，已在文档说明）。

**没做/未验证**
- 真实 vendor 适配器（Codex/DSH 等）没有 config 写入、附件消息摄入、stop/revive 能力：真实后端这些路径是诚实的 502（只有显式 `--fake` 测试服务覆盖成功路径）。真实 vendor 的 Web 工作区 E2E 未跑（live-e2e 流负责真实 vendor）。
- 真实二进制下的"取消型审批 + 问卷答案"未做黑盒 smoke（`--fake` 没有通过 HTTP 播种 pending approval 的路径）；由已提交的 Rust HTTP/集成测试 + node 精确 body 测试覆盖，未声称是 smoke 结果。
- 会话**命令执行**（`/…`）与项目创建仍无端点，UI 继续禁用/诚实报不可用（本流任务清单未包含）。
- Swift ClientKit 未加新接口模型；本机 Linux 无 Swift 工具链，**Swift 未在 Linux 编译验证**（本流未触碰任何 `.swift` 文件）。
- 多文件附件上传中途失败会留下已上传的 blob/index 条目（没有附件 DELETE 端点），但消息发送不会被报告为成功；WebKit/macOS 真实渲染未验证（Linux 无 WebKit，仅 node vm 测试 + Rust HTTP/e2e）。
- 未 push、未合入/FF `integrate/mesh2-into-main`、未做 Phase E。

**需要人决定**
1. 是否/何时把 `rust/web-endpoints`（26 commits，HEAD `dac9f14`）合入 `integrate/mesh2-into-main` 或现有 `rust/integrate-dsh3`，以及何时 push（本流按规则未 push）。
2. 真实 vendor 适配器是否要补 config 写入 / 附件摄入 / stop-revive 能力（补了才不只是诚实 502）；若要补，建议在 adapter trait 上做 capability + 方法（本流刻意未改 adapter-codex，避免与 live-e2e 流冲突）。
3. 会话命令执行与项目创建 API 是否列入下一批（当前 UI 明确不可用）。
4. 绑定语义确认：PUT binding 允许"新成员名"（绑定即成员资格、无需先在 replica 中 join），这是 WIP UI "add existing local Session" 流程所需；若希望严格只允许既有 thread 成员，需要再提供一个 join/member-create API（contract 已写明当前语义）。
5. 多文件附件上传部分失败的清理策略：是否增加 DELETE attachment 端点/孤儿清理任务。
6. Swift ClientKit 新模型是否由后续有 macOS 的流补（本机无法编译验证）。
- 合并提示：`router.rs` 的新路由全部集中在一个 `// --- web-endpoints additions` 块（在 `.with_state` 之前）；cross-host-sessions 若按约定只在 router.rs 末尾最小追加，冲突面仅限该块附近。


**STATUS: INTEGRATE-DSH3-DONE — 287a136fb274f781baae11c8e7782b5eb4795058**
**分支/worktree**：`rust/integrate-dsh3`，worktree `/workspace/pharos-rust/2026-11-11_dsh-team/wt/integrate-dsh3`，base `integrate/mesh2-into-main @ 4e381a4`。未 push、未 force/rebase/amend、未改写任何已有提交；只 `git fetch` 过 remote refs。未触碰其它 worktree（hitl-persist / web-real-sessions / thread-autoreply 保持原 tip、未改）与主 checkout `/workspace/pharos-rust/2026-11-11_dsh-team/repo`。团队：Lead（本轮、merge1+集成测试+最终交接）、teammate `implementer`（merge2 + node/npm + 门禁）、teammate `verifier`（独立静态审查 + 全门禁复跑 + 真实二进制黑盒 smoke）。

**做了什么（三个已验收流的 merge captain，不加新功能）**
- `daa81f7`（本流起始已有）：`git merge --no-ff rust/hitl-persist @ 7f9c741`（pending approval 持久化 + `GET /api/v1/approvals` + WebCanvas 重连）。
- `7736b00`：`git merge --no-ff rust/web-real-sessions @ 8a0aeb9`。6 个冲突文件按语义合并，两边功能都保留：
  - **默认真实服务**：`pharos-web` 走新增 `real_app_state()`（= `pharos_http::services::build_real_app_state` + durable approvals），`--fake` 仍是显式 opt-in（启动 WARN）。
  - **任何模式都持久化 pending approvals**：`AppState` 始终带 `FileApprovalService(<data-dir>/pending-approvals.json)`（版本化 JSON，temp+fsync+rename 原子写，损坏/空文件/不支持 version 启动报错、绝不静默重置），且 `serve`/`serve_with_token`/`serve_ephemeral`/`serve_ephemeral_with_token` 全路径 `spawn_approval_tap()`。fake 模式 = 内存 fake Thread/Session + durable approvals（新语义，见"需要人决定"）。
  - **单一 `--data-dir`**：优先级 `--data-dir` > `PHAROS_WEB_DATA_DIR`（主 env）> `PHAROS_DATA_DIR`（兼容 hitl 流旧 env）> 平台默认（macOS `~/Library/Application Support/Pharos`；Linux `$XDG_DATA_HOME/pharos`，否则 `~/.local/share/pharos`）。Thread replica `mesh/replica.sqlite3`、goals `mesh/goals.sqlite3`、`pending-approvals.json` 全在同一 data dir。（历史 HITL 段写的 Linux `~/.local/state/pharos` 已被本合并取代。）
  - **router 两边追加路由全保留**：`POST /api/v1/threads`、`POST /api/v1/sessions`、`GET /api/v1/approvals?state=pending[&sessionId=]`、`POST /api/v1/sessions/{id}/approval` 的 durable 语义（幂等 first-wins、未知 404、session mismatch 400、过期 409、下游派发失败 revert 保持可重试）。token 鉴权在 `app_router_with_token` 包住整个 API router，故覆盖 approvals；`/health` 与静态 UI 免鉴权；非 loopback 无 token 拒绝启动（CLI + serve 双重校验）。
  - `Cargo.lock` 用 `cargo metadata` 重新生成依赖并集（未手工拼）；两侧测试文件全部保留。
- `adebf73`：合并专用集成测试（真实模式 pending approval 跨重启 + 非 loopback+token bearer），见下。
- `287a136`：`git merge --no-ff rust/thread-autoreply @ f158b8b`。唯一冲突 `docs/handoff.md`（两边都在顶部插 STATUS 段）→ 取 ours 保持本文件其余内容，该流原 handoff 段已在本文件下方**完整恢复**。`rust/Cargo.lock` 由 git 自动合并后被 `cargo check` 验证为正确解析（仅 pharos-agent-runtime 依赖表 +3 个 workspace path crate）；agent-runtime/adapter-codex/pharos-adapter-dsh/dsh 插件整段零改写进入。
- 3 个 merge commit（`daa81f7`/`7736b00`/`287a136`）均 `--no-ff` 双 parent；无 rebase/squash/amend；无 `.orig`/`.rej`/冲突标记残留。

**改了哪些 crate/文件**
- merge captain 手工解析：`rust/crates/pharos-http/{Cargo.toml,src/lib.rs,src/router.rs}`、`rust/crates/pharos-web/{Cargo.toml,src/lib.rs,src/main.rs}`（语义合并 + `real_app_state()`/data-dir env 优先级/`--fake` durable approvals/tap 全路径）、`rust/crates/pharos-web/tests/real_approvals.rs`（新）、`rust/Cargo.lock`、`docs/handoff.md`、`internal/evidence/2026-11-11_rust-integrate-dsh3-review.md`（verifier）。
- 合并带入（两流原始实现，未改写）：`pharos-http/src/services/{real,real_thread,real_session}.rs`、`pharos-web/src/auth.rs`、`pharos-hitl/src/approval_store.rs`、`pharos-http/src/{approvals.rs,services/approval.rs}`、`adapter-codex/src/{reply.rs,transport/recorded.rs}`、`agent-runtime/src/reply_sink.rs`、`integrations/dsh-plugin-pharos/index.test.mjs` 等。
- **未改任何 `.swift` 文件、未改 `Sources/Pharos/Resources/WebCanvas/`、未改 `webui/`**（`diff -r webui Sources/Pharos/Resources/WebCanvas` 无输出，`asset_sync` 绿）。**Swift 未在 Linux 编译验证**（本机无 Swift；本流未触碰 Swift，无需验证）。

**新增测试**
- `rust/crates/pharos-web/tests/real_approvals.rs`（2）：① 真实模式（非 `--fake`）`ApprovalRequired` → approval tap → 持久化 → HTTP snapshot → 停服 + 重启同 `--data-dir` 后 `GET /api/v1/approvals?state=pending` 仍在，且 `mesh/replica.sqlite3`+`mesh/goals.sqlite3`+`pending-approvals.json` 同目录；② 真 HTTP bind `0.0.0.0:<ephemeral>` + token → approvals snapshot/resolve 无 bearer 401、带 bearer 200、`/health` 200、`validate_bind` 无 token 拒绝。
- `rust/crates/pharos-web/src/lib.rs` 单测新增/加强：real/fake 两模式 durable approval 跨 reopen、corrupt store 在两种模式都报错且不覆盖坏字节、`PHAROS_WEB_DATA_DIR` 优先于 `PHAROS_DATA_DIR`、legacy env 兼容/空值报错、token 覆盖 approvals snapshot 路由。
- `rust/crates/pharos-http/src/router.rs`：保留两流全部测试并重建（14 个 router 测试：hitl 8 + web 2 + 既有 4）。
- 两流原有测试全部保留、未削弱（数字见下）。

**门禁结果（最终代码 HEAD `287a136`，`rust/` 下，`CARGO_BUILD_JOBS=3`）**
- `cargo fmt --all -- --check` → **PASS**（exit 0，无输出）。
- `cargo clippy --workspace --all-targets -- -D warnings` → **PASS**（exit 0，0 warning）。
- `cargo test --workspace` → **PASS**（exit 0，**222 passed / 0 failed / 0 ignored，57 suites** 含 doc-tests）。关键计数：pharos-http lib 31 + approvals_api 9 + real_state_http 4；pharos-web lib 28 + real_approvals 2 + approvals_persistence 2 + real_sessions 3 + acceptance 1 + asset_sync 1；agent-runtime 32；adapter-codex 19+8；pharos-hitl 19；pharos-adapter-dsh 9+1。
- 额外：`integrations/dsh-plugin-pharos` `npm test`/`node --test` → **18 passed**，`node --check index.mjs` OK；`Tests/WebCanvas` `node --test` → **3 passed**；`diff -r webui Sources/Pharos/Resources/WebCanvas` → exit 0 无输出；`git status` 干净。
- 独立 verifier（teammate）复跑三条门禁数字一致，并做真实二进制黑盒 smoke **39/39 PASS**（mktemp 临时 data dir + 随机高位端口）：真实模式 pending approval 跨重启仍在、无 fake 数据泄漏；`--fake` 模式 resolve 后磁盘 store 变 resolved 且重启仍 resolved；`0.0.0.0`+`--token` 的 401/200/?token=/health 矩阵、无 token 拒启动 exit 1、token 不入日志；损坏 store 启动 exit 1 且坏字节保留；未碰真实房间/3080/ipc.sock/~/.gemini。证据：`internal/evidence/2026-11-11_rust-integrate-dsh3-review.md`；merge2 证据：`internal/evidence/2026-11-11_rust-integrate-dsh3-autoreply-merge.md`。

**没做/未验证**
- 真实 vendor E2E 未跑（继承两流，非本次合并回归）：真实 Codex app-server `thread/read` 的 `phase="final_answer"`、真实 DSH Host + Rust runtime 往返、`~/personal/pharos-msg-test` 真实消息、Codex worker crash 恢复 at-least-once 重投均未验证；未碰 3080 dsh Host/ipc.sock/~/.gemini。
- 默认真实模式 + `--session-adapter none` 时没有 live Session adapter：session 列表为空、`POST /api/v1/sessions/{id}/approval` 会先落 durable decision 再被下游 502 `operationFailed` 回滚（approval 仍 pending 可重试）——这是 hitl"失败不吞审批"与 web"不伪造成功"的既定诚实语义，不是回归；因此默认真实二进制下 approvals 无法真正 resolve 直到配置 live adapter（需要人决定是否例外）。
- WebKit/浏览器 UI 未在真实 macOS 验证（Linux 无 Swift/WebKit）；只有 node `vm` 单测 + Rust HTTP/e2e。
- `webui`/WebCanvas 的 `transport.js` 不支持 bearer token（token 模式浏览器是 API-only）；共享 SQLite 无 WAL/busy_timeout；reply 重试可能重复 1 帧 WS（均为继承的非阻塞项）。
- Swift ClientKit 的 pending-approval snapshot 请求/模型仍未实现（Linux 无法编译验证 Swift，按"不确定不改 Swift"保留缺口）。
- 未 push、未合入/FF `integrate/mesh2-into-main`、未做 Phase E、未改 `pharos-api` 冻结契约（新路由未追加进 OpenAPI stub，approvals 路由除外）。

**需要人决定**
1. 是否把 `rust/integrate-dsh3` 提升进 `integrate/mesh2-into-main`（FF/merge + 何时 push）；本流按规则未 push。
2. `--fake` 语义变更：现在 fake 模式也持久化 pending approvals（Thread/Session 仍是内存 fake），与旧"`--fake` 不落盘"描述不同；是否接受并在 UI/文档中固定。
3. `PHAROS_DATA_DIR` 保留为 legacy 兼容还是废弃；Host canonical data-dir 根命名仍待统一（RFC-007 Q1/Q8）。
4. `--session-adapter` 默认 `none` 还是检测到 codex CLI 后默认 `codex`；这决定默认真实二进制能否 resolve approvals。
5. DSH 助手回复写回 Thread 的路径（canonical 插件 mesh 工具 vs Rust `thread.reply` RPC）；真实 Codex 0.167 若无 `final_answer` phase 是否允许"匹配 turn 的最后一条非空 agentMessage"兜底（thread-autoreply 流遗留，见下）。


**STATUS: THREAD-AUTOREPLY-DONE — 7655e95**
**Thread 自动回复（Codex + DSH）2026-11-11**：worktree `/workspace/pharos-rust/2026-11-11_dsh-team/wt/thread-autoreply`，分支 `rust/thread-autoreply`（base `integrate/mesh2-into-main` @ `4e381a4`）。共 10 个提交，未 push、未 rebase/amend/force、未改历史。

**做了什么（投递 poll → 代理 followup → 最终答案 → 关联回复 → ack 闭环）**
- **Rust agent-runtime 投递路由**（f7306f8）：`delivery.submit-member` 只投给**唯一存活**候选——conversation `online` + 非 archived + state 观察值新鲜（-5..=45s），且其 driver 声明 `delivery.poll` 且心跳新鲜（-5..=15s）；runtime 自带的 managed Codex（`codex:app-server`）不需要插件心跳。0 个候选 → `No managed conversation registered for member: …`；>1 个 → `-32602 Multiple active conversations registered for member: …`（绝不乱投/猜）。`idempotencyKey` 复用必须同 member+conversation+payload，否则 `-32602`。新增只读 RPC `delivery.inspect-members` / `delivery.inspect-dsh-binding` / `delivery.inspect-dsh-bindings`（300/512 上限校验，不建投递不落盘），`runtime.hello` capabilities 增加 `delivery-inspect-v1`、`dsh-binding-inspect-v1`、`dsh-binding-batch-inspect-v1`。
- **Codex 最终答案 → 关联回复 → ack**（5e5f637 + 8f7f7cb/42064ed/87e9c98 加固）：把 `turn/start` 返回的 turn id 记录进投递（`turnId`），投递 `consumed` 后按 envelope 的 `room`/`messageID` + `targetMemberID` 布置 reply job；缺失则显式 `missing-turn-id`/`missing-member-id`/`missing-correlation`，绝不静默当成功。adapter worker 轮询 `thread/read(includeTurns=true)`，用 `pharos-codex-adapter::inspect_turn_reply` 只取**该 turn** 且 `status=completed` 的 `phase="final_answer"` 文本（commentary/别的 turn 永不泄漏）；成功时经 `HostReplySink` 的生产实现 `ThreadStoreReplySink` 调用 `pharos-thread` 的 `replyOnce`（room + member=`targetMemberID` + messageID=原消息）写回 Thread，回复 ID 由 (scope,room,member,原消息) 确定，崩溃重试返回同一 ID → 不会重复回复；`reply_state` 记 `posted`/`turn-failed`/`no-final-answer`/`answer-too-large`/`failed`/`turn-timeout`，sink 失败最多 5 次、未终结 turn 的等待预算 300 次轮询（约 10 分钟）后显式 `turn-timeout`，只有回复真正落盘才 `posted`。
- **幂等/顺序加固**（8f7f7cb、42064ed）：`delivery.ack` 重复同状态是**真 no-op**（不重复发事件、不重复回复），且只允许状态前移——misordered/重复 consumer 不能把已 `consumed` 的投递退回 `injected` 让 Codex worker 重投；公开 `delivery.submit` 不能伪造 `targetMemberID`（必须是对应 conversation 的唯一存活路由）、archived conversation 不接受投递、幂等键复用校验 conversation/payload；`ready_codex_delivery_index` 不再向 archived Codex 会话注入；turn id 提取走受测 helper。
- **adapter-codex 最终答案选择**（9f8bc20、e7b7d04）：新增 `src/reply.rs`（`ReplyInspection`、`inspect_turn_reply`、`final_answer_text`、`assistant_reply_text`）；`parse_turns`/`DeliveryWorker::dispatch` 不再拼接所有 agentMessage，改为“匹配 turn 的 `final_answer`，否则最后一条非空 agentMessage（legacy 无 phase）”，completed 无文本 → Failed、failed/interrupted → Failed（绝不 Completed）；新增 `CodexTransport::Recorded(RecordedAppServer)` 假 transport、`RecordedRequest`、`CodexSessionAdapter::from_transport`。
- **DSH plugin 闭环对齐 canonical 427db7d（PIT-DS-05）**（790892d、7655e95）：`integrations/dsh-plugin-pharos` 循环改为 `delivery.poll` → ack `injected`（失败吞掉）→ `agent.followup(buildUserMessage(...))` → ack `consumed`；followup 抛错 → ack `failed`+detail；consumed-ack 在 followup 成功后抛错 → 再 ack `failed`（detail `followup accepted but consumed ack failed: …`），failed-ack 自身失败只记录不中断其余投递；archived session → failed 且不 followup；`consumed` 只表示 DSH durable inbox 接管、不宣称助手回合完成。移除 `@deepseek-ai/dsh-llm` 顶层依赖（本地 `buildUserMessage`，零依赖可测）；driver capabilities 增加 `delivery.poll` + `mesh.reply-once-v1`（Rust 侧 liveness/reply-capable 检查依赖它）；`package.json` 加 `node --test`。
- **pharos-adapter-dsh 保持薄、不伪造**（cbb7425）：新增 `RUNTIME_DRIVER_CAPABILITIES`（`delivery.poll`/`mesh.reply-once-v1`）并用于 manifest；文档明确 adapter 只报告观测到的 terminal turn、不自己发 Thread 回复、不存在 fabricated `delivered`；测试保证 failure/interrupt 结果永不 Completed 且无 assistant_text。

**改了哪些 crate / 文件**
- `rust/crates/agent-runtime/`：`src/main.rs`（投递路由 + inspection + ack 顺序 + Codex reply loop + worker 接线）、新增 `src/reply_sink.rs`（`HostReplySink`/`ThreadStoreReplySink`/确定性 nick）、`Cargo.toml`（+pharos-api/pharos-thread/pharos-codex-adapter）；`rust/Cargo.lock`。
- `rust/crates/adapter-codex/src/{reply.rs(new), lib.rs, codex.rs, delivery.rs, transport/mod.rs, transport/recorded.rs(new)}`、`tests/recorded_dispatch.rs`(new)。
- `rust/crates/pharos-adapter-dsh/src/{adapter.rs, lib.rs}`。
- `integrations/dsh-plugin-pharos/{index.mjs, index.test.mjs(new), package.json, package-lock.json, README.md}`。
- 未改 `pharos-web`/`pharos-http` services、未改 `pharos-hitl`、未改 `pharos-thread` 源码、未改 Swift/WebCanvas。

**新增测试（cargo test / node --test）**
- `agent-runtime`：32 个 unit（新增 21：liveness/ambiguity/idempotency/inspection、ack no-op+顺序、reply correlation/restart、sink 重试、等待超时、大答案、direct-submit 防伪造、turn id 提取）；均用 /tmp 临时 registry + 录制 `thread/read` JSON + `RecordingReplySink`/内存 SqliteThreadStore，不调真实 Codex。
- `adapter-codex`：lib 19（新增 14）+ `tests/recorded_dispatch.rs` 8（final-answer-only Completed、failed/interrupted→Failed、无文本→Failed、commentary-only→Failed、legacy phase-less→Completed、turn/start 错误→Failed 等），全部假 transport/录制事件。
- `pharos-adapter-dsh`：lib 9（新增 2：runtime capability 契约、failure 不伪造 Completed）+ 1 integration。
- `integrations/dsh-plugin-pharos`：`node --test` 18/18（新套件：4 阶段 ack 顺序/载荷、followup 抛错→failed、consumed-ack 抛错→failed、failed-ack 再失败被捕获、archived、空 poll、payload 渲染、buildUserMessage 形状、capabilities、name/inject/apply 保持）。

**门禁（在 rust/ 下，最终代码提交 7655e95）**
- `cargo fmt --all -- --check` → exit 0。
- `CARGO_BUILD_JOBS=3 cargo clippy --workspace --all-targets -- -D warnings` → exit 0，无 warning。
- `CARGO_BUILD_JOBS=3 cargo test --workspace` → exit 0；52 个 test suite 全绿，共 **135** 个测试（其中 agent-runtime 32、adapter-codex 19+8、pharos-adapter-dsh 9+1）。
- `cd integrations/dsh-plugin-pharos && node --test` / `npm test` → **18 passed / 0 failed**；`node --check index.mjs` OK。
- `git status` 干净（本 handoff 提交前）。

**没做 / 没验证**
- 未跑真实 Codex app-server E2E（真实 0.167 的 `thread/read` 是否带 `phase="final_answer"` 未验证；env-gated product test 未执行）。若 0.167 不带 phase，本实现会诚实落到 `no-final-answer`，不会乱发。
- 未跑真实 DSH Host + Rust agent-runtime 端到端（插件测试为 fake agent/RPC shim）；未在 `~/personal/pharos-msg-test` 做真实消息投递/回复；未碰 3080 Host/ipc.sock/~/.gemini。
- 应用启动器（Swift/GUI 或 supervisor）如何传 `--thread-data-dir`/`PHAROS_THREAD_DATA_DIR`、是否与 GUI/Host 共用同一 `replica.sqlite3` 未验证；默认 `$HOME/Library/Application Support/Pharos/Mesh`。
- DSH 助手回复的实际写回路径（canonical 0.2.0 插件的 `pharos_mesh_send` 工具）不在本流；仓库内插件是 runtime-intake 包装，只负责 poll→followup→ack，助手正文回复需另接（见下）。
- 未验证真实 Codex worker 崩溃恢复的 at-least-once 重投（turn/start `clientUserMessageId` 去重依赖 vendor 行为）；重复**回复**不会发生（replyOnce 稳定 ID），但 prompt 可能重投一次。
- `delivery.submit` 仍是低层 API（本地 socket 0600，且 Peer allowlist 只放 `delivery.submit-member`），现已加 target/archived/幂等校验；如需彻底关闭可再加开关。
- 未改 Swift/WebCanvas，无需 Swift 编译验证（本机 Linux 也无法编译 Swift）。

**需要人决定**
1. daemon 的 Thread 数据目录权威来源与启动参数（谁在 supervisor 里传 `--thread-data-dir`，是否与 GUI/Host 共用同一 `replica.sqlite3`）。
2. DSH 助手回复写回 Thread 的路径：接 canonical 插件的 mesh 工具，还是给 Rust runtime 新增 `thread.reply` RPC 由插件调用（本流只做投递 intake 闭环）。
3. 真实 Codex 0.167 若确实不带 `phase`，是否允许“匹配 turn 的最后一条非空 agentMessage”作为兜底（当前严格 final_answer，宁可 `no-final-answer` 也不乱发）。
4. `delivery.submit` 是保留为可信本地 API（已加校验）还是彻底移除，以收窄本地 socket 攻击面。

**STATUS: WEB-REAL-SESSIONS-DONE — 494435f**
**Stream:** `rust/web-real-sessions`，worktree `/workspace/pharos-rust/2026-11-11_dsh-team/wt/web-real-sessions`，分支 `rust/web-real-sessions`（base `4e381a4` = integrate/mesh2-into-main）。未 push。未改 Swift / `Sources/Pharos/Resources/WebCanvas/` / `webui/` / `Package.swift`（本流无需 WebCanvas 变更，asset_sync 逐字节检查保持绿；Swift 未在 Linux 编译，因未触碰无需验证）。

**做了什么（真实 Session/Thread，不再假数据）**：
- `pharos-web` 默认改为启动真实 S1/S2 后端（`pharos_http::services::build_real_app_state`）；假服务只在 `--fake`（显式参数，启动 WARN "data will NOT persist"）或测试中使用。
- `RealThreadService`：真实 `pharos-thread` SQLite replica（`<data-dir>/mesh/replica.sqlite3`，PHASE0 rooms/memberships/messages）支撑 thread 列表/详情/messages/send/replyOnce/create；`ThreadError`→冻结的 `PharosApiError`；写路径向 WS `EventBus` 发 `threadMessageReceived`；store 的数字 epoch 时间戳在 HTTP 层归一化成 RFC3339（否则浏览器 `new Date()` 显示 Invalid Date，reviewer MEDIUM-1 已修复）；send 不会隐式建 thread（缺 thread 返回 404）。
- `RealSessionService`：包 `pharos-session::AdapterSessionService`。`--session-adapter none`（默认）不 spawn vendor：sessions 列表为空、get/history 404、send/steer/approval/create 明确返回 `operationFailed`（message 含 `--session-adapter`，绝不伪造 turn/session）；`--session-adapter codex` 才接 live Codex adapter。progress 读持久化 `pharos-goals`（`<data-dir>/mesh/goals.sqlite3`），session 事件桥接到 WS bus；projects/inventory 不发明数据（projects 空列表，inventory 只报真实 sessions + configured/unavailable agents）。
- CLI/ENV：`--data-dir`/`PHAROS_WEB_DATA_DIR`（默认 macOS `~/Library/Application Support/Pharos`，Linux `$XDG_DATA_HOME/pharos` 或 `~/.local/share/pharos`；测试用临时目录）、`--addr` 默认 `127.0.0.1:8787`、`--token`/`PHAROS_WEB_TOKEN`、`--session-adapter`/`PHAROS_WEB_SESSION_ADAPTER`（none|codex）、`--fake`。非 loopback 绑定（含 0.0.0.0/::）无 token 拒绝启动（`validate_bind` 在 CLI 和 `serve_with_token` 双重校验）；有 token 时 API 要求 `Authorization: Bearer` 或 `?token=`（常量时间比较、token Debug 脱敏、不入日志；`/health` 与静态 UI 免鉴权）。
- router 只做最小追加：`POST /api/v1/threads`（`{threadId, memberIds}` → ThreadSummary，幂等，memberIds 先校验后建 room）、`POST /api/v1/sessions`（`{workspacePath, mode}`，无 live adapter 时明确 502）；现有路由形状未改。HITL 审批持久化（hitl-persist 流）与 Codex/dsh 自动回复（thread-autoreply 流）未触碰。
- 数据目录与 CLI/daemon 共享：web `--data-dir` 是 Host 根（DB 在 `mesh/replica.sqlite3`）；`pharos-cli --data-dir <同一 Host 根>` 会解析到同一 `mesh/replica.sqlite3`（macOS 上 CLI 默认 `.../Pharos/Mesh` 与 web 的 `.../Pharos/mesh` 大小写不敏感即同一目录）。

**改动 crate/文件**：`rust/crates/pharos-http/`（`Cargo.toml`、`src/lib.rs`、`src/router.rs`、`src/services/{mod,thread,session,fake,real,real_thread,real_session}.rs`、`tests/real_state_http.rs`）；`rust/crates/pharos-web/`（`Cargo.toml`、`src/{auth,lib,main}.rs`、`tests/real_sessions.rs`）；`rust/Cargo.lock`；`internal/evidence/2026-11-11_rust-web-real-sessions-review.md`（独立 reviewer 证据）；`docs/handoff.md`（本段）。提交序列：`98a241f`（真实服务+builder）、`788c2c8`（HTTP 真实集成测试）、`94177a7`（auth）、`3fc4826`（lib token/serve/validate_bind/data-dir）、`6e3de9c`（main 默认 real）、`dddcc00`（real_sessions 集成测试）、`494435f`（reviewer 发现项修复），最后为本 handoff/证据提交。

**新增测试**：`pharos-http` 24（20 lib 单测：real thread 建/发/replyOnce/幂等/时间戳/RFC3339/坏 memberId 不落半成品、真实 session live+unconfigured 诚实错误、builder 持久化、fake 新路由；4 `tests/real_state_http.rs` 真实 state HTTP 集成：create→send→reply→GET、重建 state 后持久化、无假 session、真实 errors）；`pharos-web` 27（22 lib：auth 401/200 header+query、常量时间、Debug 脱敏、validate_bind、default_data_dir；+既有 acceptance 1、asset_sync 1；3 `tests/real_sessions.rs`：真实服务无假数据、诚实 session 错误、thread 创建→消息→grokbot reply→abort+重建 AppState 重启后数据仍在、token 真实 HTTP 矩阵）。workspace 合计 135 passed / 0 failed / 0 ignored。

**门禁（`rust/`，源码 HEAD `494435f`，CARGO_BUILD_JOBS=3）**：
- `cargo fmt --all -- --check` → exit 0（无输出）。
- `cargo clippy --workspace --all-targets -- -D warnings` → exit 0，无 warning。
- `cargo test --workspace` → exit 0，**135 passed / 0 failed / 0 ignored**（doc-tests 0）。
- 独立 reviewer（teammate `reviewer`）在 `dddcc00` 另跑三条门禁全绿（131 passed），并在 `dddcc00` 与 `494435f` 用**真实二进制** E2E smoke 验证：默认无假数据（threads/sessions []、fake ids 404）、HTTP create thread→send→reply→持久化、kill+重启同一 `--data-dir` 数据仍在、`--fake` 显式显示假数据并 WARN、`0.0.0.0` 无 token exit 1 明确拒绝、有 token 401/200（Bearer + `?token=`）、`/health`+静态资源免鉴权、token 未入日志、默认 XDG data dir 生成 `mesh/{replica,goals}.sqlite3`。证据：`internal/evidence/2026-11-11_rust-web-real-sessions-review.md`（§1–§7）。

**没做/未验证**：
- live Codex 路径（`--session-adapter codex`）未在 CI/测试里连真实 vendor：测试用 fake `SessionAdapter` 验证包装层与 HTTP 路由，binary smoke 只覆盖默认 `none`；启动时 `CodexSessionAdapter::connect_stdio()` 的 live 行为未验证。
- session 列表/元数据不持久化（`AdapterSessionService` 内存态，重启后 live session 列表丢失；durable session registry 属 S2/后续）。
- HITL 审批持久化/快照（hitl-persist 流）、Codex/dsh Thread 自动回复（thread-autoreply 流）不在本流。
- projects 真实 registry 未接线（`GET /api/v1/projects` 返回 []，不伪造）；inventory 只反映已配置 adapter。
- `openapi.json` stub 未追加 `POST /threads`、`POST /sessions`（未改冻结的 `pharos-api` 以避免跨流冲突）。
- 浏览器 UI：`webui/transport.js` 不支持 token、也没有创建 Thread 的入口（thread 需经 HTTP/CLI 创建）；非 loopback + token 模式目前是 API-only，浏览器会被 401。
- WS 升级的 `?token=` 鉴权路径未被 cargo 测试覆盖（HTTP query token 已覆盖；reviewer smoke 覆盖 HTTP 侧）。
- reviewer 记录的非阻塞遗留：SQLite store 无 WAL/busy_timeout（pharos-thread/pharos-goals 既有，S1/S2 owner 未改，共享 data dir 与 daemon 并发时可能 SQLITE_BUSY）；live codex 模式 session 调用会阻塞 tokio worker 至 180s（持 std Mutex）；reply 重试会重复广播一次 WS 帧（UI refresh 去重，无害）；`--fake` 仍会先解析默认 data dir（只影响 warning）。

**需要人决定**：
1. `pharos-web` 默认 `--session-adapter`：保持 `none`（不 spawn vendor 进程）还是检测到 codex CLI 时默认 `codex`？当前 opt-in。
2. Host canonical data-dir 根/命名：web 用 `<root>/mesh/replica.sqlite3`，CLI 默认 macOS `.../Pharos/Mesh`；是否统一（RFC-007 Q1/Q8 相关）并让 daemon/CLI/web 共用。
3. 非 loopback 的浏览器 UI 鉴权：在 `webui/`+`Sources/Pharos/Resources/WebCanvas/` 注入 token（必须两份同步、Swift 无法在 Linux 验证）还是明确 API-only。
4. 两条 append-only create 路由是否纳入 `pharos-api` OpenAPI stub / 是否需要 CONTRACTS_VERSION bump（本流未改冻结契约）。
5. 是否由 S1/S2 owner 补 SQLite WAL/busy_timeout 与 durable session registry。

# 活跃任务交接

**STATUS: HITL-PERSIST-DONE — 6f2a7c8**

**分支/worktree**：`rust/hitl-persist`，worktree `/workspace/pharos-rust/2026-11-11_dsh-team/wt/hitl-persist`，base `integrate/mesh2-into-main @ 4e381a4`。未 push、未 force/rebase、未改写历史；未触碰其它 worktree 或主 checkout。前端由 teammate `frontend` 完成（`c65e076`），独立验证由 teammate `verifier` 完成（`6f2a7c8`）；本段由 Lead 汇总。

**做了什么**
- **持久化待审批（pharos-hitl）**：新增 `approval_store`（`PendingApprovalStore` 文件存储 + 可复用内存 `ApprovalRegistry`）。版本化 JSON envelope；原子写（temp + `sync_all` + rename）；文件损坏/空文件/不支持的 version 报错，绝不静默重置。`record` 为幂等 upsert：保留原 `createdAt`、不复活已决定审批、过期后可被重新宣告并重开 45m 窗口。`resolve` 幂等 first-wins：第一个 decision 生效，后续（即使 decision 不同）返回 `AlreadyResolved` 与原 decision；45m 超时（可注入 `WallClock`，测试无需 sleep）；prune 把过期 pending 标记 expired 并清理 24h 前的已决/过期记录；`withdraw`；`revert_resolution` 用于下游派发失败时撤销 durable decision 保持可重试。
- **API（只追加，不改现有路由形状）**：新增 `GET /api/v1/approvals?state=pending[&sessionId=]` → `{"approvals":[{approvalId,sessionId,kind,availableChoices?,state:"pending",createdAt,expiresAt}]}`；`state` 仅支持 `pending`，其它值 400 `invalidRequest`；`sessionId` 可选过滤；`pharos-http` 的 OpenAPI stub 追加该 path（未改 `pharos-api` 冻结契约）。`POST /api/v1/sessions/{id}/approval` 现在更新持久状态：首次 200 `{ok,approvalId,state:"resolved",decision,alreadyResolved:false}`，重复/并发 200 `alreadyResolved:true` 且 decision 仍为第一个（exactly-once）；未知 id 404 `approvalNotFound`；session 不匹配 400 `invalidRequest`；已过期 409 `conflict`；下游 session/adapter 派发失败时先 `revert_decision` 回滚再返回原错误（失败不会静默吞掉审批，重试可再次派发）。
- **事件接线（pharos-http）**：`AppState` 新增 `approvals: Arc<dyn ApprovalService>`（`AppState::new` 保持原签名并默认内存实现，新增 `with_approvals`）+ `spawn_approval_tap()`：订阅 `EventBus`，把 `ApprovalRequired/ApprovalUpdated/ApprovalResolved/ApprovalWithdrawn` 落盘。这样刷新/WS 重连可从快照恢复；`approvalResolved`/`ApprovalWithdrawn` 事件（无论来自 HTTP 还是 adapter）都会更新/删除持久状态。
- **服务端接线（pharos-web）**：解析 data dir（`--data-dir` / `PHAROS_DATA_DIR` / macOS `Application Support/Pharos` / Linux `~/.local/state/pharos`）；`persistent_app_state()` 打开 `<data-dir>/pending-approvals.json`，打不开或损坏时进程启动报错（不静默退化成内存）；`serve`/`serve_ephemeral` 启动 approval tap；`pharos-web` 二进制改用持久 state，`fake_app_state()` 仍为内存（S4 acceptance 用）。
- **前端（frontend）**：`webui/transport.js` 与 `Sources/Pharos/Resources/WebCanvas/transport.js` 字节一致同步修改：`start()` 时和每次 WS `onopen` 拉 `/api/v1/approvals?state=pending` 快照；按 `approvalId` 去重 upsert live 事件（`approvalRequired/Updated`），`approvalWithdrawn/Resolved` 移除；按当前 selection + `createdAt` 选最早 pending 展示；WS 断线 200ms→10s 指数退避自动重连（generation counter 忽略旧 socket），不再要求 reload；resolve 成功后本地移除。原生 WebKit bridge 路径保持只转发、不改。
- **文档**：本段 + `docs/2026-11-11_wip-salvage-gaps.md` 末尾更新（原“没有 current-approval snapshot / 断线需 reload”描述对 pending approvals 已过期）。

**改了哪些 crate/文件**
- `rust/crates/pharos-hitl/`：`src/approval_store.rs`（新）、`src/lib.rs`。
- `rust/crates/pharos-http/`：`src/approvals.rs`（新 handler + `APPROVALS_ROUTE`）、`src/services/approval.rs`（新 service/DTO/文件+内存实现）、`src/services/mod.rs`、`src/state.rs`、`src/router.rs`、`src/lib.rs`、`Cargo.toml`；`tests/approvals_api.rs`（新，verifier）。
- `rust/crates/pharos-web/`：`src/lib.rs`、`src/main.rs`、`tests/approvals_persistence.rs`（新 e2e）、`Cargo.toml`；`rust/Cargo.lock`。
- `webui/transport.js`、`Sources/Pharos/Resources/WebCanvas/transport.js`（字节一致）、`Tests/WebCanvas/transport.test.mjs`。
- `docs/2026-11-11_wip-salvage-gaps.md`、`docs/handoff.md`。
- 未改任何 `.swift` 文件。**Swift 未在 Linux 编译验证**；WebCanvas 资源仅随 HTTP 版同步修改，`asset_sync` 测试通过。

**新增测试**
- `pharos-hitl` approval_store 单元 11：reopen 持久化、幂等 resolve 保留首个 decision、resolved 不被晚到事件复活、45m 过期、过期重开窗口、损坏/不支持版本/空文件报错、withdraw、24h prune、session 过滤、失败派发 revert 可重试。
- `pharos-http` 单元：`services::approval` 3（内存实现快照/会话过滤/幂等、apply_event、过期 conflict）+ `router` 10（快照+session 过滤、state=resolved 400、event tap 落盘、resolve 幂等并移出快照、未知 404、session mismatch 400、expired 409、失败派发 retryable、既有 health/openapi/threads 回归）。
- `pharos-http/tests/approvals_api.rs`（verifier 独立黑盒）9：快照形状/排序/session 过滤、tap（Required/Updated/Resolved-unknown/Withdrawn）、AppState 重启同文件仍列出且校验 on-disk versioned JSON、幂等 first-wins + 不重复派发 + 晚到事件不复活、错误契约（404/400/422）、45m 边界 409、并发决定 exactly-once、既有路由/OpenAPI 保持、失败派发 pending+durable+真重试。
- `pharos-web/tests/approvals_persistence.rs` 2（e2e）：event tap → GET snapshot → abort server → 新 AppState 同 data dir → 仍列出 → POST 决定一次 → 快照空 → 再重启仍 durable resolved；corrupt store 启动失败且不覆盖坏文件。原 acceptance + `asset_sync` 保持通过。
- `Tests/WebCanvas/transport.test.mjs` 3：page-load 快照恢复、同 id 事件去重更新、resolved 移除、resolve POST body `{approvalId,decision}`、WS 重连后重新拉快照。

**门禁结果（最终提交 6f2a7c8，`rust/` 下，`CARGO_BUILD_JOBS=3`）**
- `cargo fmt --all -- --check`：PASS。
- `cargo clippy --workspace --all-targets -- -D warnings`：PASS。
- `cargo test --workspace`：PASS — 124 passed / 0 failed / 0 ignored（53 suites，含 doc-tests；本流新增 34 个 cargo 测试，JS 测试 2→3）。
- `node --test Tests/WebCanvas/transport.test.mjs`：PASS 3/3；`diff -r webui Sources/Pharos/Resources/WebCanvas` 无差异（`asset_sync` 亦通过）。
- `git status`：干净。

**没做/未验证**
- 真实浏览器/WebKit 交互未跑（Linux 无 Swift/WebKit）：前端只有 node `vm` 单测 + Rust HTTP/e2e 集成测试；WebCanvas 资源改动未在 macOS 编译验证（**Swift 未在 Linux 编译验证**）。
- Swift ClientKit 的 “fetching the current approval snapshot” 未实现：本机无法编译验证，按“不确定就别改 Swift”保留缺口；其快照模型/请求仍需 S6 在 macOS 上实现。
- 未接真实 adapter/session HITL E2E：`pharos-web` 仍用 fake S1/S2 服务；approval tap 按真实 `ClientEvent` 形状接线，但真实 Codex/DSH HITL 往返未跑。未做真实消息/真实房间测试。
- 存储为单写者假设：无跨进程文件锁（两个进程同时写同一 store 会 last-writer-wins 丢记录）、无父目录 fsync（极端断电可能丢最后一次写，但不会读到半截文件）；`state` 只支持 `pending` 查询。
- 未 push、未合入 `integrate/mesh2-into-main`（按规则）。

**需要人决定**
- 合并冲突面：本流与 `web-real-sessions` 流都会改 `pharos-http/src/state.rs`、`services/mod.rs`、`router.rs`、`pharos-web/src/*`；合并 captain 需按并集处理（本分支未 push，也未 FF 主分支）。
- 行为变更：`POST /api/v1/sessions/{id}/approval` 对未知 approval id 现在返回 404 `approvalNotFound`（此前由 fake session service 直接返回 ok）。真实 session service 接入后若存在“审批事件未持久化但可决定”的旧路径，需要决定是维持 404（诚实）还是增加委托式回退。
- 是否在 macOS 上补 Swift ClientKit 的 pending-approval snapshot 请求/模型，并把 `pharos-web` 从 fake S1/S2 切到真实服务（这决定该特性能否在真实产品路径上生效）。

**STATUS: PHASE-E-DONE — see docs/handoff-phase-e.md**
**Phase E（merge captain / CLI agent）**：worktree `~/personal/pharos-wt/_phase-e` 分支 `rust/phase-e`（base `379febb` = integrate-b3 tip）。`git rm` 删除 Swift Mesh/Runtime/CodexAdapter/AgentCore/CSQLite 及 desktop-mesh 路径；client-only Package.swift。Gates 与证据见 `docs/handoff-phase-e.md`。未 push；未 FF `integrate/mesh2-into-main`。


**STATUS: RUST-B3-MERGED — 648c22892a52a27812de44f75b306d5fd23b4234**
**Batch 3 merge（merge captain）**：worktree `~/personal/pharos-wt/_merge-b3` 分支 `rust/integrate-b3`（base `9b5434f` = B2 tip）。`--no-ff` 合入 `rust/swift-client` @ `715c687`。保留 wiring-local：`Package.swift` `PharosClientKitTests` + `ContentView` backend flag。Captain 另提交：`webui/dsh-stream.js` ← WebCanvas fetch 版。Gates：`cargo fmt --check` / `clippy -D warnings` / `test --workspace` 绿；`swift build --target PharosClientKitTests` 绿；`ArchitectureBoundaryClientKitTests` 3/3 绿。**Full `Pharos` app target still blocked** by missing committed Mesh files (`HostSessionSchema.swift` / MeshCore sessionRPC) — not copied from dirty main checkout. 未触碰 `integrate/mesh2-into-main` WIP；未做 Phase E；未 push。

**Branch tip:** tip of `rust/integrate-b3` (includes handoff).

**STATUS: RUST-B2-MERGED — 144cab6e3485d47bca45c2514a388b7167e03b71**
**Branch tip:** `rust/integrate-b2` (includes handoff/fmt; run `git rev-parse rust/integrate-b2`).

**Batch 2 merge（merge captain）**：worktree `~/personal/pharos-wt/_merge-b2` 分支 `rust/integrate-b2`（base `rust/integrate-b1` @ `6a1c455`）。`--no-ff` 顺序：S5b `rust/adapter-dsh` → S5c `rust/adapter-agy` → S5d `rust/adapter-cursor` → S2 `rust/session-hitl`。Captain 对 `rust/Cargo.toml` members/deps 做并集（冲突于 S5c/S5d/S2）；`agent-runtime` 注册 `session_service`/`hitl_bridge` mods。每步 `cargo check --workspace` + `cargo test --workspace` 绿；合入后 `cargo fmt` + `cargo clippy --workspace --all-targets -- -D warnings` 绿。未 FF `integrate/mesh2-into-main`、未 stash 主 checkout WIP、未 push。

**STATUS: RUST-B1-MERGED — 09192f0213b3977c0a68ec00368446045284eea1**
**Batch 1 merge（merge captain）**：在 worktree `~/personal/pharos-wt/_merge-b1` 分支 `rust/integrate-b1` 按 RFC-007 §6.1 顺序 `--no-ff`：S3 `rust/mesh-iroh` → S1 `rust/cli-thread` → S5a `rust/adapter-codex` → S4 `rust/web-api`。Captain 合并 `rust/Cargo.toml` members/deps 并集；`agent-runtime` 注册 `mesh_bridge`/`replica_bridge`/`thread_service`/`grokbot_bridge` mods；S4 按 wiring Option B 保留 `pharos-web` 旁路二进制。每步后 `cargo check --workspace` + `cargo test --workspace` 绿；全部合入后 `cargo clippy --workspace --all-targets -- -D warnings` 绿。未 push。

**Batch 2 start here:** tip of branch `rust/integrate-b1` (includes this handoff).

**FF blocked:** main checkout `integrate/mesh2-into-main` still has uncommitted WIP in `rust/Cargo.lock` and `rust/crates/agent-runtime/src/main.rs` (would be overwritten). Captain aborted `git merge --ff-only rust/integrate-b1` and did not stash. **Batch 2 must branch from `rust/integrate-b1` tip until that WIP is relocated/committed and FF lands.** Pre-existing dirty Sources/DESIGN/PLAN files were left untouched.

**STATUS: RUST-P0-DONE**
**Phase 0 contracts（2026-11-10 19:07）**：`pharos-protocol` / `pharos-store-schema` / `pharos-api`（CONTRACTS_VERSION=0.1.0，SCHEMA_VERSION=1）。`cargo check`+`test` 三 crate 通过；无 adapter/CLI/web 依赖。文档：`docs/GOAL-RUST-BACKEND.md`、`docs/rfc-007-contracts.md`。本地 tag `rust-contracts-0.1.0`。未做 CLI/适配器/HTTP/mesh。**等用户验收后开 Batch 1 并行流；本 agent 任 merge captain。**

**STATUS: RUST-PLAN-DONE**
**Rust backend plan（2026-11-10 18:01 + 18:02 并行补充）**：架构决定——全部后端收敛为独立 Rust 服务；Swift 只留 SwiftUI+WebKit 客户端。盘点 + `docs/RFC-007-rust-backend.md`：阶段门禁 A–E；**§6.1 并行工作流**（Phase 0 共享契约 → 流 S1–S6；worktree/tmux/合并规则）。`BACKEND-MATRIX` 仅 `planned-rust`。

**STATUS: GROKBOT-MEMBER-DONE**
**Grokbot Thread member（2026-11-10 14:20）**：成员 `grokbot` / nick `Pharos`（webhook 型，非本地 CLI）。`@Pharos` 定向投递 → Runtime `delivery.submit-member` → `GrokbotThreadBridge` POST ID-only `thread-mention`（human-proxy webhook）→ state=`injected`；`pharos-mesh thread reply --as grokbot` → `replyOnce` → state=`completed`；45m 无回复=`failed`。E2E Thread `grokbot-41349f97`（含 `agy-stub`），marker `PHAROS_GROKBOT_MEMBER_DONE_41349f97`，delivery `4f6afe55-…` → reply `reply-4c10d3ec…`，runtime-completed=1。协议：`docs/agents/grokbot/threads/2026-11-10_protocol.md`。证据：`internal/evidence/2026-11-10_grokbot-member-summary.md`、`..._grokbot-member-e2e.log`、`..._grokbot-unit.log`。矩阵 `GB-THD-01`…`05`。

**STATUS: peer-hitl blocked human-proxy .done.md timeout (approval path proved mini→air)
**Peer HITL re-run (2026-11-10 12:41)**：新鲜请求 `2026-11-10T112654Z_peer-air-codex-hitl.md` 再次 seed/peerSend/approval 成功，但 900s 内无 `.done.md` → 仍 **blocked/not-tested**。证据：`internal/evidence/2026-11-10_phase-d2-peer-hitl-rerun.log`。
**

**STATUS: isolated-dsh-product done**

**STATUS: isolated-codex-product done**

**STATUS: XHOST-DONE mini↔air Peer real; box headless Runtime real (Swift Host/Peer not-tested)**

**STATUS: desktop-dsh-wiring done**

**Phase (5) 桌面 DSH 接线（2026-11-10 12:25）**：**done**（受控测试）。`DesktopPharosClientService.startExplicitLocalDshThreadBridges` 在 product mode 对本机显式绑定的 DSH 启动 `DshThreadRuntimeBridge`→`replyOnceChatMessage`；`testDshThreadBindingRequiresExactLocalSessionAndMember` 与 `testDshHostProductPathUsesReplyOnceWithoutBroker` **通过**。未改 `DshBackendAdapter` 为假投递（反而去掉伪造 session ID）。证据：`internal/evidence/2026-11-10_phase-e-desktop-dsh-wiring.log`。


**Phase (4) 跨机 Runtime（更新 2026-11-10 14:02）**：落地 Peer `host.runtime.call.v1`（allowlist=`delivery.submit-member`）+ `runtime-local` / `host-runtime-submit` CLI。mini→air 真实投递 E2E：**Peer submit → air Runtime 入队 → air Agy 回复 → air `host-reply` replyOnce → mini 房间可见**（marker `PHAROS_XHOST_AIR_DONE_*`，host=`xiangs-macbook-air`）。证据：`internal/evidence/2026-11-10_xhost-mini-to-air-runtime-submit.log`。air→mini 经 `--via-local` Peer submit 成功（证据 `...xhost-air-to-mini-runtime-submit.log`）。box(grok-bot Linux)：从最新 commit 构建 `pharos-meshd`，SSH 头less Runtime submit→Agy→completed 成功；无 Swift → sync-serve --host / Peer Host **not-tested**（证据 `...xhost-mini-to-box-runtime-submit.log` / `...xhost-box-meshd-build.log`）。


**Phase (3) 隔离 Codex app-server 真实产品往返（2026-11-10 12:22）**：**done / real**。`CodexStdioTransport` 独立 `codex app-server`（禁用共享 adapter 以免抢 delivery）；Host binder→`conversation.state`→Runtime submit `.accepted`→turn→`replyOnce`；Session `01a1c532-…`，phase=replied，runtime-completed=1。门控：`PHAROS_HOST_THREAD_CODEX_PRODUCT_PATH_TEST=1`。证据：`internal/evidence/2026-11-10_phase-b3-codex-live-product-path.log`。


**Phase (2) 隔离 DSH 真实产品往返（2026-11-10 12:17）**：**done / real**。空 `DSH_HOME` 会种子失败；现复制 `~/.dsh/.credentials.yaml` + 注入 `OPENCODE_GO_API_KEY` + model patch（不共享 sessions、不碰 3080 Host/`ipc.sock`）。`PHAROS_HOST_THREAD_DSH_PRODUCT_PATH_TEST=1` → Session `session-0be5de80-…`：seed→bind→Runtime submit `.accepted`→`consumed`→`replied`，runtime-completed=1，房间关联回复。证据：`internal/evidence/2026-11-10_phase-b2-dsh-live-product-path-retry.log`。


**PM 队列（2026-11-10 11:45 Europe/Copenhagen）**：grok-bot 已回 tailnet（`tailscale status | grep grok-bot`）；`ssh box@grok-bot` 可用；human=pharos-proxy。顺序：(1) Peer HITL E2E → (2) 隔离 DSH 真实产品往返 → (3) 隔离 Codex app-server → (4) 跨机 Runtime mini↔air(+box) → (5) 桌面 DSH 接线测试后提交。真实消息仅 `pharos-msg-test`；不碰 mac-pro / 3080 Host `ipc.sock`；不把 `DshBackendAdapter` 改成假投递；不 push / 不 force。

**Phase (1) Peer HITL E2E（2026-11-10 12:07）**：**blocked / not-tested**（human-proxy）。真实路径已证明到审批：air Codex Session `01a1c515-…` 种子完成、peer inventory listed、peer sendSessionMessage、peer fetchSessionApproval 命中精确命令 `printf PHAROS_PEER_HITL_OK`；请求写入 `~/personal/pharos-msg-test/human-requests/2026-11-10T105159Z_peer-air-codex-hitl.md`，900s 内无同名 `.done.md`。证据：`internal/evidence/2026-11-09_phase-d2-peer-hitl.log`、`.../2026-11-10_phase-d2-peer-hitl-summary.log`。门控：`PHAROS_REAL_PEER_HITL_TEST=<air-uuid>`。

**持续推进目标（2026-11-09，用户授权）**：按 [本地 Cursor 持续目标](2026-11-09_cursor-local-continuous-goal.md) 分阶段继续真实 DSH / Antigravity / 远程 Host Session、Thread、Projects 及各家 HITL / Goal / Todo 验证；阶段完成后自动继续安全工作，不可得数据如实记录。Cursor CLI 适配为核心目标后的可选项；既有安全、远程部署许可及不 push/PR 边界保留。

**Phase (e2) Cursor CLI thin 封装（2026-11-09 20:55 Europe/Copenhagen）**：`CursorAgentCLI` 仅走公开 CLI：`create-chat` 在 `~/personal/pharos-msg-test/cursor-cli-probe` 返回 UUID；`agent ls` 无 TTY 失败（Ink raw mode）→ 清单 **unsupported**。不读 `~/.cursor` 私有库。Host Session/Thread 适配仍未实现；HITL/Goal/Todo **unsupported**。grok-bot：`tailscale status` 仍不可见 → **not-tested**。证据：`internal/evidence/2026-11-09_phase-e2-cursor-cli-ls.log`、`...create-chat.log`。门控测试 `PHAROS_CURSOR_AGENT_CLI_TEST=1`。

**Phase (b2) DSH/Codex product 投递桥（2026-11-09 20:52 Europe/Copenhagen）**：对齐已证明的 Agy Host binder→Runtime→`replyOnce` 路径。
- **DSH**：新增 `DshThreadRuntimeBridge`；`DshLiveSessionService.send` 接受显式 `turnID`；桌面 product mode 对本机显式绑定的 DSH 启动 Host 桥（`replyOnceChatMessage`）；legacy 仍留给插件/Broker。受控 fixture：`testDshHostProductPathUsesReplyOnceWithoutBroker` **通过**（binder→poll→submit envelope→replyOnce，runtime completed）。桌面绑定选择：`testDshThreadBindingRequiresExactLocalSessionAndMember` **通过**。
- **Codex**：`MeshHostThreadBinder` 对 Codex **固定** `codex:app-server`，不再 `driver.register` 以免覆盖 builtin 能力；`pharos-mesh host-reply` 在 `PHAROS_DISTRIBUTED_MESH=1` 下改为 `MeshDistributedHostReply`→`replyOnce`（stdin 仍为 say-once JSON，兼容 Rust worker）。`testDistributedHostReplyMapsSayOnceOntoReplyOnce` **通过**；legacy `testHostReplyCLIReadsRequestToEOF` **仍通过**。
- **Live DSH**：`PHAROS_HOST_THREAD_DSH_PRODUCT_PATH_TEST=1` 隔离 `DSH_HOME` 下 Session 创建成功，但 90s 内种子回合未完成 → **skipped / not-tested**（非失败宣称）。首次无种子尝试：submit `.accepted` 但无 room reply（`runtime-completed=0`），与种子失败同属「隔离 DSH 本轮未给出可用助手正文」边界。
- **not-tested**：真实 Codex app-server 经新 host-reply 的端到端 product 往返；跨机 Runtime submit；grok-bot / Peer HITL；desktop UI 绑定闭环。
- 证据：`internal/evidence/2026-11-09_phase-b2-dsh-codex-product-bridges.log`、`...phase-b2-dsh-live-product-path.log`。

**Phase (e) Cursor CLI 探针（2026-11-09 19:45 Europe/Copenhagen）**：本机 `agent` 2026.11.05-86047df help/`--list-models`/`create-chat --help` 核实：`--print`、`--resume`/`create-chat`/`ls`/`resume`、`--mode plan|ask` 等；**未宣称 ACP**。文档：`docs/agents/cursor/sessions/2026-11-09_protocol.md`。适配器 **未实现**；不读私有 DB/token。证据：`internal/evidence/2026-11-09_phase-e-cursor-cli-probe.log`。

**Phase (d) HITL/Goal/Todo（2026-11-09 19:45 Europe/Copenhagen）**：Peer 路径 DSH Goal/history 探针 `PHAROS_REAL_PEER_DSH_GOAL_TEST` 对 air 清单中的 Session 取得 progress=nil 后 history 报 `session-query-failed` → **skipped**（清单可达，但 Host 未持有该 Session 的 live adapter）。human-proxy 请求已写入 `~/personal/pharos-msg-test/human-requests/20261109T194416+0100_grok-bot-hitl-proxy-unavailable.md`；grok-bot 仍不可见 → HITL 人工代理 **blocked/not-tested**。既有本机/SSH HITL·Goal·Todo 证据仍有效，但**不能**称为本轮 Peer 路径 E2E。证据：`internal/evidence/2026-11-09_phase-d-peer-dsh-goal.log`。

**Phase (c) 跨 Peer Projects（2026-11-09 19:43 Europe/Copenhagen）**：同一真实 mini→air Host Peer 路径上 `fetchHostProjectCheckouts` 取得 **78** 条映射（unavailable=false），与 Session 清单交叉：**136** 个 Session 的 workspace 落在某条 checkout 路径下（例：agy Session ↔ `/Users/baixianger/omika.AI/enetpulse-event`）。证据：`internal/evidence/2026-11-09_phase-c-peer-projects.log`。**real**。**not-tested**：desktop Project→Session 跳转 UI、SSH 备用 Projects、写入/创建远端 checkout、grok-bot Projects。

**Phase (b) Host binder→Runtime→replyOnce 真实 Agy（2026-11-09 19:42 Europe/Copenhagen）**：`PHAROS_HOST_THREAD_PRODUCT_PATH_TEST=1` → `testRealHostBinderRuntimeSubmitReplyOnceWhenEnabled` **通过**。路径：`MeshHostThreadBinder.bind` → 隔离 `pharos-meshd` → `AgyThreadRuntimeBridge.poll`（delivery.poll 心跳）→ `MeshRuntimeDeliveryBridge.submit`（`.accepted`）→ 真实 ACP Session `a6ff2a80-…` → `binder.commitReply`/`replyOnce`；结果 `consumed`→`replied`，runtime-completed=1，房间唯一关联回复含 `PHAROS_HOST_PRODUCT_DONE`。**real**（非 Broker `say-once`）。证据：`internal/evidence/2026-11-09_phase-b-host-product-path.log`。要点：submit-member 要求 conversation online + 活跃 delivery.poll driver；错误 host 显示名会误 `.forward`。DSH/Codex product 桥见上方 Phase (b2)；**not-tested**：跨机 Runtime submit、desktop UI 绑定闭环。

**Phase (a) 真实 mini↔air Host Peer（2026-11-09 19:32 Europe/Copenhagen）**：mini 产品 `DistributedMesh/v1` 与 air 隔离 `~/personal/pharos-msg-test/peer-phase-a/air-mesh` 已配对同一信任组 `91AF4F03-9981-4787-B9AF-C49E0045DEB9`。`~/.config/pharos/hosts.json` 已写 `peerDeviceIDs.xiangs-macbook-air=24C6F9B2-4CBC-4A03-8379-CF72DE5FFCDF`。mini `sync-serve`（tmux `pharos-phase-a-mini`）与 air `sync-serve --host`（tmux `pharos-phase-a-air-host`，PATH+/`AGENT_CLI_CREDENTIAL_STORE=file`）在跑。`PHAROS_REAL_PEER_INVENTORY_TEST=24C6F9B2-…` → `testRealAirPeerInventoryWhenEnabled` **通过**：经 local session-rpc → Iroh → air Host 只读 Codex 18 / DSH 201 / Agy 13（均 available）+ project checkouts 78。证据：`internal/evidence/2026-11-09_phase-a-real-air-peer-inventory.log`、`...phase-a-summary.log`；运行副本 `~/personal/pharos-msg-test/peer-phase-a/logs/`。`host-runtime-hello` 达 air 但回 `runtime-unavailable`（air 无 agent-runtime；Peer RPC 本身可用）。**real**；非 loopback。grok-bot：此刻 mini `tailscale status` 不可见 → **not-tested**。未测：跨机发送/HITL、desktop UI 发现、launchd 生产 Host、Cursor CLI 跨机 Session。

下一阶段：真实隔离 DSH/Codex product live 往返（需可用 Agent 回合）；Phase (c) Projects Session 跳转 UI；Peer HITL 在 grok-bot 可达后；Cursor CLI 适配器骨架（仅正式 CLI）。

**Host-owned Thread 绑定桥（2026-11-09）**：新增 `MeshHostThreadBinder`（`Sources/PharosRuntime/MeshHostThreadBinding.swift`）：用 Host 清单校验 Session 归属、经 Runtime `conversation.register` 建立唯一 member↔vendor Session 会话、拒绝歧义/陈旧清单；并映射 `queued` / `delivered` / `consumed` / `replied` / `unknown`（`acknowledge` + `replyOnce`，不启动 legacy mailbox）。`MeshHostSessionServer` 增加 `threadBindingInspect` / `bindThreadMember`（可选 binder）；`MeshRemoteHostSessionClient` 暴露对等 API。独立 Host 与应用内 Host 启动时接入共享 `HostLocalSessionService` + 本地 Runtime driver。桌面分布式 product mode：`supportsThreadSessionBinding` 开放、候选来自本机非 stale 清单，`bindThreadSession` 走 Host binder + `joinChatMember`（不再硬拒绝）。`sendChatMessage` 对定向目标尝试 `MeshRuntimeDeliveryBridge.submit`（不走 mailbox）；product mode 本机 Agy 桥改用 `replyOnceChatMessage`，legacy 仍用 Broker `say-once`。证据：`internal/evidence/2026-11-09_host-thread-binding.log`、`...-peer.log`、`...-product-bind.log`、`...-desktop-binding-regression.log`、`...-host-thread-delivery-wire.log` — Thread binder 4 + peer Iroh 1 + Agy 不重放 1 + desktop/runtime 回归通过。边界：未证明真实 Agent 消费/回复；本机未见可用 agent-runtime，真实 Runtime 绑定 not-tested；DSH/Codex product 投递桥未接；submit 结果尚未映射到 UI receipt。插件两侧仍分歧、未改。

**真实本机只读 Host 清单 + Agy Thread 回归（2026-11-09）**：`PHAROS_HOST_LOCAL_INVENTORY_TEST=1` 经 Host RPC/Iroh 只读：Codex 1、DSH 98、Agy 86，Projects checkout 361，三家可用（`internal/evidence/2026-11-09_host-local-inventory-readonly.log`）。`PHAROS_AGY_THREAD_MESH_TEST=1` 隔离 `pharos-meshd` + 真实 ACP Session `a2597355-a45c-4fc9-9548-0696d1a70a35`：room 唯一关联回复、runtime-completed=1（`...agy-thread-mesh-real.log`）。该真实往返仍走 legacy Broker `say-once` 桥，不是新 Host binder/`replyOnce` product 路径；未测 HITL/Goal/Todo。Projects peer snapshot 回归 2 项通过。

**稳定回复冲突边界（2026-11-08）**：在既有 `replyOnce` 稳定 ID 之上，补验 `DistributedAgentChat.replyOnce` 调用链，以及同机共享 replica 双连接并发与离线双副本同步后的冲突边界。相同内容跨连接 / 跨离线副本收敛为同一 `reply-…` ID；离线两边先写入不同正文时本地均可落盘，同步后按 immutable 最早确定性时间戳收敛，败者内容重试报 `replyConflict`，胜者内容幂等。证据 `internal/evidence/2026-11-08_replyonce-conflict-boundaries.log`：4 项通过（`testDirectedAgentReplyIsIdempotentAcrossRegistryInstances`、`testDistributedAgentChatReplyOnceEntryIsIdempotentAndRejectsConflicts`、`testDirectedAgentReplyConflictsAcrossOfflineReplicasAfterSync`、`testDirectedAgentReplyOnceAcrossSharedReplicaConnections`）。这仍是房间写入边界，不是 Agent 消费、生产 Host 投递桥或桌面闭环；未跑真实 OS 多进程 fork、真实 Iroh 跨机同步、不同 Host 争用同一成员身份，也未启动真实 Agent。

插件包装分歧（仅报告、未改任一侧）：规范仓 `~/personal/deepseek harness/dsh-plugin-pharos` 干净 `main` `427db7d`（`dsh-plugin-pharos` 0.2.0，`index.js`）；Pharos 树内 `integrations/dsh-plugin-pharos` 为另一包装 `dsh-plugin-pharos-runtime` 0.1.0（`index.mjs` + runtime/mesh-broker 客户端）。两侧文件集与入口不同，不能互相覆盖或当作迁移已完成。

恢复后按原队列继续：完成由 Session 所在 Host 验证成员身份、绑定和接收投递的生产桥，接入三家并区分入队、消费、回复及结果未知；保持已有终端唤醒路径不与新路径重复处理。然后完成 Projects、真实 Peer / SSH 备用及逐家 HITL、Goal、Todo 验收，记录无法取得的数据。真实远端部署仍须按项目规则另行取得许可；不要把本次受控测试当成远端或端到端通过。

**暂停交接：分布式 Thread 稳定回复（2026-11-08）**：任务曾暂停，工作区修改尚未提交。暂停前在 `DistributedChatRegistry.replyOnce` 增加稳定回复 ID：由信任组、房间、成员及原消息 ID 确定，并校验原消息明确指向该成员；相同内容重试返回已有回复，不同内容报冲突。`DistributedAgentChat.replyOnce` 提供调用入口。这只是房间回复写入能力，不是消息已消费的证明，也尚未接入生产 Host 投递桥或桌面。

当时验证：`swift test --filter DistributedChatRegistryTests/testDirectedAgentReplyIsIdempotentAcrossRegistryInstances` 通过一项测试，覆盖同一 replica 的两个 registry 并发写入、重新创建 registry 后重试、不同内容冲突及非目标成员拒绝。该测试没有重启进程、运行真实 Agent、跨机器同步或验证生产桥；跨进程并发、不同 Host 同时声称相同成员及断网恢复仍需验证。暂停时 `DistributedAgentChat` 的入口刚加入，未单独验证其调用链。后续补验见上方「稳定回复冲突边界」。

**Peer Session 事件恢复（2026-11-08）**：客户端检测到事件缺口或无法解码的事件后报告错误，先读取完 Host 返回的事件页，再向已打开的 Session 发出恢复信号；桌面现有恢复处理会重新读取历史、进度、审批与配置。并发轮询同一 Peer 被合并为最多一个在途请求。三个 loopback Iroh 受控测试分别验证缺口与未知事件、事件页读完后触发恢复、桌面会话模型历史刷新，以及重复轮询保护；真实双机断网、厂商进度 / 审批在恢复后的完整闭环仍未验证。Host 缓冲以外的事件不能声称无损，未能重建的数据仍可能丢失。分布式 Thread 的 Host 绑定和生产投递尚未完成。

**Peer 清单一致性（2026-11-08）**：桌面生产路由改用一次 `sessionInventorySnapshot` Host RPC，同时取得同一轮三家 Session 列表与可用状态；避免并发刷新造成列表和状态来自不同轮次，从而误判 Peer / SSH 选择。模拟 Host 经 loopback Iroh 验证 DSH 从可用变不可用时清单与状态一致；桌面 mock Peer 断线回归通过。真实本机三家 CLI 经该快照和 loopback Iroh 只读取得 Codex 1、DSH 97、Antigravity 85，三家均可用。协议变更需要两端升级：不支持新查询的旧 Host 首次发现会按 Peer 不可用处理（有 SSH 时可走既有备用）；已有 Peer 绑定保持 stale，不自动跨路径重发。真实双机、真实 SSH 降级和并发交错压力仍未验证。Thread 的 Host 绑定仍未实现。

**Thread 投递安全进度（2026-11-08）**：分布式 `DistributedAgentChat` 新增按单条定向消息确认的本机持久回执，测试验证未定向拒绝、重复确认幂等及重开后其余消息保留；接口尚未接入生产投递，也不表示 Agent 已消费。旧 Antigravity Broker 桥在发送结果不明时不再把 `injected` 退回 `queued` 自动重发，回归测试模拟响应丢失后重复轮询只发送一次；目前需人工或后续对账解决未知状态，未验证真实断网。分布式生产模式仍禁用该旧桥，Thread 的 Host 绑定、投递、回复与真实远端验收未完成；下一步须使用 Host 本机确定的 Session 身份与 Runtime 队列关联，并分别呈现入队、消费和回复，不能以本次底层确认充当端到端成功。

**接手入口**：[远程 Pharos 改造详细交接、验收与测试标准](2026-11-08_remote-pharos-handoff.md)。包含工作区状态、已验证边界、执行顺序及逐家验收清单；本文件保留历史细节和既有条目引用。

**远程架构调整（2026-11-08）**：用户要求各机器的 Pharos 优先互相通信，远端 Pharos 负责本机 Agent；先建立 peer 通信，再迁移三家 Session、Thread 和 Projects，并在真实远端验证。用户明确保留现有 SSH 研究和直连作为 peer 无法通信时的备用路径；应显示实际路径，不把未知结果自动重发。现有源码差距、目标和验收见 [RFC-006 远程边界与审计](RFC-006-UNIFIED-CLIENT-AND-BACKEND-INTEGRATION.md#remote-pharos-boundary-and-current-deviations)。

**本次进度（2026-11-08）**：完成通用 Host Session & Event Replica RPC 契约与服务端骨架（`host.session.query.v1`、`host.session.action.v1`、`host.session.events.v2`），并在 Host 侧实现 `MeshHostSessionServer`（负责本地适配器所有权代理、基于游标的环形事件缓冲与幂等去重缓存）；在客户端实现 `MeshRemoteHostSessionClient`（遵循 `PharosClientService`，自动处理 Session 前缀与断点续传游标）。完成了以 Codex 为垂直切片的端到端受控闭环测试（`testCodexVerticalSliceOverIroh`），覆盖了会话列表、历史重读、发送消息、流式接收审批请求以及 HITL 决议回写。自动化回归套件 9 项（含 6 项新 RPC 测试）全数通过。

**审查修复进度（2026-11-08）**：审批撤回等无 Session ID 事件不再使整批协议校验失败；并发同幂等键共享执行，冲突拒绝；可配置的请求键日志在执行前保存，Host 重启后对旧键返回结果未知，尚未实现持久结果对账、崩溃掉电持久性或多进程互斥；进程内缓存上限 512：配置日志时可淘汰已完成缓存，但旧键重试一律返回结果未知；持久日志增长、失败请求占满缓存以及对账仍需处理。事件流带进程实例 ID，并对缓冲溢出或实例变化报告缺口，客户端发出需重载错误；不能声称无损恢复。独立分布式 Host 和应用内回退端点已接 Codex 本机服务与日志，但Codex 客户端已接入初步路由，真实服务集成及远端尚未验收。后台服务独占 Iroh 端点；本次新增 `session-rpc` 本地 IPC 使用帧 body 承载会话数据、当前 epoch 的可信 Host 和 controller 校验、Session RPC 白名单，以及 `DistributedMeshBackgroundSessionTransport`。应用侧按明确设备 UUID 建立客户端，桌面根据 `hosts.json` 的 `peerDeviceIDs` 优先只读发现 Codex Peer；没有 SSH 的 Peer 主机也可列出。初次 Peer 不可用时若有 SSH 则可发现 SSH 会话；已发现的 Peer 会话在断线时保持 Peer 归属并标记缓存，不会自动跨路径重发。会话行 / 项目会话标注 PEER 或 SSH。当前映射需手动配置，尚无界面；路由测试使用注入的 mock Peer，未覆盖真实后台到远端的完整链或初次发现失败后的真实 SSH 备用。已用真实本机 Unix socket 往返 1 MiB，含派发后超时未知结果等 18 项本地服务测试和 1 项设备映射读写测试通过；未测试最大附件、真实端到端后台转发或远程。由于 JSON/base64 嵌套及帧上限，有效大小小于上层标称值，尚未实现分块。IPC 已将派发后超时报告为结果未知，不得把它当作未执行并切换重发。早期模拟事件源异步注册导致一次测试失败，已改为真实生产事件分发器验证。

**本轮桌面路由验证（2026-11-08）**：Codex Peer 只有在显式设备 UUID 映射下使用，首次选择前查询 Session 及 v2 事件接口；设备可仅配置 Peer，无需 SSH。首次只读发现失败时如有 SSH 配置沿旧路径发现；已经选择 Peer 的 Session 断线后保持 Peer 归属、标记 stale，不会自动将发送 / 审批重放到 SSH。Session 列表和 Project 会话显示 PEER / SSH。注入 mock Peer 的桌面路由测试验证历史、断线、旧数据和不切换；实际 WKWebView 验证 SSH 标记；Host RPC / 桌面 / WebKit 针对性共 12 项通过。真实后台 IPC → Iroh → Host 与真实 SSH 降级尚未闭环；已有 Peer 会话暂无手动切换备用的界面，映射仍需手动配置，DSH / Antigravity 仍直接走 SSH。

**三家 Host Session 接入（2026-11-08）**：新增 `HostLocalSessionService`，独立 Host 与应用内回退端点持有本机 Codex、DSH、Antigravity 适配器；按 Agent 返回清单及失败状态，桌面按已支持 / 不可用信息逐家选择 Peer 或旧 SSH。Host RPC 受控 Iroh 测试使用 DSH 假 Host 和 ACP 假进程，验证三家清单、DSH 历史 / Goal / Todo / 权限拒绝、Antigravity Plan / 权限拒绝及 UTF-8 文本附件；不代表真实厂商或真实远端验收。审批 ID 以 peer 会话前缀隔离，回写去除前缀。

**真实本机只读验证（2026-11-08）**：`PHAROS_HOST_LOCAL_INVENTORY_TEST=1 swift test --filter MeshHostSessionRPCTests/testRealHostLocalInventoryWhenEnabled` 使用实际本机 CLI 与 Codex daemon，经 `HostLocalSessionService`、Host RPC、loopback Iroh 和 Peer 客户端读取清单：Codex 1、DSH 97、Antigravity 85，三家未标不可用。此测试没有发送提示或验证审批；不代表独立后台 IPC、桌面接入、真实远程或各家完整流程通过。

**后台转发受控闭环（2026-11-08）**：`testBackgroundServiceForwardsSessionToTrustedIrohHost` 使用真实本机私有 Unix socket、后台 `DistributedMeshLocalRuntimeCommands`、受信任的 loopback Iroh 和模拟 Host，验证清单、发送与 Host 历史；变更 controller 的 membership epoch 后原 Host 被拒绝。属于本机受控测试，不是启动实际 launchd 服务或两台机器的验收。

**串行流限制**：MeshKit 0.2.1 的同连接服务循环等待前一请求完成后才接收下一流；首次测试 Antigravity 等待完整回合时审批查询超时。Host 对文本及嵌入文本附件现在先返回进行中的回合，后续结果走事件，受控审批测试通过；所有其他长请求、真实网络恢复、后台 IPC 与多设备并发仍需验证。ACP 不支持的附件类型应明确拒绝，大小及断线后的附件状态未验收。

**Projects Peer 路径（2026-11-08）**：`HostProjectCheckoutProvider` 由 Host 读取本机 Pharos 偏好中的项目 UUID→绝对路径，`projectCheckouts` 经已认证的 Host Session 查询返回，桌面优先使用该映射，缺失时才在配置了 SSH 的主机使用旧只读路径；Agent 清单失败不影响已取得的项目映射。无映射 / 连接失败标记不可用，不把空与未知混同。受控测试覆盖无效 / 重复 UUID 路径、后台 Unix socket → Iroh Host、桌面 Peer-only、清单故障及不可用；真实本机只读测试通过 Iroh 取到 361 条，与本机偏好相等。未验证实际 launchd、真实远端 Host、跨机项目跳转和 SSH 备用。

**下一步**：验证真实 launchd 后台服务与双机转发、初次发现失败后的 SSH 备用及未知结果；完善设备映射配置、链路恢复与手动切换；逐家完成 DSH 与 Antigravity 的 Session 适配器向 Host Session RPC 迁移；完成 Thread 绑定与 Projects 远程映射向 Peer RPC 迁移；准备就绪后按规则向用户申请远端测试许可，进行双机真实验收。

当前工作分支 `integrate/mesh2-into-main`；工作区有未提交修改，`.agy-tasks/PLAN.md` 是已有暂存内容，保留。详见 [Session 验证记录](2026-11-07_session-surfaces.md)。

队列：进行中——Pharos peer 远程链路、Session / Thread / Projects 迁移及各家 HITL、Goal、Todo 端到端验证；后续——按 [Session 输入能力清单](2026-11-08_session-composer-capabilities.md) 继续逐家实现并验证动态权限模式、模型选择和图片/文档附件，记录不支持及无法取得的数据。清单已有部分 DSH 与 Antigravity 实现和验证，不代表三家全流程完成。

1. 完成并核验桌面生产服务：本机三家会话列表、历史、发送、事件及 Thread / Project 已接入；检查传输断开、并发历史、UI 状态与分布式 Mesh。
2. 逐家使用隔离真实会话验证 HITL、Goal、Todo 从请求、UI 回写到代理继续运行。Codex shared daemon 的自有回合结构化问答已通过程序驱动桌面 WKWebView 及持久历史验证（测试注入 Plan 模式），真实 Goal 初始显示、完成和清除事件已在桌面观察；旁观回合不会抢答；本机 CLI 命令审批取消回合已通过程序驱动桌面 WebKit 和服务端历史验证；物理鼠标、命令允许及文件审批尚未验证；DSH 远程真实结构化问答已通过程序驱动 WKWebView 提交，助手回复及 journal 完成、Goal 和 Todo 创建显示已确认；真实远程权限拒绝也已通过桌面及 journal 验证；真实远程单次允许也已在精确匹配安全命令后通过桌面、工具输出和 journal 验证；物理鼠标和并发仍待验收；Antigravity 的真实权限请求使用字符串 ID，修复过滤后已在桌面提交拒绝并收到 completed；另一次桌面单次允许精确匹配的安全命令，确认工具输出和助手正文；服务和桌面拒绝分支未观察到助手正文，真实 Plan 模式未产生 Plan 更新。DSH 隔离 Host 的模型回合报错，不能当作成功回复。
3. 远程 Codex 和 DSH 已通过配置的 SSH 主机连接；mac-air 的桌面服务已实测 Codex 列表、历史与临时只读回合，以及 DSH 列表与 3 回合历史。DSH 远程发送和一次真实 Goal、Todo、结构化问答回写已在服务层验证，journal 可恢复 Goal 和两条 Todo；额外回合已查明来自 DSH 的 `source=goal`；服务已处理外部回合开始、增量和完成，并用真实远程 Session 验证通用路径。交互流断开后的自动重试与撤回已通过模拟交互流验证；真实网络断线、会话 journal 在模拟断线后的 Goal/Todo 恢复已验证，真实网络故障及回合重建、Goal 后续回合完整运行、真实 UI、权限及并发仍待检查。DSH 的另一个真实 Session 验证 Goal 从 active 到 complete；Codex 持久测试 Session 验证 Goal 设置、读取、完成和清除，服务已读取 Goal 快照；两次 Todo/Plan 探针没有原始 Plan 事件，仍待验证；Todo 的进行中、完成、清空及重连快照已在远程真实 Session 的服务层验证；桌面 UI、并发和断线中更新待验证。远程 Antigravity 的 SSH ACP 发现和桌面路由已实现，模拟 ACP 验证历史、Plan、审批和回合；mac-pro 清单仍拒绝（先前探针观察到认证错误），真实远程会话和 SSH 恢复未验收，涉及部署先按项目规则取得授权。
4. 复测全量测试卡住的问题，完成桌面实测及同尺寸截图、头像录屏对照。不可取得的数据与失败原因持续更新到验证记录。

5. 真实桌面测试揭示切换 Session 后输入可能早于视图模型加载而丢失；现已在加载时禁用输入，WKWebView 回归通过。首次旧探针未确认选中目标，目标 journal 无用户消息，无法排除它提交到了先前会话；见 DSH 验证记录。全局错误可能被其他后台刷新覆盖，后续应检查错误作用域。
6. 已建立 [各 Agent 的 Session / Thread 协议目录](agents/README.md)，记录当前实现、状态来源、通信路径与证据边界；继续随实现和验证更新。Thread 每 3 秒刷新 Mesh roster 并在右栏展示状态；隔离真实 Broker 和 WKWebView 分别验证了状态变化与渲染。实时状态事件仍只见 mock 发出，真实厂商状态上报和端到端投递仍需验证。桌面不再将房间历史误报为 delivered；发送和 mailbox 领取后均显示 unverified，逐目标消费回执尚未接入。

7. DSH waterfall 与 journal 已在真实远程 Session 按 callId 和工具名关联；桌面权限卡可异步显示唯一匹配的命令，真实 WebKit 拒绝闭环与模拟取消、歧义测试通过。真实并行调用、断线和不同主机同 ID 仍待验收；历史读取失败且无后续事件时命令详情可能不可用。

8. Projects 现以稳定 UUID 标识，并从配置的 SSH Mac 只读提取主机本地 checkout 映射，按主机与 UUID 关联当前 Session；mac-air 真实远程路径及 Session 映射通过，WebKit 远程项目跳转经模拟验证。mac-pro 未取得映射；完整用户项目、物理鼠标和加载故障仍待验收；真实远程 Codex Session 的程序驱动 WebKit 跳转已通过。详见 [Project 记录](2026-11-07_project-session-routing.md)。

9. Runtime 外部插件投递现在要求在线、状态新鲜且驱动声明并维持 `delivery.poll`；Rust 内置 Codex worker 是例外，可处理 managed Codex 队列。DSH 项目内插件已声明该能力。独立旧 DSH 插件尚未升级，因此新 Runtime 将其回退 mailbox。隔离真实 socket 验证 Broker 至 Runtime 队列，真实厂商消费、回复、断线和既有待处理队列仍待验收，详见各 Agent 的 Thread 记录。

10. DSH 项目内插件与真实 Rust Runtime 的隔离 socket 集成测试覆盖注册、定向入队、模拟 Agent followup 与等待返回后 ack；真实 Agent 消费和回复、ack 丢失引发的重复仍未验收。同键重试在驱动离线时返回原投递，键冲突拒绝。

11. 隔离真实 Broker → Rust Runtime → Codex 持久 Session 定向投递已验证，助手正文和 completed 可从 Session 历史核对；受控提示禁止工具调用，尚未验证自动回复房间、桌面输入或远程。临时 Session 的 includeTurns 读取不受支持。复现和保留的 Session ID 见 [Codex Thread 文档](agents/codex/threads/2026-11-07_protocol.md)。

12. DSH 真实远程桌面单次允许已验证：仅在精确匹配无副作用 printf 后提交，journal 有 allowed-once 和成功工具输出，助手可见且 completed；Session 保留，详见 [DSH 验证记录](2026-11-07_dsh-session-validation.md)。

13. Antigravity 真实 plan 模式第二种虚构任务提示仍未产生 ACP plan 或工具事件，回合 end_turn，测试 skipped；真实 Todo 无法据此验收。详见 [Antigravity 记录](2026-11-07_antigravity-session-validation.md)。Session 总览已修正过时的权限和远程项目映射状态。

14. DSH 真实桌面 Todo 四阶段及四个 completed 回合已通过，退出桌面 Host 后独立 journal 重放通过；多 Host 会话争用曾失败，随后连接失败与清理测试孤儿隧道的因果未证实。其他归属不明的 SSH 隧道未动，子进程生命周期待核实。详见 [DSH 验证记录](2026-11-07_dsh-session-validation.md)。

15. 正常释放真实远程 DSH 服务及桌面测试视图后，weak 引用与测试创建的直接子进程均消失；异常退出和多窗口未验收，先前 SSH 隧道错误根因仍未知。生命周期探针的 signal 11 已定位为测试窗口 close 后重复释放，已修正测试设置；详见 [DSH 记录](2026-11-07_dsh-session-validation.md)。

16. DSH 远程真实桌面 Goal active→complete、结构化问答及 completed 已验证；后续清除提示仅产生 get_goal，Goal 保持 complete，独立 journal 无 clear。详见 [DSH 验证记录](2026-11-07_dsh-session-validation.md)。

17. Codex 真实 Thread 回复探针失败：Agent 的 Mesh CLI 无法连接隔离 Broker；对照诊断中宿主连接成功，真实 workspace-write 工具进程 connect 返回 EPERM。不得把 consumed 或 Session 内回复当成房间往返；后续已接入宿主侧关联及幂等回复，本机隔离真实 Codex 桌面往返通过；远程与分布式尚待验证，详见 [Codex Thread 记录](agents/codex/threads/2026-11-07_protocol.md)。

18. Codex Rust Runtime 现在保存目标 member 与 turn ID，只转发完成回合的 final_answer；Broker 按目标和原消息校验并幂等落盘。本机隔离真实往返、并发重试和 Runtime 恢复关联通过；旧记录不自动补发，远程、分布式和网络故障仍待验收。详见 [Codex Thread 记录](agents/codex/threads/2026-11-07_protocol.md)。

19. 生产桌面 WebKit 已在隔离 legacy Broker 发送消息并显示真实 Codex 宿主回复；Broker 历史核对唯一回复及引用。UI 尚不显示 replyTo，远程、分布式和故障恢复仍待验收，详见 [Codex Thread 记录](agents/codex/threads/2026-11-07_protocol.md)。

20. 用户确认范围仅为 CLI 或其协议明确支持的 Session，不对各家桌面 GUI 做专门接入。Codex shared daemon 的 `thread/list` 当前无来源过滤，可能列出其他客户端 Session；不能将列表或写入权一概视为 CLI，需按协议能力和所有权区分。DSH `web --no-open` 是 CLI 服务，尽管本机可执行文件位于应用包内。

21. Codex CLI 0.166.0 真实命令审批提供 `cancel` 而未提供 `decline`；已区分取消回合与拒绝继续，真实服务层确认回写及回合取消，随后生产 WebKit 与服务端历史也完成真实闭环验证。真实桌面命令允许、文件审批及远程审批仍未验证，详见 [Codex Session 协议](agents/codex/sessions/2026-11-07_protocol.md)。

22. Codex 真实命令审批取消已通过生产桌面 WebKit 与历史闭环（程序驱动），先执行只读种子回合；首次空会话 70 秒未出现在列表，原因未确定。测试细节、两个 Session 和证据见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

23. 项目内 DSH 插件按 Session 独立领取投递，避免一个挂起的 followup 阻塞其他 Session，同时保持同一 Session 串行；真实 Rust Runtime + 两个模拟 Agent 的隔离测试通过。真实 DSH 插件部署、Agent 消费和房间回复仍未验证；确认丢失后仍可能重复。见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。

24. Projects 的真实远程桌面验证通过：使用 mac-air 的真实 checkout 映射和 Codex Session，程序操作生产 WebKit 从 Project 打开对应 Session，并核对远程历史渲染；不涵盖 DSH/Antigravity、物理鼠标或故障恢复。详见 [Project 记录](2026-11-07_project-session-routing.md)。

25. Antigravity ACP prompt 发生 JSON-RPC 错误时，服务现在撤回审批并以原 turn ID 发布失败结束事件，记录用户输入与已录制部分内容；模拟错误及本地／远程前缀权限回归通过。进程崩溃可能先清空 recording，真实断网及 Mesh→ACP 桥接仍未验证。见 [Antigravity Session 文档](agents/antigravity/sessions/2026-11-07_protocol.md)。

26. Swift/Rust Runtime 对同一 member ID 的多个在线投递候选不再按最近更新时间任选，新投递会报冲突；幂等重试保持原记录。隔离真实 socket + Broker 验证冲突回退 mailbox，Rust 回归 15 项、Swift 路由 8 项通过。mailbox 同 ID 仍有领取者歧义，本次不证明端到端身份安全；真实多主机及 Antigravity Mesh→ACP 桥仍待完成。详见 [Antigravity Thread 记录](agents/antigravity/threads/2026-11-07_protocol.md)。

27. 受控 ACP 子进程退出测试复现 Antigravity 已录制内容被清空，现保留已到达 transport 的记录；回合失败、审批撤回与四项相关测试通过。最后管道数据竞态及真实 SSH 故障未验收。Thread 桥接需明确保存 member UUID、主机与 ACP sessionId 关联；一般 MeshSpawn 的成员 ID 可独立生成，不能由昵称猜测。见 [Antigravity Session](agents/antigravity/sessions/2026-11-07_protocol.md) 和 [Thread](agents/antigravity/threads/2026-11-07_protocol.md)。

28. 新增 Antigravity Thread 回合关联层 `AgyThreadRelay`，显式绑定 member/Session/room/message 并按 turn 匹配；真实 ACP 测试在内存回调收到匹配助手回复，模拟测试覆盖重复、错误 Session、失败回合和重试。生产 Runtime 队列、持久绑定、Broker 写回及崩溃恢复尚未接线；不能称为真实房间往返。见 [Antigravity Thread 文档](agents/antigravity/threads/2026-11-07_protocol.md)。

29. Antigravity 已有显式绑定的 Runtime 队列桥：隔离真实 Rust Runtime → MeshBroker → 本机真实 ACP → Broker `say-once` 往返通过，房间唯一回复引用原消息，Runtime completed；Session 和证据见 [Antigravity Thread 文档](agents/antigravity/threads/2026-11-07_protocol.md)。测试手动创建桥并轮询，桌面生产生命周期、绑定 UI、持久恢复、远程及 HITL 尚未接入或验证；`injected` 后崩溃不会自动重试。

30. Antigravity 本机明确绑定的 legacy Thread 已挂到桌面服务：真实隔离 Rust Runtime、Broker、ACP 和程序驱动 WKWebView 从输入到唯一关联回复通过；最终 Session 和证据见 [Antigravity Thread 文档](agents/antigravity/threads/2026-11-07_protocol.md)。仅当 member ID 和 session 精确等于本机 ACP ID 且 host/type 明确时启动；独立 member UUID 绑定界面、后台服务、成员离开时立即停止、跨进程竞争、远程/分布式、Thread HITL 与 `injected` 崩溃恢复仍未完成或未验证。

31. Antigravity 本机明确绑定 Thread 的真实 HITL 单次允许已通过：从房间发起安全命令，桌面切换同一 Session 后按精确命令匹配允许，确认工具输出、completed 回合、房间唯一关联回复及 Runtime completed。Thread 拒绝、多请求、远程、断网与恢复仍未验证；见 [Antigravity Thread 文档](agents/antigravity/threads/2026-11-07_protocol.md)。

32. Antigravity 桌面 Thread 成员离开后下一次房间清单刷新会使桥 offline、停止领取，重新加入后可上线。真实 ACP/桌面测试在完成回合后验证离开与重加入；进行中回复等待成员重新加入由模拟 ACP + 隔离 Runtime/Broker 验证，非真实中途离开。进程退出的关联持久恢复、跨进程争用及断网仍待验收。见 [Antigravity Thread 文档](agents/antigravity/threads/2026-11-07_protocol.md)。

33. 本机 DSH `0.2.2-rc.1` 真实 Host 经临时 overlay 加载项目插件；真实 Runtime consumed，Session journal 的 `agent/inbox/spliced` 在 `turn/start` 前包含投递，现已映射到 Session 历史。模型回合为 error，未证明回复或房间往返；peer 兼容声明与锁文件已调整，实际 profile 安装和远程版本未验收。详见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。

34. DSH 测试 Session `session-051f9259-cd70-43f8-99ae-82dd25e14700` 的模型无视禁止工具提示，调用既有 web profile 中的旧 Pharos 工具并向默认 `pharos` 房间发出一条测试消息，工具返回 delivered；未删除消息。暂停同类模型测试，必须先硬禁用旧插件及隔离可执行工具/通信路径；详见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。

35. 本机 DSH v4 对旧 `source.kind=plugin` 返回来源格式错误，安全复现与普通提示对照确认；项目插件改为 `pharos-mesh`/`relay` 后，硬禁用旧工具和具体工具的真实 Host 测试观察 inbox、助手标记及 completed，journal 无工具调用；真实房间回复与远程未验证。此前不受控 Session `session-051f9259-cd70-43f8-99ae-82dd25e14700` 的旧插件向默认 `pharos` 房间成功发出一条测试消息，保留未删除；详见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。

36. 项目内 DSH 插件以 inbox claimed 消息 ID/turn 关联回合，由宿主经本机 Broker `say-once` 幂等回复，不再让模型调用消息工具。禁用旧工具及具体工具的隔离测试已通过真实 Rust Runtime、Broker 和本机 DSH 完整往返，唯一回复引用原消息，Session `session-07fa6e24-caa2-4cca-ae9f-88857fba7dda`。生产 profile 未部署、桌面/远程/分布式及跨重启恢复仍未验收；injected 崩溃可能需人工核对。详见 [DSH Thread](agents/dsh/threads/2026-11-07_protocol.md)。
37. 桌面应用打包已包含项目内 DSH 插件及锁定依赖，本机应用 Host 通过临时 overlay 加载且不改用户 profile；包内模块经真实 Swift Host、隔离 Runtime/Broker 和新建 Session 完成唯一回复往返。已有冷 Session 仅 history/follow 不会激活，真实测试未注册，不能接收 Thread 投递；需寻找明确支持的无副作用恢复方式。真实打包应用 UI、旧插件并存、远程、崩溃恢复和 Thread HITL 未验收。证据及安全边界见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。
38. DSH 冷 Session 调查补充：随本机 `0.2.2-rc.1` 的公开插件文档确认 `ctx.agents.resume()` 底层原语存在，但普通 Host 恢复另有投影/preset、subagent 归属、writer 冲突和并发策略；Host 内部 `resolveAgent` 未见外部插件协议保证。未将绕开这些约束的调用接入生产；继续寻找支持完整策略的公开入口，或记录能力缺失。细节见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。
39. 发现另一正式候选：本机 DSH SDK `0.2.2-rc.1` 的 stdio `session/resume` 可从原持久库无新提示恢复确切 Session；它由独立 SDK 进程持有，已占用会拒绝。上游文档说明可能修复中断回合并记录初始化模型选择，因此不是无副作用的 Web Host 激活。SDK 加载项目插件、preset/模型保真及桌面协调尚未验证；详见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。
40. 隔离真实 DSH SDK 测试已验证自建空 Session 关闭后 `session/resume`、插件在线注册及第二写者被拒绝；journal 实际包含模型选择，无用户消息和新 turn。可复跑脚本 `Tests/Live/dsh_sdk_resume_probe.py`，证据及未验证的 Web 创建 Session、preset/模型保真和生产协调见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。
41. 真实隔离 Web Host 创建的空 Session 在 Host 关闭后可被 SDK 恢复并注册插件；Host 尚持有时 SDK 被拒绝。先后以 reasoner 与 chat 两种 SDK 初始化路由恢复，journal 记录两次模型选择，证明固定 SDK 路由会改写会话模型，尚不能直接用于生产。Web 直接选模型的隔离尝试因无可用模型失败；非默认 preset、历史回合和桌面协调未验收。可复跑 `python3 Tests/Live/dsh_sdk_resume_probe.py --web`，证据详见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。
42. DSH SDK 隔离 Web Session 同一 reasoner 路由连续恢复未追加重复模型选择，随后切换 chat 仍追加选择；仅覆盖空 Session。非默认 preset 标记在 Session 创建前已运行，无法判断 scoped preset 恢复，之前据此作出的判断无效；SDK 对该 preset 的声明虽可解析，作用域保真仍未知。完整测试和失败诊断见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。
43. DSH preset 改为直接观测 `composedPreset(agent.ctx)`：本机隔离 Web Agent 绑定测试 preset，同一 Session 的 SDK 恢复 Agent 未绑定，即使声明可解析；SDK 恢复不能原样用于生产保真。另修复同一 Host 重开 Session 时状态序号重置导致 Runtime 一直离线：真实 Rust Runtime + 模拟 Agent 测试先失败、修复后上线并接收消息，真实 DSH 生命周期仍未验收。证据见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。
44. 修复 DSH 注册与销毁交错：真实 Rust Runtime/socket 代理延迟注册确认的回归先复现旧 Agent 销毁后误上线；现核对 Agent 身份，替代 Agent 可注册接收消息，迟到旧销毁不使新 Agent 离线。四项插件回归及真实隔离 DSH SDK 正常注册通过；真实进程中的延迟、远程与崩溃恢复未验收。证据见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。
45. 远程 Project 探针改为可选 Agent 并隔离本机偏好域和注册表；mac-air Codex 实际跳转/历史回归通过。DSH 有 185 个候选、118 个路径匹配，但历史读取 117 次报错（116 次 NSURLError -1011、1 次无快照）、1 次无文本，测试跳过，需先查单 Session 和受控连续读取，不能视为无数据或通过。最初裸 XCTest 在隔离前因通知 bundle 崩溃，ProjectStore 已对实际偏好 `pharos.launchMeshAtLogin` 写 true，原值未知；未主动赋值项目列表或发送消息。证据见 [Project 记录](2026-11-07_project-session-routing.md)。
46. 远程 DSH 批量历史定位：已知 Session 单次、五次重复及不存在 Session 后读取均通过；特定候选的初始快照使共享连接关闭，随后已知 Session 握手 -1011。将远程首个快照 maxMessages 由 100 改为 1，旧记录仍 HTTP 分页；问题 Session 的 407 条记录及前后已知 Session 的 71 条读取通过。桌面 DSH Project 找到并列出匹配项，但点击后的历史渲染断言失败；下一次诊断清单为空，尚未完成端到端验收，首帧根因未完整证明。见 [DSH Session 文档](agents/dsh/sessions/2026-11-07_protocol.md)。用户提出候选名 Amigents 和 Afriends，明确只讨论、不改名。
47. 远程 DSH 清单对照：同一桌面测试中独立 ACP 查询 mac-air 取得 185 条，但服务内查询 SSH 退出 255、脱敏分类 connection closed，导致列表为空；重试和禁用 SSH 复用无效且已撤回。增加仅记录错误域、退出状态的诊断；直接根因、失败时现有 DSH 服务生命周期及 Project 渲染仍待处理。本地项目关联/WebKit 模拟回归通过。详见 [DSH Session 文档](agents/dsh/sessions/2026-11-07_protocol.md)。
48. 远程 DSH 清单失败不再销毁既有 Session 服务和绑定；保留最后成功清单并标记 inventoryStale，Session/Project 行提示清单暂不可用。成功刷新替换缓存，空清单和主机目标变更清除旧绑定；checkout 路径失败仍不复用旧映射。模拟服务生命周期及程序驱动 WebKit 两项通过；真实 mac-air 保留测试 Session 在故障注入前首次历史读取失败，远程验证未通过。见 [DSH Session 文档](agents/dsh/sessions/2026-11-07_protocol.md)。
49. 隔离 SSH 对照发现 mac-air 在一条独立会话存活时关闭第二条独立连接；在同一 SSH ControlMaster 上动态添加转发成功，原因未定。远程 DSH Host 已将 Host 和自身转发合并为一个受控连接；真实 mac-air 交互订阅后读 71 条历史、模拟清单故障前后读四回合、正常释放 SSH 子进程均通过。完整 Project 流程中 Codex/ACP/checkout 等仍各自使用连接，DSH 清单依旧 SSH 255 skipped；跨服务连接协调、真实断网和异常退出待验收。见 [DSH Session 文档](agents/dsh/sessions/2026-11-07_protocol.md)。
50. 桌面按远程主机共享私有 SSH ControlMaster，Codex 转发、DSH 清单和 Web Host、Antigravity ACP 与 Project 路径复用；子命令失效时禁止静默直连。真实 mac-air 同一连接验证 Codex/DSH 清单、78 项路径、DSH 71 条历史；DSH 的 history 和 follow 首帧均缩小后，生产 WKWebView 从 Project 打开真实远程 DSH Session、渲染历史通过，Codex 同流程回归通过。一次异常测试产生的自有 SSH 残留已清理，现以管道约束主连接生命周期；真实断网、强制退出、跨窗口及真实远程 Antigravity 未验收。完整证据和两次 UI 环境异常见 [DSH Session 文档](agents/dsh/sessions/2026-11-07_protocol.md)。
51. 共享 SSH 本地进程关闭时，桌面下一次清单刷新无需等 60 秒；同一目标重连前在后台等待自有旧 SSH 子进程退出，避免远端尚占用时连接失败。真实 mac-air 受控关闭共享连接的桌面服务测试先复现重连失败，修复后自动建立新连接、获取新清单并重读同一 DSH Session 的四个回合；不是物理断网或在途回合恢复。mac-pro Antigravity 经共享 SSH 的 ACP `session/list` 仍被拒绝，真实会话验收 skipped。详见 [DSH Session](agents/dsh/sessions/2026-11-07_protocol.md) 和 [Antigravity Session](agents/antigravity/sessions/2026-11-07_protocol.md)。
52. 远程 DSH 共享连接替换、清单成功恢复后，桌面按精确 Session ID 发布恢复事件；已打开视图模型自动重读历史、进度和审批并重新建立 follow，无需切换会话。已完成的旧回合不再保持忙碌，加载期间新状态与新错误有修订保护。真实 mac-air 受控关闭自有连接后，桌面视图模型自动重读并恢复四回合；事件编码、其他 Session 隔离和模拟回归通过。真实断网、在途模型回合、HITL 恢复、新连接实时更新及 WebKit 重连仍未验收。见 [DSH Session 文档](agents/dsh/sessions/2026-11-07_protocol.md)。
53. 共享 SSH 恢复通知扩展到远程 Codex 和 Antigravity：仅在同主机清单成功且精确 Session 仍存在时触发；失败保留待恢复关联，目标变化或移除清除。真实 mac-air Codex 受控关闭连接后视图模型自动重读 12 回合，DSH 同流程四回合回归通过；模拟远程 Antigravity ACP 路由与事件编码回归通过，未模拟其真实 SSH 替换，mac-pro ACP 清单仍拒绝。详见 [Codex Session](agents/codex/sessions/2026-11-07_protocol.md)、[Antigravity Session](agents/antigravity/sessions/2026-11-07_protocol.md)。
54. 修复共同 Session 视图模型的历史快照竞态：加载期间到达的回合完成、新回合和提交消息原会被旧快照覆盖；现按回合 ID/本地修订号合并并保留忙碌状态。两个受控并发回归先复现后通过，相关 20 项测试及 mac-air DSH 真实只读自动重连回归通过；真实在途断网、多次并发加载和厂商历史压缩仍未验收。见 [DSH Session 文档](agents/dsh/sessions/2026-11-07_protocol.md)。
55. 共同 Session 历史加载加请求代次：旧请求不得覆盖新历史/进度/审批/错误或提前结束新请求的加载状态；重复加载保留事件监听。受控乱序、旧错误及重叠期间事件回归先复现后通过，相关 23 项测试通过；mac-air DSH、Codex 受控连接关闭后自动恢复历史分别回归通过。真实网络分区、远端乱序与在途回合仍未验收。见 [DSH Session 文档](agents/dsh/sessions/2026-11-07_protocol.md)。

56. mac-air DSH 0.2.1-rc.2 在两个专用测试 Session 上通过 `commands/execute` 原生 `/goal clear`，各自 journal 持久 clear；其中一个真实服务订阅收到 Goal nil，独立重放通过，未启动模型回合。桌面输入框尚未接原生命令、命令业务错误和输出尚待处理，不能视为 UI 闭环；见 [DSH 验证记录](2026-11-07_dsh-session-validation.md)和 [Session 协议](agents/dsh/sessions/2026-11-07_protocol.md)。用户提出 Afriends 为名称候选，与 Amigents 一样目前仅讨论、不改名。

57. DSH 桌面普通发送的斜杠命令已走本地/远程 Host 原生命令通道，显示结果并识别业务错误；其他 Agent 和 steer 保持原路径。mac-air 真实 WKWebView 只读 `/goal` 与未知命令的结果/错误显示通过，模型回合数不变；另一个此前专用 completed Goal Session 的桌面 `/goal clear` 使 Goal 消失，服务进度为空，独立 journal 重放通过。创建/完成与本次清除分属不同 Session；新建同一 Session 的完整闭环测试已修改但尚未执行。失败草稿恢复、附件、命令发现与其他版本待验收，见 [DSH 验证记录](2026-11-07_dsh-session-validation.md)。

58. Session 斜杠提交保留草稿直至结果返回：成功只清除仍等于提交原文的草稿，失败保留；按 Session 和请求 ID 匹配，等待时编辑及切换其他 Session 不覆盖新输入。真实 mac-air DSH 桌面 `/goal` 成功清空、未知命令失败保留且无新增回合；模拟延迟 WebKit 与 14 项 Session 流式回归共 15 项通过。跨窗口、断网、重启后草稿、附件和命令发现未验证，见 [DSH 验证记录](2026-11-07_dsh-session-validation.md)。

59. 远程 Antigravity ACP 清单失败保留同目标缓存和已打开服务并标注 `inventoryStale`；共享 SSH 建连失败同样保留过期行但读取明确不可用，目标变化清旧绑定。模拟 ACP 故障后 Plan/权限继续、受控实际桌面刷新建连失败与目标变化、DSH 对照，以及 WebKit Session/Project 过期标记通过。mac-pro 的真实认证没有修改，远程 Session/HITL/Goal/Todo 仍未验收；首次失败无缓存时缺少主机级错误提示。详见 [Antigravity 验证记录](2026-11-07_antigravity-session-validation.md)。

60. 远程 Antigravity 首次清单失败且无缓存时，Session 侧栏现显示对应主机的不可用提示，成功刷新或移除主机后清除；收起侧栏有可访问提示符。受控真实桌面服务 SSH 建连失败和模拟服务 WKWebView 零 Session/恢复测试通过；mac-pro 只读 ACP `session/list` 复查仍拒绝并 skipped，此次未证明具体原因。DSH/Codex 的首次发现主机级提示尚未接入，真实远程 Antigravity Session/HITL/Goal/Todo 仍未验收。见 [Antigravity 验证记录](2026-11-07_antigravity-session-validation.md)。

61. 用户将 Session 输入框动态权限/执行模式、真实模型目录及切换、图片与文档附件兼容纳入当前目标；按各 Agent 和主机能力区分，保留 DSH 输入体验。现有模型列表硬编码、模式仅 safe/yolo 且按标题调用成员接口，Session 发送为纯文本；均不视为完成。具体优先队列、各家协议起点和真实本地/远程验收见 [Session 输入能力清单](2026-11-08_session-composer-capabilities.md) 与各 Agent Session 文档。

62. 本机 Antigravity CLI 现为 1.5.3；隔离 ACP Session 的 initialize 声明 image/embeddedContext，new/load 返回 models、modes 和 model/thought_level/mode 配置。plan 设置响应成功后跨进程重载仍显示 default，尚未验证当前连接实际生效或持久。生产 AgyLiveSessionService 按 Session 保留打开时能力快照，真实 ACP 和四项模拟回归通过；动态更新、桌面控件、实际附件传输及远程仍未验收。证据见 [Antigravity Session](agents/antigravity/sessions/2026-11-07_protocol.md)。

63. Antigravity ACP `configOptions` 已按 Session 接入桌面输入区，显示原生 select 配置并用 `session/set_config_option` 精确路由、校验宣告值和响应；处理配置变更事件及加载期间配置通知，`agy` 隐藏旧硬编码模型/YOLO 控件。本机真实 1.5.3 隔离 Session 经程序驱动 WKWebView 切换 plan 与另一模型，服务响应和界面一致，无模型回合；测试固定注入清单且 ACP 在本机，不是 SSH 或推理实际生效。配置生效/持久、权限、附件、远程和其他 Agent 未完成。详见 [Antigravity Session](agents/antigravity/sessions/2026-11-07_protocol.md)。

64. DSH Web Host 已读取 provider 分组模型目录及精确 Session 的 next selection，桌面输入区显示加载时只读 provider/model，不以全局默认代替未知 Session，隐藏旧硬编码控件。真实 mac-air 0.2.1-rc.2 和程序驱动 WebKit、provider 重名及目录缺失回归通过；切换仍未接入，因上游 `selectModel` 可能后台更新新 Session 默认，reasoning/权限/附件及实时变化未完成。两次探针出现额外 journal 记录，后一次确认 `session/end-seed`，原因不明，无模型选择或新回合；具体日志见 [DSH Session](agents/dsh/sessions/2026-11-07_protocol.md)。

65. DSH 本机 0.2.2-rc.1 在独立 DSH_HOME 的空 Session 中读取模型目录和选择通过，但该隔离环境返回零 provider、无当前选择；不能推广至用户正常配置。真实远程模型目录/Session 只读 UI 综合 18 项通过；另一次 UI 本机空目录回归通过。模型切换和默认值副作用、权限、附件、实时变更仍未完成，见 [DSH Session](agents/dsh/sessions/2026-11-07_protocol.md)。

66. DSH 输入区按精确 Session 和 provider/model 接通 `session/selectModel`，仅接受已宣告组合并核对响应，实时处理 `model/selection`；界面提示可能更改新 Session 默认值。隔离本机 DSH 0.2.2-rc.1 + mock 模型，生产 WebKit 切换、journal、投影和隔离 profile 默认值写入通过；显式固定默认模型的 patch 对照未观察默认变化，原因未定。综合 23 项通过含远程只读和 Antigravity 回归；没有在用户真实 profile 切换，真实推理、远程切换、reasoning、权限和附件仍待完成。见 [DSH Session](agents/dsh/sessions/2026-11-07_protocol.md)。

67. DSH 输入区按 Host catalog 和 Session 投影显示原生权限预设；`/permission` 写入需校验允许项并由投影确认，完全权限/auto 需界面确认，权限事件触发状态刷新，目录失败时模型仍可用并显示权限不可用。独立本机真实 DSH + mock 模型经 WKWebView 验证只读、完全权限取消/确认及恢复，默认预设不变、无模型回合；mac-air 只读目录通过，未更改真实远程权限。模拟目录缺失、非法选项及既有回归通过；auto、远程切换、真实工具、断线并发仍未验收。测试中的 `InvalidTransition` 定位到 WebKit 求值阶段，脚本作用域调整后通过，底层原因未完全证明。见 [DSH Session](agents/dsh/sessions/2026-11-07_protocol.md)。

68. DSH Host 与 DshLiveSessionService 支持按精确 Session 上传小文件回执并随消息提交；回执被绑定 Host/Session、成功后不可重复使用，Host 替换清除本地记录。journal 回放新增普通 file 元数据块，URI 留空。独立 0.2.2-rc.1 Host 对文本文件与 PNG（均为普通 file）核对存储字节、消息记录、文件 ID/名称/大小及跨 Host/Session 客户端拒绝；mock 模型不可用，未证明模型接收或完成。综合 20 项通过；桌面文件选择、远程、图像视觉通道、下载、大小/流式和超时是否已接收未完成。见 [DSH Session](agents/dsh/sessions/2026-11-07_protocol.md)。

69. 停止并重启独立 DSH Host 后可回放此前两个附件的 ID 和名称；未验证重启后下载字节。修复未完成回合的轮询任务保留服务、导致 Host 不退出的问题，增加释放和实际 Host 子进程退出检查。测试期间识别并终止本测试遗留的三个孤儿进程，清除七个本测试 scratch 目录；测试清理现在先结束自有子进程再删除目录。记录与证据见 [DSH Session](agents/dsh/sessions/2026-11-07_protocol.md) 和 `internal/pitfalls/2026-11-08_dsh-pending-host-retention.md`。

70. 轮询重构后的回归共 21 项通过：包含静默 journal 仅通过轮询完成原回合并允许下一次发送、服务释放、真实隔离附件 Host 重启、远程 DSH 命令与本机权限 UI。证据 `internal/evidence/2026-11-08_dsh-file-lifecycle-final.log`；实际模型读取附件、远程附件传输、输入框选择附件及端到端 HITL/Goal/Todo 余项仍须按现有清单继续。

71. mac-air DSH 专用 Session 现在完成同一 Session 的桌面 Goal 创建、问答、完成和 `/goal clear`；独立 Host 重放 journal 确认 create→complete→clear 及完成回合，Goal 为空。首次运行创建空 Session 后因 XCTest 调用通知中心崩溃，未发提示；关闭通知并复用该 Session 后通过，测试已处理通知环境。程序化 WebKit 并非物理点击，断网和自动后续回合未测；详细证据见 [DSH 验证记录](2026-11-07_dsh-session-validation.md)。

72. mac-air DSH 0.2.1-rc.2 专用 Session 经本机服务上传 51 字节随机标记文本，真实模型回复包含该标记并完成，远程 journal 含附件 ID/名称/大小；新 Host 重放文件元数据和回复通过。测试 Session 保留；桌面附件入口、图像视觉、其他类型、下载、断线和恢复仍未验收。证据与细节见 [DSH Session](agents/dsh/sessions/2026-11-07_protocol.md)。

73. DSH 桌面输入区已接入文件选择与对应 Session 上传，限制五个文件合计 10 MB，失败保留草稿，命令/steer 不带附件。mac-air 真实 DSH 经程序向 WKWebView 注入文件，模型回复随机文件内容且 journal 记录附件；受控测试覆盖字节、失败/成功和 Session 草稿隔离。测试固定注入清单且未人工操作系统选择器；图片视觉、其他 Agent、拖放、下载、进度及断线恢复待验收。见 [DSH Session](agents/dsh/sessions/2026-11-07_protocol.md)。

74. 本机 `agy 1.5.3` 真实隔离 ACP 实验确认 `embeddedContext` 文本 resource 可被模型读取；新进程重放时资源转成普通文本，内容及 URI 可见、原类型丢失。现有生产 ACP 发送先返回进行中回合、后异步接收结果；将附件接入 UI 前需处理失败与草稿保留，避免提前声称成功。生产链、图片/二进制、远程及异常恢复尚未验收。见 [Antigravity Session](agents/antigravity/sessions/2026-11-07_protocol.md)。

75. Antigravity 声明 `embeddedContext` 的 Session 已支持桌面发送 UTF-8 文本附件；附件请求等待 ACP 完成，失败保留草稿。模拟 ACP 拒绝经桌面回归通过；本机真实 ACP 经程序驱动 WKWebView 读取随机文件内容并回复。真实测试注入清单，远程样式 ID 但 ACP 在本机，系统选择器、图片/二进制、真实 SSH、断线与元数据回放尚未验收。见 [Antigravity Session](agents/antigravity/sessions/2026-11-07_protocol.md)。

76. Antigravity 桌面附件真实及模拟拒绝与既有 Session 测试综合 18 项通过。首次测试残留自有 scratch 目录已核对并清理；测试清理现在先终止命令行包含本次专用目录的直属子进程，再删除目录；复测后未发现对应目录。证据 `internal/evidence/2026-11-08_agy-embedded-ui-final.log`。

77. Codex 0.166.0 在默认及显式 plan 模式的两次新 ephemeral Session 均完成但未发结构化 Plan 更新，真实 Todo 仍未通过。受控通知复现旧回合计划覆盖新回合；生产服务现按 turn 和 Session 限制计划、在新回合清除旧计划，相关 17 项回归通过。本机生成 schema 要求 threadId/turnId；真实计划生成、持久化、远程与异常事件顺序仍待验收。详见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

78. 真实 Codex plan 模式发出独立 `plan` 文本 item，旧转换器丢弃该内容；现接入实时计划增量和最终权威文本，保留原始类型。真实 ephemeral 和持久测试 Session 的完成回合通过，持久历史重读也保留相同文本；测试注入 plan 模式，不是桌面选择验收。计划文本不等于 Todo，结构化 Todo 和远程仍未验收。见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

79. 新持久 Codex 测试 Session 经生产桌面服务及程序驱动 WKWebView 提交计划请求，真实 Plan 的 803 个增量中观察到实时界面文本，最终计划标记可见，历史重读文本与后端最终 item 一致。测试注入 Session 清单及 plan 模式；普通列表、桌面模式选择、结构化 Todo、远程及物理操作不由此证明。证据见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

80. 另一真实持久 Codex 测试 Session 的桌面实时文本经归一化后与最终 Plan 内容匹配，原始流有 879 个增量，最终标记和历史重放通过；相关回归共 17 项通过。测试仍注入清单和 plan 模式，不代表结构化 Todo 或远程验收。见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

81. 本机独立 DSH Host、项目插件、Rust Runtime 和隔离 Broker 经生产桌面 WebKit 完成 Thread 定向消息与唯一关联回复，journal 确认 Session completed，界面显示回复；安全 overlay 禁用所列工具并核对配置。首次桌面 65 秒等待超时，随后同一测试后端完成；将等待上限调为 120 秒后另一测试 Session 通过。生产 profile 并存、冷 Session、远程、分布式、HITL 和断线未验收。详见 [DSH Thread 协议](agents/dsh/threads/2026-11-07_protocol.md)。

82. Project 页面现提示读取 checkout 映射失败的远程主机，已知映射仍可用，成功空映射不视为失败；模拟 SSH 建连失败和 WebKit 提示/恢复通过，真实 mac-air DSH 的 Project 打开历史回归通过。真实断网恢复、checkout 指令独立故障和 Agent 清单完整性仍未验收，详见 [Project 关联记录](2026-11-07_project-session-routing.md)。

83. 真实本机 `agy 1.5.3` plan 模式的隔离提示正常结束，但未观察到 ACP Plan 或工具事件，真实 Todo 仍未取得。模拟 ACP 对端经生产桌面验证计划创建、更新、完成、清空及重载完整快照，相关 17 项通过；不得把模拟重载视为真实 Agent 持久化。ACP priority 当前未保留，远程与真实 Goal/Todo 仍待验收。见 [Antigravity 验证记录](2026-11-07_antigravity-session-validation.md)。

84. ACP Plan priority 现按 Agent 提供的字符串保留并显示；缺失不推测，未知值保留，DSH/Codex 不自动套用 ACP 语义。模拟 ACP 覆盖 high/low 的桌面显示、更新和重载，旧数据解码及其他厂商计划回归通过；真实 Antigravity priority 尚未观察到。证据见 [Antigravity 验证记录](2026-11-07_antigravity-session-validation.md)。

85. 本机真实 Codex 文件审批已经生产桌面 WebKit 显示、拒绝并收到同一请求 resolved；只读临时文件未创建。请求仅带 item ID，文件变更在先前 started 事件；服务现按 Session/turn/item 关联 patch，真实 UI 核对文件名和内容，受控回归核对旧回合和旁观隔离。远程、乱序、多文件、实际允许写入仍未验收。见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

86. 本机真实 Codex 的单个测试文件变更经精确路径、类型、内容及一次授权预检后，在桌面 WebKit 单次允许，实际文件内容、请求确认和历史重读均通过，测试文件已清理。另修复 `fileChange.changes` 数组导致历史出现空 patch：每项保留路径、类型和内容；多项完成事件及重放经模拟验证。初次把 add 内容当统一 diff 的预检拒绝了安全请求，格式核对后修正；远程、真实多文件、覆盖/删除和断网未验收。见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

87. Codex 文件变更历史现显示后端状态：真实桌面拒绝后的 `declined`、界面标记和文件未创建通过；受控 UI 对照 completed 和未知状态，相关 19 项回归通过。真实多文件、远程和其他状态仍未逐项验收。见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

88. 远程 mac-air Codex 结构化问答经真实 SSH 和生产 Session 服务完成请求、回答与回合继续；独立桌面测试发现并打开远程 Session，但未在期限内显示问答，标记 skipped，原因未明，需诊断原始事件与回合状态后继续，不视为桌面通过。plan 模式由测试注入。见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

89. 用户再次确认输入框的动态权限/执行模式、模型选择、图片和文档附件须逐家兼容并记录支持边界；此前已列入 [输入能力清单](2026-11-08_session-composer-capabilities.md)，现有局部实现仍需按清单逐项完成和真实验收。继续当前真实 Session 数据链及 HITL/Goal/Todo 工作，再处理未完成的输入能力。

90. 已定位并修复 Codex 已加载 Session 在新连接发送时未订阅事件：清单发现的 Session 首次发送前执行 `thread/resume`。mac-air 真实远程桌面程序操作 WKWebView 已通过结构化问答显示、回答确认、回复完成和历史重放；plan 模式仍由测试注入。旁观实时订阅、断线重连、真实拒绝及多请求等仍待验证。先前专用运行回合已检查并处理，详见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

91. Codex 已恢复 Session 与连接代次绑定；旧事件丢弃，旧审批查询/回答时撤回并在 UDS 写入处校验代次，失联回合须由历史确认结束才允许再发送。本机真实独立客户端在已完成回合之间关闭并重建自身连接、再次收到回复；mac-air 真实桌面正常问答回归通过。受控测试覆盖旧事件、旧审批及运行中回合阻止新发送。远程真实断网、回合/审批中断线、主动失效提示及恢复与发送间竞态仍待验收或解决，见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

92. 已修复 Codex 恢复后、发送前连接变化的竞态：RPC 返回实际连接代次，启动请求在连接锁内核对代次，回合所有权也绑定实际发送连接。受控测试先复现再验证；本机真实测试在恢复后关闭专用客户端连接，旧代次发送被拒且历史无新增回合，正常续聊和 mac-air 桌面问答回归通过。发送后响应丢失、远程真实断网、运行中断线及普通纯文本发送失败的草稿保留仍待处理，见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

93. Session 普通文本和 steer 现按提交结果保留失败草稿；编辑代次保护用户改回同一文本的情况，按 Session 隔离并阻止等待时重复提交。Codex 连接变化的受控桌面路径确认错误可见、草稿保留且无回合启动。Antigravity 桌面纯文本现等待 ACP 回合结果，模拟拒绝保留草稿，本机真实权限拒绝 completed 后未修改草稿清空；Thread 原发送语义不变。真实断网、结果丢失后的安全恢复、跨进程草稿和其他 Agent 的异步拒绝仍待验证，见 [输入能力清单](2026-11-08_session-composer-capabilities.md)。

94. 修复 steer 操作覆盖原回合 ID、失败时错误清除运行状态：steer 不改变原回合的活动标记，受控测试覆盖成功和失败后的状态。真实 steer 断线及历史重放仍待验收。

95. legacy Broker 的显式 `join` 现可将独立 member ID 绑定到厂商 Session ID，已有 ID 不能通过重 join 静默改绑；本机 Antigravity 桌面桥按明确的 host/type/session 匹配，多个成员指向同一 Session 时拒绝自动路由。真实隔离 Runtime、Broker、ACP 与程序操作 WebKit 已验证独立 UUID 的 Thread 唯一关联回复；另通过精确安全命令的单次权限允许、工具输出、completed 以及离开/重加入状态。UI 绑定入口、真实远程/分布式、多进程及崩溃恢复仍待完成，详见 [Antigravity Thread 协议](agents/antigravity/threads/2026-11-07_protocol.md)。

96. legacy Broker 声明 `thread-session-binding-v1` 时，桌面 Thread 右侧可选择当前可用的本机 Antigravity Session、填写成员名并加入；Broker 原子拒绝昵称和身份冲突，跨房间复用明确绑定。真实 ACP、隔离 Runtime/Broker、程序操作 WebKit 已从 UI 添加并完成 Thread 定向回复，另通过精确安全命令的单次权限允许、工具输出及离开/重新加入。旧 Broker、远程、分布式、其他 Agent、进行中改绑和崩溃恢复不在已验证范围，见 [Antigravity Thread 协议](agents/antigravity/threads/2026-11-07_protocol.md)。

97. 入口按 Broker 实际能力显示，并按当前 ACP 清单可用性提供候选；真实 UI 添加与消息往返复测通过。历史文件存在但房间未加载时的添加已通过受控 Broker 测试，不存在房间仍拒绝；历史房间真实 UI、远程/分布式和其他 Agent 仍待验收或实现。最后相关回归 29 通过、9 环境跳过，见 [Antigravity Thread 协议](agents/antigravity/threads/2026-11-07_protocol.md)。

98. 修复 Rust Runtime 错把 Codex 派生会话的根 `sessionId` 当目标 ID：只接受具体 `thread.id`，受控测试先复现再通过；真实根/派生隔离房间投递通过。Thread 右侧现也可添加本机 Codex Session，须由 Broker 和 Rust Runtime 明确声明新能力，提交前核对 Runtime 所有权及成员冲突；真实本机普通和派生 Session 均经程序操作 UI 加入、定向回复，派生测试核对根无回复。首次无回合 Session 未能从入口选择、未活动 fork 未出现在测试清单，种子回合后才完成验证；旧持久记录不自动迁移，Runtime/Broker 间并发改绑、远程/分布式、真实故障和 DSH UI 绑定仍待处理，见 [Codex Thread 协议](agents/codex/threads/2026-11-07_protocol.md)。

99. Thread 右侧现可添加本机已在线且项目插件声明回复能力的 DSH Session；只读 Runtime 检查使用真实投递候选规则，唯一、在线和精确身份不满足时不提供或拒绝。真实隔离 DSH Host/插件、Broker、Runtime 和程序操作 WebKit 从 UI 加入并完成定向回复，发送前 journal 未变化；三家本机入口随后分别真实回归通过。冷 Session 不自动恢复；用户现有 Host/插件未升级，远程、分布式、断网、进程崩溃及多进程竞争仍待验证，见 [DSH Thread 协议](agents/dsh/threads/2026-11-07_protocol.md)。

100. 远程 Thread 投递发现未修复的重复投递风险：受控 Broker 测试让节点领取 Runtime 命令并延迟回执，8 秒超时后消息进入旧 mailbox，而命令随后仍可报告已提交成功。测试使用模拟节点回执，没有证明真实 Agent 重复执行；本机 Runtime 请求写入后响应丢失也可能被误当作可转发，尚未复现。需要区分明确未提交与结果未知，持久协调同一投递的确认/恢复并向 UI 呈现不确定状态；不能简单将未知归为成功或自动放入第二条通道。真实远程故障和恢复仍未验收。证据 `internal/evidence/2026-11-08_remote-thread-timeout-repro.log`，复现测试在 `MeshRuntimeRoutingTests`。

101. 后续修改 legacy Broker：远程命令已领取但未确认、失败或回执无法解释时保留未知状态，不再写第二份 mailbox；未领取时取消命令并保留旧回退。本机 Runtime 写入/响应不确定及持久化错误同样不转发；明确无该成员才转发，成员归属冲突明确拒绝并显示提示。消息历史记录未知/拒绝目标，桌面展示检查后再重试；客户端 `say` 等待由 5 秒增至 30 秒。受控测试经真实 Broker Unix socket、模拟远程节点领取和迟到成功核对客户端警告与空 mailbox；桌面服务重读、WebKit 提示和相关回归共 17 项通过，证据 `internal/evidence/2026-11-08_remote-thread-routing-verified.log`。迟到成功不会自动清除历史未知标记；尚无持久对账/安全恢复，多个目标顺序等待仍可能超过 30 秒，提交中 Broker 崩溃的持久性和真实断网/远程 Agent 尚未验收。初次桌面测试因 XCTest 通知初始化异常退出，隔离设置后通过，遗留自有 scratch 已清理。

102. 已领取的 Runtime 投递命令过期后，Broker 现可记录同一节点、同一命令、匹配原 JSON-RPC 请求 ID 的迟到成功回执；仅接受 `delivery.submit-member` 的正向提交结果。未领取命令、其他动作、错误节点/请求 ID 和非成功结果仍拒绝。受控测试核对过期、迟到确认、幂等更新及新 Broker 重读，相关 16 项通过（`internal/evidence/2026-11-08_late-node-ack-final.log`）；实际远程 Agent 未验收。旧版过期记录没有领取标记，无法用此路径自动补认。消息历史与 UI 目前仍保持未知，不会自动根据迟到回执对账；后续需持久关联命令和消息、处理事件通知及重启恢复，不能把 Runtime 接收当成 Agent 已执行。

103. legacy Broker 已将精确的房间、消息、成员与节点命令的成功回执持久关联：核对原始 RPC ID、投递键与消息信封后，历史读取只移除相应成员的未知状态；桌面既有三秒历史刷新可获取投影，仍显示 Unverified，不声称 Agent 消费。受控真实 Broker socket + 模拟节点验证错误 RPC ID 不清状态、正确回执清除、删除确认文件后从持久命令重建及新 Broker 重读；桌面服务、WebKit 和相关回归共 18 项通过（`internal/evidence/2026-11-08_thread-ack-reconcile-final.log`）。本次未做真实远端故障或自动界面刷新端到端；原始投递尚未确认时 Broker 崩溃、多目标超时仍待处理。节点命令保留七天，超过此期限后损坏/丢失确认文件不能从命令恢复；确认文件目前未随房间删除回收且会增长，需后续补充生命周期管理。

104. 修复明确远程主机的 Thread 成员与本机 Runtime 同成员 ID 碰撞：投递桥先按成员 host 判断，非本机 host 直接交对应节点，避免被本机同 ID 会话截获。受控测试核对本机 host 正常路径、远程路径不调用本机客户端，以及隔离真实 Swift Runtime 中已注册同 ID 的队列不新增投递；相关 17 项通过（`internal/evidence/2026-11-08_remote-thread-host-routing-final.log`）。缺失 host、主机别名不一致、节点所有权冲突和真实远端投递仍待验收。mac-air 只读探测确认 DSH/Codex 可执行链接及一个既有测试 Broker，用户的 `~/.local/bin/pharos-mesh` 指向不存在的应用目标；未确认其他位置是否有可用当前 Runtime，未更改或重启远端进程（`internal/evidence/2026-11-08_mac-air-thread-runtime-readonly.log`）。

105. Broker 现将显式节点 owner 的连接来源传给 Runtime 投递桥；远程或离线 owner 不允许直接进入本机 Runtime，即使成员 host 缺失或写为 localhost。本机在线 owner 且 host 不冲突仍可直连。受控测试覆盖远程节点与本机同名、缺失 host、本机节点、离线节点及旧版成员数据解码；路由、桌面和 WebKit 综合 22 项通过，旧格式另 1 项通过（`internal/evidence/2026-11-08_thread-node-ownership-routing.log`、`...thread-node-ownership-legacy.log`）。本地/远程判断依赖 Broker 观察到的节点连接来源，并非跨机器密码学身份；转发连接、host 与 owner 冲突的具体生产拓扑及真实远程投递仍未验收。无 nodeID 且无 host 的旧记录仍无法判定归属，沿用原路径。

106. mac-air Codex 的专用持久 Session 已经真实远程协议和生产 Session 服务完成 Goal 创建、读取、标记完成、清除；同一 Session 从生产桌面的真实远程清单打开，程序驱动 WebKit 观察 Goal 初始、完成、清除。独立 SSH 连接重读 Goal 为空且种子回复保留；Session 保留。写入由独立协议客户端发起，不是模型或桌面输入控件主动创建；真实断网及其他版本未验收。证据与版本边界见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

107. 本机隔离 Codex ephemeral 回合以真实多步骤任务和指定 `printf` 提示诱导 `update_plan`；回合 completed、原始 item 含 commandExecution，但无 `turn/plan/updated` 或 Todo 快照，测试 skipped，未核对实际命令文本；结构化 Todo 仍未取得，不能据此判定不支持。当时发现的 Codex 输入框 `/goal` 缺口见下一项进展。证据和边界见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

108. Codex Session 输入已接入 `/goal` 查询、创建、暂停、恢复和清除，写操作带用户来源；已有 Goal 时拒绝创建，但读取与写入非原子。mac-air 专用 Session 的生产桌面真实验证查询、已有 Goal 拒绝和草稿保留、对暂停目标再次暂停、清除及无新增回合；创建与恢复目前只有受控测试。后台 Mesh 错误曾遮盖会话错误，现优先展示当前会话错误；异常测试留下的专用 Goal 已在核对归属后清除。相关回归、版本与未验收项见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

109. 随后同一 mac-air 专用 Session 的真实远程服务及生产桌面 WebKit 输入框分别验证 `/goal <目标>` 创建、暂停、恢复和清除，目标要求禁止工具/文件/网络。独立 SSH 重读 Goal 为空、历史 6 回合且无在运行回合，规范化历史未发现工具、终端或文件变更块；未归因每个回合来源，不推断原始协议中没有其他事件。目标创建的并发竞态、真实断网及物理操作仍待验收。详见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

110. mac-air 的 DSH 与 Codex 各选一个真实 checkout 匹配的 Project/Session：生产桌面先打开并渲染历史，受控关闭测试自有共享 SSH 连接后重建连接、刷新清单和 checkout 映射，再从 Project 打开同一 Session 并渲染历史，两项分别通过。测试只读，属于主动关闭自有连接而非真实物理断网；每家仅一组，Antigravity 远程仍未验收，见 [Project 关联记录](2026-11-07_project-session-routing.md)。

111. 为远程 DSH Thread 添加受限 Runtime 只读检查：指定单个 Session，仅在真实候选规则满足唯一、在线、精确成员/厂商 ID 和回复能力时返回 eligible；不启动或投递。新能力可经 Host RPC 网关访问，原批量详情接口仍只供本机驱动。Rust 17 项、真实 Rust socket + 项目插件 4 项、Swift 网关 2 项通过。mac-air 旧测试副本未升级；下一步仍须将已验证 SSH 主机与唯一在线节点绑定、接入桌面候选并在提交前复查，再验证真实远端投递和回复，见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。

112. 后续已实现远程 DSH 桌面候选、批量受限检查、绑定前复查及 Broker 节点校验。真实 mac-air SSH 身份配合模拟远端节点、模拟清单与本机真实 Runtime，程序驱动 UI 验证旧节点隐藏、离线拒绝、绑定和一次队列投递；不是远端真实 DSH 消费或回复。相关 Swift 回归 30 项通过；真实本机 DSH 一次超时且原因未明，诊断重试成功，均保留证据。mac-air 旧组件未升级，真实跨机链路、网络故障和恢复仍待验收，见 [DSH Thread 文档](agents/dsh/threads/2026-11-07_protocol.md)。

113. 受控复现本机和远程 Runtime 即时回执 ID 错误仍被判定成功；现本机 socket 先校验 ID 再解释错误，本机和远程正向提交都要求匹配 JSON-RPC 身份及布尔结果，错误或不匹配为 unknown、不自动回退 mailbox。socket 与路由回归见 [DSH Thread 共同链路记录](agents/dsh/threads/2026-11-07_protocol.md)；这不是实际远程 Agent 故障的证据，也未解决提交期间 Broker 崩溃或多个目标的顺序等待超时。

114. Broker 现先将原消息及保守 unknown 状态原子写入历史再路由，写入失败不投递；路由结束仅更新原消息，避免快速回复被当成找不到原消息。受控测试在投递闭包中同步回复并重读另一个 Broker 历史，真实本机 DSH 桌面绑定及房间回复也回归通过；实际杀进程、断电、多 Broker 写入、长历史性能及多目标顺序超时仍未验收或解决，见 [DSH Thread 共同链路记录](agents/dsh/threads/2026-11-07_protocol.md)。

115. 受控复现投递中删除房间使已发送原消息消失；Broker 现保护进行中的房间，暂时拒绝删除、改名、成员离开和同名接管，全部投递完成后可重试，显式发送者身份在保护开始时复核。真实 Broker socket + 模拟远程节点和并发发送回归见 [DSH Thread 共同链路记录](agents/dsh/threads/2026-11-07_protocol.md)；真实远端 Agent、跨 Broker 并发、UI 拒绝呈现及多目标顺序超时仍未验收或解决。

116. 四个慢远程目标在隔离真实 Broker socket 复现 30 秒客户端先超时、原消息已写历史；常用发送接口现按去重目标数计算等待预算，响应丢失时提示结果未知、先检查历史。另修复事件先于发送确认导致同一消息重复显示，按服务端 ID 合并。受控 socket 和 WebKit 状态渲染验证见 [DSH Thread 共同链路记录](agents/dsh/threads/2026-11-07_protocol.md)；远程节点为模拟，仍顺序路由，显式 endpoint 超时、真实断网、跨进程故障及 UI 端到端错误路径尚未验收。

117. 本机 Antigravity CLI 1.5.3 的真实会话清单已分别验证服务层关联隔离 Project，以及程序操作生产 WebKit 从 Project 打开准确 Session 并渲染真实历史；只读、各选择一个样本、不记录正文。项目映射与 UI 回归见 [Project 关联记录](2026-11-07_project-session-routing.md)。真实远程 Antigravity 清单、远程 HITL 和真实 Goal/Todo 仍未验收。

118. mac-air 的专用 DSH Session 已观察 Goal 来源自动后续回合 completed，生产服务发布两次完成及一次开始事件；清除 Goal 后独立 Host 重放确认两回合完成、Goal 来源及清除。首次只记录事件数量，未核对开始事件具体 ID；桌面 UI 与真实断网仍未验收，见 [DSH Session 验证记录](2026-11-07_dsh-session-validation.md)。

119. 第二个 mac-air 专用 Session 的 Goal 来源自动后续回合再次完成，并精确核对生产服务的开始和完成事件均匹配该 journal 回合 ID；Goal 完成后清除，独立 Host 重放确认清除及两回合完成。相关模拟断流重放回归也通过；实时桌面、真实断网和其他版本仍未验收，见 [DSH Session 验证记录](2026-11-07_dsh-session-validation.md)。

120. 第三个 mac-air 专用 Session 经程序驱动生产 WebKit 发送 Goal 提示，界面显示 active、complete 和自动后续回合回复，服务开始/完成事件匹配该回合 ID；通过桌面服务清除后，独立 Host 重放确认 Goal 来源回合含同一标记、已完成且 Goal 为空。清除通过服务调用而非输入框；物理操作、真实断网和其他版本仍待验收，见 [DSH Session 验证记录](2026-11-07_dsh-session-validation.md)。

121. mac-air 专用 Codex Session 使用只读沙箱经生产桌面真实触发命令审批；核对命令包含测试标记后，在 WebKit 取消，审批 resolved、卡片关闭、同一回合 cancelled；独立 SSH 重读确认 cancelled 且没有在运行回合。测试未批准命令，远程允许、文件审批、物理操作和断网仍待验收，见 [Codex 验证记录](2026-11-07_codex-session-validation.md)。

122. 同一生产 DSH 服务同时观察 mac-air 两个专用 Session：真实 Agent 分别创建并完成不同 Goal，状态和事件未串用，清除第一个不影响第二个；最后两个 Goal 均清除，独立 Host 重放核对各自完成、无交叉内容及清除。桌面会话切换、多主机、并发写入和真实断网仍待验收，见 [DSH 验证记录](2026-11-07_dsh-session-validation.md)。

123. 另两个 mac-air 专用 DSH Session 经程序操作生产 WebKit 分别创建 Goal，验证会话切换后展示各自目标、清除第一目标不影响第二目标，并通过输入框清除两者；独立 Host 重放确认各自完成、无交叉和清除。物理操作、多主机、并发写入和真实断网仍待验收，见 [DSH 验证记录](2026-11-07_dsh-session-validation.md)。

STATUS: peer-hitl blocked human-proxy .done.md timeout (approval path proved mini→air)

STATUS: isolated-dsh-product done

STATUS: isolated-codex-product done

STATUS: cross-host-runtime done hello mini→air; submit Peer RPC not-tested; box not-tested

STATUS: desktop-dsh-wiring done

STATUS: ALL-DONE

STATUS: peer-hitl-rerun blocked human-proxy .done.md timeout again

STATUS: human-proxy-webhook landed

STATUS: peer-hitl done webhook+45m real

STATUS: ALL-DONE
STATUS: xhost-mini-to-air done Peer submit+Agy+replyOnce real
STATUS: xhost-box headless Runtime done; Swift Host/Peer not-tested
STATUS: GROKBOT-MEMBER-DONE
STATUS: RUST-PLAN-DONE
STATUS: RUST-P0-DONE
STATUS: RUST-B1-MERGED — 09192f0213b3977c0a68ec00368446045284eea1
STATUS: RUST-B2-MERGED — 144cab6e3485d47bca45c2514a388b7167e03b71
STATUS: RUST-B3-MERGED — 648c22892a52a27812de44f75b306d5fd23b4234

## 2026-11-11 — WIP salvage (partial)

STATUS: WIP-SALVAGE-PARTIAL

Worktree `rust/wip-salvage` starts at `6f33c33`; no push or merge. Snapshot `cbb7c8e` was read from Git objects. Commits: `b1ff80c` preserves historical validation and ideas; `8318e59` adds standalone session progress models; `80fd55d` retains the DSH runtime socket alias; `d3550cf` preserves WIP evidence and pitfalls; `0ecc1e1` fixes Codex fork routing by concrete thread ID with a regression test; `6ea3d72` rejects unrecognized approval choices; `9913d63` documents gaps.

The workspace/WebCanvas UI, remaining ClientKit changes, DSH reply flow and iOS changes have **not** been ported. The WIP workspace requires the native bridge and older contracts, while the current `pharos-web` executable uses fake services. Deleted Swift backend code and its backend-specific tests were not restored. See [WIP salvage gaps](2026-11-11_wip-salvage-gaps.md) for feature-level coverage and remaining work. The workspace UI port and reconciliation of other compatible WIP changes remain open; do not treat this as WIP-SALVAGE-DONE.

Gate results after code changes (2026-11-11; PATH includes `/opt/homebrew/bin`, Rust commands after `source "$HOME/.cargo/env"`):

- `swift build`: PASS — `Build complete!`.
- `swift test --filter ArchitectureBoundary`: PASS — 4 tests, 0 failures.
- `swift test --filter PharosClientKitTests`: PASS with one skipped live HTTP smoke — 5 tests executed, 1 skipped, 0 failures; `PHAROS_SMOKE_BASE_URL` was not set.
- `cd rust && cargo fmt --all -- --check`: PASS — exit 0.
- `cd rust && cargo clippy --workspace --all-targets -- -D warnings`: PASS — `Finished dev profile`.
- `cd rust && cargo test --workspace`: PASS — 89 tests passed, 0 failed, including `codex_forks_register_concrete_thread_ids`.

Full command output is in `internal/evidence/2026-11-11-wip-salvage-{swift-build,swift-boundary,swift-client,cargo-fmt,cargo-clippy,cargo-test}.log` (local ignored files). No live host or GUI verification was performed.

## 2026-11-11 — WIP salvage follow-up

STATUS: WIP-SALVAGE-DONE

- `a812cff`, `dbf19cf`, `5e6f364`: ported WebCanvas workspace, transcript, avatar, markdown and styling to both `Sources/Pharos/Resources/WebCanvas/` and `webui/`. `transport.js` uses the WebKit bridge when available and otherwise the Rust HTTP/WS API. Keep the two directories byte-identical; `rust/crates/pharos-web/tests/asset_sync.rs` enforces this during `cargo test`. The web root redirects to `workspace.html`.
- `19cd544`: ported ClientKit workspace DTOs, request IDs, progress reads, matching Rust event mapping, and explicit errors for unavailable operations. `50958f7`: ported the app shell, workspace view and session/thread view models without restoring Swift backend modules. `b594c34`: checked bundled WebKit rendering and bridge dispatch. `0639d88`: updated the [gap list](2026-11-11_wip-salvage-gaps.md), including missing operations and wire contracts.
- WIP backend implementations and incompatible tests remain dropped; iOS remains unported. The web server binary still uses fake services. Current approval snapshots, session commands/configuration/attachments, questionnaire answers, session binding, member operations and other missing endpoints are listed in the gap document and disabled or reported unavailable. No real host, physical GUI interaction or production backend behavior was verified.

Final gates, run after the code changes with `/opt/homebrew/bin` in `PATH` and `source "$HOME/.cargo/env"` for Rust. Full local output: `internal/evidence/2026-11-11-wip-salvage-final-{swift-build,swift-boundary,swift-client,cargo-fmt,cargo-clippy,cargo-test}.log`.

| Exact command | Result and output excerpt |
| --- | --- |
| `swift build` | PASS — `Build complete!` |
| `swift test --filter ArchitectureBoundary` | PASS — `Executed 4 tests, with 0 failures` |
| `PHAROS_SMOKE_BASE_URL=http://127.0.0.1:18787 swift test --filter PharosClientKitTests` | PASS — both selected suites reported `Executed 8 tests, with 0 failures`; live HTTP smoke used the local fake server, with no skipped test. |
| `cd rust && cargo fmt --all -- --check` | PASS — no formatter output, exit 0 |
| `cd rust && cargo clippy --workspace --all-targets -- -D warnings` | PASS — `Finished dev profile` |
| `cd rust && cargo test --workspace` | PASS — 90 passed, 0 failed; includes `app_and_web_assets_are_identical` |

Additional checks: `node --test Tests/WebCanvas/transport.test.mjs` passed 2 tests; `swift test --filter WorkspaceWebViewPortTests` passed the bundled WebKit rendering and native bridge check. A local browser sent a message to the fake service, rendered the response and progress, and displayed an unavailable error for an unsupported action. The local fake server was stopped after testing. No push or merge.
