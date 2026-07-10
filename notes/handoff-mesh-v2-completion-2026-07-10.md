# Handoff — mesh v2 收尾（部署 + Pharos#5 P2 + 远程 reconcile + Pharos#6）@ 2026-07-10

## TL;DR

mesh v2 的步骤 1–4 已全部落地实测（`launch/issue-start --host`、`agents`/`agent` 驱动面、
skill 文档 v2、Pharos#5 的 P1+P3），代码在 main（`44d5f60`…`a4852c1`，未 push，无远程）。
剩四件事：**T1 部署新 app 到两台机 → T2 Pharos#5 P2（同步 hub 身份）→ T3 远程
reconcile → T4 Pharos#6（rename 路径残留）**。按 T1→T4 顺序做，T1 最先（后面都要新 app 在跑）。

## 背景（零上下文读者需要知道的）

- 两台 Mac：**mac-mini**（本机，Tailscale 100.123.131.117，host key `Xiang’s Mac mini`）
  和 **home-ts**（ssh alias；MacBook Air，100.91.91.43，host key **白富贵**）。
- mesh = agent 聊天室。拓扑：mac-mini 是唯一 hub（GUI hostMesh=1，broker 绑
  `<tailscale-ip>:47800` + 本地 UDS）；home-ts 是卫星，agent/hook 拨号 hub。
- 拨号解析（本次新增）：env `PHAROS_MESH_TCP` > `~/Library/Application Support/Pharos/mesh-endpoint`
  文件（GUI 配对时写，hub 机清除）> GUI 内存解析。**绑定**仍 env-only。
- `pharos launch <proj> claude --host <alias>` / `issue start … --host` 在远端 tmux 起
  claude：注册表按 host key 解析路径 → keychain 自动解锁（本机 keychain 条目
  `host-<alias>` 存对端登录密码）→ RC URL 打印。驱动：`pharos agents` /
  `agent peek|say|kill [--host]`。
- 跟踪：brainstorm#2（v2 主线）、Pharos#5（双 hub）、Pharos#6（rename 残留）。
  设计稿 `notes/mesh-skill-v2-design.md`（含状态区和后续项）。
- 汇报习惯：每完成一块 `pharos update add <proj> "…" --issue <n>`。

## Next session — 按序执行

### T1 部署（先做；15 分钟 + 一次人工确认）

1. `pharos mesh list` 看有没有活跃成员的房间（形如 `omika [lelantos]`）。
   **hub broker 重启会清空内存房间** — 有活人就先问用户挑时机。
2. mac-mini：`./Scripts/dev.sh`（构建+打包+ad-hoc 签名+启动）。启动后验证：
   `pharos version`（应不再是 0.2.0 旧行为，`pharos agents` 子命令存在）；
   `lsof -iTCP:47800`（hub 仍在监听）。
3. home-ts：`./Scripts/package_app.sh release` 后
   `rsync -a --delete Pharos.app home-ts:/Applications/`（先 `ssh home-ts 'pkill -x Pharos' 2>/dev/null`；
   注：不知道 home-ts 的 app 当初怎么装的，rsync 整个 .app 是安全默认）。
   用户在远程桌面里启动一次 Pharos.app（GUI 配对 → 写 mesh-endpoint 文件）。
4. 验证卫星零配置：`ssh home-ts 'cat ~/Library/Application\ Support/Pharos/mesh-endpoint'`
   应为 `100.123.131.117:47800`；`ssh home-ts '/opt/homebrew/bin/pharos mesh list'`
   （无任何 env）应显示 hub 房间。
5. 然后撤掉临时 env：`ssh home-ts` 用 python3 从 `~/.claude/settings.json` 的 env 块
   删除 `PHAROS_MESH_TCP` 键。再跑一次第 4 步验证。
6. `pharos update add Pharos "部署完成…" --issue 5`。

### T2 Pharos#5 P2 — 同步 hub 身份（核心剩余工程，~1-2h）

目标：「谁是 hub」成为 iCloud 同步 store 里的**单一事实**，两台机读同一个答案，
双 hub 在数据模型上不可能。

1. `Sources/Pharos/ProjectStore.swift:10` `struct StoreData` 加 `var meshHubHostID: String?`
   —— **tolerant decode**（仿照现有字段的 `decodeIfPresent` 风格，老数据不炸）。
2. 派生判断：`store.isMeshHub = (storeData.meshHubHostID == HostIdentity.current)`。
   迁移：load 时若 UserDefaults `pharos.hostMesh`==true 且 meshHubHostID==nil →
   写 meshHubHostID=当前 host、清掉 defaults 键（`ProjectStore.swift:475` 是旧 hostMesh）。
3. `SettingsView.swift:190` 的 hostMesh Toggle 改语义：开 = `meshHubHostID = 我`（顶掉
   别人），关 = 置 nil。文案提示"整个配对里只有一台 hub"。
4. `PharosApp.swift` `.task`：`apply(hosting: store.isMeshHub)` else `demoteStrayHub()`
   （现在还挂在旧 `store.hostMesh` 上）。被顶掉的旧 hub 下次启动走 else 分支自动降级 ✓。
5. `MeshRemote.swift:33` 删掉 "local broker wins"（`resolve` 开头的 UDS 短路）——
   改为 config wins：`isMeshHub` → nil（用本地）；否则拨 peerHost。
6. 双机测试：mac-mini Settings 开 hub → home-ts GUI 显示同一 hub 且拨号；再从
   home-ts 抢 hub → mac-mini 重启后自动降级、mesh-endpoint 文件方向翻转。
   注意 iCloud 同步有秒级延迟。

### T3 远程 reconcile（issue↔session 链接支持远端 tmux，~1h）

现状：`issueStart --host` 分支**刻意不 link**（`PharosCore.swift` issueStart 内有注释），
因为 `reconcileAgentLinks`（`ProjectStore.swift:341`，调用点 :581/:1144）只拿本机
tmux 的 live set（`LaunchService.runningSessions()`），远程链接会被误清。

1. 链接带 host：`linkIssueSession`（`ProjectStore.swift:300`）加 `host: String?`
   字段（tolerant decode）。
2. reconcile 按 host 分桶：本机桶用现有 live set；远程桶
   `ssh <host> 'PATH=…; tmux list-sessions -F "#{session_name}"'`（超时 5s）——
   **unreachable ⇒ fail-open 不清**（宁可链接陈旧，不可误清，v1.7 的既定原则）。
3. 打开 issueStart 远程分支的 link（删掉 skip + 注释），传 host。
4. 测试：`issue start brainstorm 2 claude --host home-ts`（或建个测试 issue）→
   GUI 里 issue 显示 running → `agent kill` → 下次 reconcile 链接清除。

### T4 Pharos#6 — rename localPaths 残留调查（~30min）

现象：iCloud store 里名为 `world-monitor` 的记录带 `白富贵` 路径，改名后的
`World Monitor` 没继承（当时用 `PHAROS_HOST=白富贵 pharos path …` 绕过了）。

1. 读 `PharosCore.renameProject` + GUI rename 路径 —— rename 是改 `project.name`
   还是新建记录？查 store JSON：
   `python3 -c "import json;d=json.load(open('/Users/baixianger/Library/Mobile Documents/com~apple~CloudDocs/Pharos/projects.json'));print([ (p['name'],list(p.get('localPaths',{}))) for p in d['projects'] if 'world' in p['name'].lower()])"`
   也查 `trash`/重复记录。
2. 假设 A：rename 原地改名、残留是 iCloud 双机合并的重影 → 需要去重逻辑或手工清理。
   假设 B：某路径 rename 走了 remove+add → localPaths 丢失 → 修迁移。
3. 修复 + 给 store 写一次性清理（或手工清掉重影记录），关 Pharos#6。

### T5 小尾巴（顺手）

- 反向解锁实测：需要人**在 home-ts 上**发起 `security find-generic-password -s
  host-mac-mini -w | cc-tmux.sh unlock -H mac-mini`（条目已种好）。完成后更新
  agent memory `spawn-hosts-projects`。
- 版本号：`Sources/Pharos/CLI.swift` 里 `version`（现 0.2.0）→ 0.3.0，随 T1 部署走。
- 全部完成后：brainstorm#2 置 done，Pharos#5 置 done。

## Key files

| Path | 说明 |
|---|---|
| `notes/mesh-skill-v2-design.md` | 设计稿 + 状态区 + 后续项（本 handoff 的上游） |
| `Sources/Pharos/RemoteLaunch.swift` | 远程 launch/驱动面全部实现（keychain/坑的注释都在） |
| `Sources/Pharos/MeshRemote.swift` | resolve/probe（T2 第 5 步改这里） |
| `Sources/Pharos/MeshHosting.swift` | apply + demoteStrayHub（T2 第 4 步关联） |
| `Sources/Pharos/MeshBroker.swift` (MeshPaths) | dialEndpoint / endpointFile / setDialEndpointFile |
| `Sources/Pharos/ProjectStore.swift:10,300,341` | StoreData / linkIssueSession / reconcileAgentLinks（T2/T3） |
| `Sources/Pharos/PharosCore.swift` (launchAgent/issueStart) | --host 分支（T3 打开 link） |
| `Sources/Pharos/SettingsView.swift:190` | hostMesh Toggle（T2 第 3 步） |
| `skills/mesh/passive-join.md` | skill 文档 v2（symlink 分发，改 repo 即生效） |
| `~/.claude/skills/spawn-claude-tmux/references/mac-keychain.md` | keychain 模型手册（独立 skill，别把它引入 Pharos 依赖） |

## Gotchas / don't do X

1. **hub broker 重启清空房间**（RAM 态）。部署/重启前 `pharos mesh list` 看活跃成员。
2. **远端引用一律单引号包裹**——zsh 会对 `=name` 做等号展开（RemoteLaunch.sq 已处理；
   手写 ssh+tmux 时别用 `printf %q`）。
3. **`tmux run-shell` 输出别直连管道**，先捕获到变量再匹配（会静默丢失）。
4. **keychain 解锁是 per tmux-server security session**，随 server 存亡；探测要在
   server 会话里做（plain ssh 永远显示 locked）。顺序：先建会话→解锁→再启动。
5. **reconcile fail-open**：远端 unreachable 时绝不清链接（误清比陈旧糟糕得多）。
6. **StoreData 改 schema 必须 tolerant decode**（v1.1 规矩），iCloud 上有旧数据。
7. 个人项目身份规矩（CLAUDE.md）：bundle `me.pai.pharos`、作者 Pai、别碰公司身份。
8. commit 风格：conventional（feat/fix/docs + scope），中文正文 OK，带
   `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。

## Branch state

- Branch：`main`，无远程（本地仓库），working tree clean。
- 本轮 commits：`44d5f60`（launch --host）→ `bef1371`（agents 驱动面）→
  `55c985b`（skill 文档）→ `1ca2d1a`（Pharos#5 P1+P3）→ `a4852c1`（设计稿状态）。

## Test / verify（回归速查）

```sh
swift build                                             # 编译门
P=./.build/debug/Pharos
$P launch "World Monitor" claude --host home-ts         # 端到端（READY + RC URL + keychain 行）
$P agents --host home-ts                                # 驱动面
$P agent kill pharos-world-monitor-claude --host home-ts
$P mesh list                                            # hub 房间（UDS）
ssh home-ts '/opt/homebrew/bin/pharos mesh list'        # 卫星视角（部署后应零 env 直达 hub）
```

## References

- brainstorm#1（独立 skill 定稿记录）、brainstorm#2、Pharos#5、Pharos#6（`pharos issue list …`）
- agent memories：`mesh-cross-host-session-addr`、`macos-keychain-session-scoped`、
  `spawn-hosts-projects`、`skill-architecture-plan`（自动加载于 MEMORY.md）

---

## ✅ 完成记录（2026-07-10 当日收尾 session）

全部四件事完成 + 全量回归通过。要点：

- **T1** v0.3.0 部署双机（/Applications 两侧 + CLI symlink 同源）。satellite 现在**启动即配对**
  （不再依赖打开 Rooms 视图），endpoint 写入 fail-open。home-ts 的临时 PHAROS_MESH_TCP env 已删。
- **T2** meshHubHostID 进同步 store；双向抢 hub 实测通过（降级 + endpoint 方向翻转）。
- **T3** 远程 reconcile 实测通过（issue start --host → link 带 host → kill → sweep 清理 + Agent finished）。
- **T4 真相**：Pharos#6 不是 rename bug —— **CLI symlink 的 UserDefaults 域错位导致双注册表分叉**
  （CLI 写 App Support、GUI 写 iCloud）。已修（PharosPrefs.shared）+ 数据统一
  （备份：projects.json.pre-unify-backup-20260710，两处）。
- **T5 遗留一件**：反向解锁（home-ts→mac-mini）**被阻塞**——home-ts 上根本没有 host-mac-mini
  keychain 条目（handoff 里"条目已种好"不实）。种它需要 mac-mini 登录密码 → 人工步骤：
  在 home-ts 上 `security add-generic-password -s host-mac-mini -a baixianger -w`（交互输密码）。
- brainstorm#2、Pharos#5、Pharos#6 全部置 done。commits：`edbf199`（0.3.0）→
  `cae44de`（P2+远程reconcile）→ `cf23fbc`（prefs 域修复）。
