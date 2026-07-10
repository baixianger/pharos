# mesh skill v2 — Pharos 自包含 skill 设计稿

状态：DRAFT（2026-07-10，源自 mesh 验收 session；跟踪：brainstorm#2，关联 Pharos#5）

## 定位与边界

- **spawn-claude-tmux**（用户级独立 skill）管"机器"：ssh/tmux/keychain 通用基建，零 Pharos 依赖。
- **mesh skill v2**（本设计）管"项目/议题"：为 issue 起 worker、代理讨论、跨机协作。
  自包含 = skill 文档 + pharos CLI 一起由 **Pharos.app 分发**，没有游离脚本。
- 依赖箭头永远单向：mesh v2 → pharos CLI。host/项目解析用 Pharos 注册表
  （projects.json + HostIdentity 的 per-host localPath），不问、不猜、不用 agent memory。

## 1. CLI 扩展（特性以子命令迁移，不拷贝 shell 脚本）

关键洞察：`pharos launch <project> <agent> [--tmux]` 和 `pharos issue start <project> <#> <agent> [--tmux]`
**已经存在**（本地）。v2 不造新命令空间，只补跨机维度：

```
pharos launch <project> <agent> [--tmux] [--host <alias>]
pharos issue start <project> <#> <agent> [--tmux] [--host <alias>]
pharos agents [<project>]           # 列出运行中的 agent tmux 会话（本机+已配置的远端）
pharos agent peek|say|kill <session> [--host <alias>]   # 驱动（对应 cc-tmux 的 peek/say/kill）
```

`--host <alias>`：

1. 用 HostIdentity 把 `<project>` 解析成**那台机器**的 localPath（没有 → 明确报错，提示 `pharos path`）。
2. SSH 到 alias，在**远端 tmux server** 起会话跑 `claude --remote-control … --dangerously-skip-permissions`。
3. **keychain 就绪**（从 cc-tmux 移植为 Swift 原生，Process 驱动）：
   - probe：`tmux run-shell 'security show-keychain-info … 2>&1'`（先捕获再判断，不直连管道）；
   - 锁定且本机 keychain 有 `host-<alias>` 条目 → throwaway pane 解锁（密码走 tmux buffer，永不 argv/ps）；
   - 顺序铁律：先建会话保住 server → 解锁 → 再启动 claude（解锁随 tmux server 存亡）。
4. RC URL 提取并打印（安全阀，必须回显给人）。
5. `--issue` 场景沿用现有 per-issue session 跟踪（v1.7 reconcile 机制对远端 tmux 的扩展是子任务）。

已验证的实现细节（全部踩过坑，见 spawn-claude-tmux/references/mac-keychain.md）：
远端引用一律单引号包裹（zsh 等号展开）；claude 首次登录成功后落盘
`~/.claude/.credentials.json`，之后 boot 不依赖 keychain（解锁仍为 ssh key / security 读取服务）。

## 2. skill 分发（app 是安装通道）

- skill 文件进仓库：`Sources/Pharos/Resources/skills/mesh/`（SKILL.md + references/），
  随 app bundle 打包。
- app 启动时安装/升级到 `~/.claude/skills/mesh/`：写 `.version` 戳（app 版本），
  仅当 bundle 版本更新时覆盖 —— 与 MeshHooks 安装 SessionStart/Stop hooks 同一职责、同一时机。
- 多机一致性 free：每台装了 Pharos.app 的机器自动拿到同版本 skill。

## 3. skill 文档（v2 重写要点）

- 现有 mesh 原语（join/say/ask/wait，--session 精确寻址）保留为核心。
- 新增"为 issue 派 worker"一节：`pharos issue start <proj> <#> claude --tmux --host <alias>`
  —— agent 只需要知道项目名和 issue 号，机器/路径/keychain 全部 CLI 内部解决。
- Mode B（代理讨论）升级：委托方可以直接用上面的命令在**目标项目所在机器**起 delegate。
- 渐进披露：正文只留原语和决策树；跨机/故障排查进 references/。

## 4. 与 Pharos#5（双 hub）的联动

- P3 的 `mesh-endpoint` 配置文件（Application Support）由 app 写、CLI 读（env 仍可 override）——
  卫星机 agent 零配置跟随 hub。此文件落地后撤掉 home-ts `~/.claude/settings.json` 里手工加的
  `PHAROS_MESH_TCP`（2026-07-10 临时措施，hub 迁移时会变陈旧）。

## 实施顺序 & 状态

1. ✅ CLI：`launch --host` + `issue start --host`（**DONE 2026-07-10**，`RemoteLaunch.swift`）
   端到端实测：`pharos launch "World Monitor" claude --host home-ts` → 白富贵路径解析 →
   keychain 自动解锁 → READY + RC URL。issue start 远程分支：状态置 In Progress、
   发 brief、**不做 session link**（本地 reconcile 只看本机 tmux，会误清远程链接——见后续项）。
2. ⬜ CLI：`agents` / `agent peek|say|kill` —— 驱动面
3. ✅ 分发通道**已存在**：`SkillInstall.swift` 把 repo `skills/` → app bundle →
   symlink 进 `~/.claude/skills/`（symlink 意味着装好的 app 永远是当前版本，无需 .version 戳）
4. ⬜ skill 文档 v2 重写（`skills/mesh/`，教真实存在的命令）
5. ⬜ Pharos#5 P1-P3

## 实施中发现的后续项

- **远程 reconcile**：issue↔session 链接要支持远端 tmux（reconcile 需按 host 分桶探测）
- **改名残留**：白富贵的 localPaths 挂在旧名记录（world-monitor）上，改名后的
  "World Monitor" 没继承 —— rename 迁移或 iCloud 合并问题，待查（已提 Pharos issue）
- **PHAROS_HOST override** 可以从任一台机器代注册别机路径：
  `PHAROS_HOST=白富贵 pharos path <project> <dir>`（文档值得记录）
