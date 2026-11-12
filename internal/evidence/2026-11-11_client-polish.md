---
summary: rust/client-polish 证据：Swift ClientKit 接 wave-2 web endpoints（配置/stop-revive/附件/成员/绑定/审批/健康探测）、Mac shell 实际接线、webui 空列表诚实化、/openapi.json 补全；门禁全绿（cargo 400 tests、swift 55+58、node 16、npm 30）。
---

# Client polish stream evidence (2026-11-11, Europe/Copenhagen)

Worktree: `/Users/baixianger/personal/pharos-wt/client-polish` (branch `rust/client-polish`, base `2a365eb` = origin/main `e3f8436` tree).
Lead: this stream. Teammates: `clientkit-http` (ClientKit HTTP + tests), `shell-web` (webui 空状态 + Mac shell 接线 + PharosTests)。所有改动都在本 worktree；未 push/force/rebase/amend。

## Commits (small steps, each independently testable)

| commit | scope |
| --- | --- |
| `16eea30` | `feat(openapi)`: `/openapi.json` 补全 router 已服务但冻结 stub 漏掉的路径 + 独立全路由测试 |
| `73d741f` | `fix(webui)`: 空 session 列表不再显示 "Configuration unavailable"（webui + WebCanvas 逐字节一致） |
| `2c46356` | `feat(clientkit)`: HttpPharosClientService 接 wave-2 endpoints + 49 个 URLProtocol 单测 |
| `d2224e7` | `feat(shell)`: Mac shell/ViewModel 实际使用新 API + 纯映射测试 + WKWebView bridge 测试 |

## 1. Swift ClientKit（`2c46356`）

`Sources/PharosClientKit/` 里原先抛 `not on pharos-api 0.1.0` / `unavailable in the Rust API` 的方法全部接上真实 HTTP（错误体经现有 `APIErrorBody → PharosClientError` 原样透传）：

- `GET/PATCH /api/v1/sessions/{id}/config` → 新 `ClientSessionConfiguration`（supported/supportedFields/model/mode/models/modes/capabilities{attachments,commands,stop,revive}/readonly）。502 `unsupportedField` 以 `operationFailed` 抛出、绝不报告为已保存。
- `POST /sessions/{id}/stop|revive` → 新 `stopSession/reviveSession(sessionId:)`。`stopMember/reviveMember` 保留显式 name→sessionId 解析：先精确 id，再唯一 title；0 个 → 明确错误；多个 → 拒绝歧义。502 一律抛错。
- 附件：`POST /sessions/{id}/attachments` + `GET /attachments/{id}` + `/content` + `GET /sessions/{id}/attachments`；`sendSessionMessage(files:requestId:)` 先按 `capabilities.attachments` 能力门控（false 时明确报错、不产生孤儿附件），再上传 → `POST /messages {"attachmentIds":[…]}`；content-type 白名单与 webui transport.js 相同，1 B..10 MiB。
- 成员：`GET/PATCH /members/{id}`（settings view；`agent/machine/status` 明确为空=未知，绝不编造），`PUT /members/{id}/avatar`（png/jpeg data URI）；`fetchMemberDetail` 映射 `displayName/avatarShape/avatarColor`（ClientMemberDetail/ClientAvatarInfo 的 additive 可选字段）。
- Thread 绑定：`supportsThreadSessionBinding()`（探测已知 thread 的 bindings 路由）、`threadSessionBindingCandidates()`、`bindThreadSession`（PUT）、`unbindThreadSession`（DELETE）、`fetchThreadMembers`（GET `/threads/{id}/members`）。
- 审批：`fetchSessionApproval` 走 `GET /api/v1/approvals?state=pending&sessionId=`；`resolveSessionApproval` 支持 `cancelled` 与 `questionnaireAnswers`（selected/free-text 拆分与 webui 一致；无元数据时全部放 selected，由服务端校验）。
- 健康探测：`BackendHealthReporting.probeBackend()` + 纯函数 `PharosBackendDiagnostics.guidance(baseURL:probe:)`；默认端口 8787 被其它本地应用占用时给出可操作文本（URL、实际 service、`PHAROS_API_BASE_URL` 覆盖）。
- `executeSessionCommand` 仍诚实不可用（后端无该路由）。`fetchHealth` 保留。

测试：`Tests/PharosClientKitTests/HttpPharosClientServiceWiringTests.swift`（新，1041 行，49 个 URLProtocol-stub 测试，覆盖每个映射与诚实错误分支：无能力不上传、上传失败不发消息、502 透传、name→id 歧义、cancelled/问卷、健康诊断等）；`HttpPharosClientLiveSmokeTests` 增加 env-gated wave-2 round-trip。

## 2. Mac shell 接线（`d2224e7`）

WebView 仍以 `file://` 加载，`transport.js` 检测到 `pharosBridge` 后所有动作走 native bridge；因此把新 API 接进 shell/ViewModel 才会真正生效：

- `WorkspaceWebState` 增加 typed `sessionConfiguration`（select/status，编码与 transport.js 完全一致）+ `capabilities: [String: Bool]`；`supportsTextAttachments` 来自 `config.capabilities.attachments`（不再用 agent 名启发式）。
- session details 的 model/mode/models 来自 `GET /sessions/{id}/config`；删除了旧的 "session title 当 member id" + machine/agent 猜测路径。
- `sessionConfig/model/mode` → `setSessionConfiguration`；`stop/revive` → `stopSession/reviveSession` 后 reload config+history；按钮由 capabilities 门控，失败只显示服务端错误。
- Thread roster 优先 `fetchThreadMembers(threadId:)`，旧路径作为 backend 无该路由时的 fallback；绑定候选=全部 sessions；绑定后重取 threads+thread data。
- 人类头像：启动 `GET /members/human` 作为行身份 fallback；编辑时先乐观渲染再 `setMemberAvatar("human", shape/color)` 持久化，失败回滚（不假装保存）。
- 后台加载失败时 probe `/health` 并用 `PharosBackendDiagnostics.guidance` 显示可操作错误；Settings ▸ Machines 显示 API base URL、8787 共享端口提示与 "Check backend" 探测按钮。
- `SessionConversationViewModel.configurationLoadFailed`：只有真正 fetch 失败/`supported:false` 的选中 session 才显示 "Configuration unavailable"。

测试：`Tests/PharosTests/WorkspaceStateMappingTests.swift`（新，14 mapping + 1 roster fallback）；`WorkspaceWebViewPortTests` 新增 WKWebView bridge 测试：把真实编码的 native state 送进 bundled `workspace.html`，断言 model/mode select、honest notice、附件菜单 capability、Stop 门控都由 native state 驱动。

## 3. Web UI 空状态（`73d741f`）

`webui/transport.js` `refresh()`：无 selection 时 `sessionConfiguration: []`（不再 `sessionControls(null)` → "Configuration unavailable"）；选中 session 的 config fetch 真失败时仍诚实显示。`webui/workspace.js` 无 selection 时关闭 selection-scoped details 面板。`webui/` 与 `Sources/Pharos/Resources/WebCanvas/` 逐字节一致（`diff -r` 空；`asset_sync` 在 cargo 测试内绿）。新增 2 个 node:test；新版空列表用例在 pre-fix 副本上会失败（负向对照）。

## 4. OpenAPI（`16eea30`）

`/openapi.json` 原来漏掉 router 已服务的 `POST /sessions`、`GET /sessions/{id}`、`/history`、`/steer`、`POST /threads`、`GET /threads/{id}`、`GET /inventory/sessions`。在 HTTP 层 additive merge（冻结 `pharos-api` stub 未改，已有 method 不被覆盖），新增独立测试逐条枚举 `api_router` 全部路由并断言文档存在。

## 5. 独立真实二进制 live 验证

- 用本 worktree 新构建的 `rust/target/debug/pharos-web` 在 **18792**（v4 loopback，data dir `/Users/baixianger/personal/pharos-evidence/2026-11-11_client-check/data-client-polish-web`，`--fake`）全新启动：`GET /openapi.json` → 27 paths、期望 37 个 (path,method) 组合缺失 0；随后真实 HTTP 写：`PATCH config mode=yolo`、`POST stop`、`POST revive`、`PATCH members/human avatarShape/Color`、`PUT threads/{id}/bindings/{member}` 全部 200 且落盘 `member-settings.json` / `thread-bindings.json`。测后 SIGTERM、端口 0 listener（仅停自己起的进程）。日志：`pharos-evidence/2026-11-11_client-check/logs/pharos-web-18792.log`。
- Swift ClientKit live smoke（`PHAROS_SMOKE_BASE_URL=http://127.0.0.1:18791`，评估阶段已启动的 fake 测试服务，只读写该测试 data dir）：`swift test --filter HttpPharosClientLiveSmokeTests` → **2/2 passed**（列表/读线程/发送 + config/stop/revive/member/附件上传→发送→列表→元数据→内容/绑定/审批快照/health 全 round-trip）。
- 未使用 8787（追思 demo，只读探测过：`GET /health` 返回 404 `{"error":{"code":"NOT_FOUND","message":"接口不存在"}}`，正是 client 默认端口连错时需要可发现的场景）、未使用 3080/18790 写操作、未碰用户 `~/.dsh`、`~/.gemini`、`~/Library/Application Support/Pharos`。

## 6. 门禁（最终代码 `d2224e7`；`rust/` 下 `CARGO_BUILD_JOBS=3`）

- `cargo fmt --all -- --check` → **PASS**（exit 0）
- `cargo clippy --workspace --all-targets -- -D warnings` → **PASS**（exit 0，0 warning）
- `cargo test --workspace` → **PASS**（400 passed / 0 failed / 0 ignored / 62 suites，含 `pharos-web` `asset_sync`）
- 仓库根 `swift build` → **PASS**（0 warning）
- `swift test`（全量）→ **PASS**：PharosTests **55** + PharosClientKitTests **58**（2 个 env-gated live smoke skipped）/ 0 failed
- `swift test --filter ArchitectureBoundary` → **PASS**（4/4）
- `swift test --filter PharosClientKitTests` → **PASS**（58，2 skipped，0 failed）
- `integrations/dsh-plugin-pharos` `npm test` → **PASS**（30/30）
- `node --test Tests/WebCanvas/transport.test.mjs` → **PASS**（16/16）
- `diff -r webui Sources/Pharos/Resources/WebCanvas` → 空（逐字节一致）

## 未验证 / 限制

- **未启动/驱动打包后的 macOS GUI**：评估阶段已知该机 raw binary 会因 bundle/notification/display 问题无法可靠截图（FINDINGS §GUI driving）。native state → bundled workspace 的契约由新增 WKWebView bridge 测试覆盖，ClientKit HTTP 行为由 58 个测试 + live smoke 覆盖；但没有一次人工 GUI 验收。
- **真实 vendor adapter 成功路径未跑**：真实 adapter 目前不声明 config 写入/附件摄入/stop-revive 能力，因此真实后端这些操作按设计是诚实 502（ClientKit 502 透传由 stub 测试覆盖；成功路径只有 `--fake` 测试服务覆盖）。
- **跨机 mini↔Air 真实会话未跑**（本流规则不做；cross-host 流另有证据）。
- **8787 误连文本未通过 ClientKit 对真实 8787 进程实测**（仅 curl 确认其返回非 Pharos 健康体；guidance 逻辑由单测覆盖）。
- `/openapi.json` 的 live 验证用的是本 worktree 新二进制（18792），不是评估阶段遗留的 18790/18791 旧二进制；旧进程仍按旧路由集合服务。
- 真实后端 18790 只做过只读探测，未写入。
