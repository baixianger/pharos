---
summary: Projects associate Sessions by stable UUID and host-local checkout maps, and show hosts whose checkout mapping could not be read.
---

# Project 与 Session 关联

**Peer 进度（2026-11-08）**：Host 从本机 Pharos 偏好读取 checkout UUID→路径，经受认证 Peer 查询提供给桌面，桌面仅在必要时保留 SSH 只读备用。本机 loopback 与实际偏好对照得到 361 条；受控后台 socket / Iroh 和错误路径测试通过。实际远端 Host、完整桌面项目跳转及备用尚未验收，见 [交接](handoff.md)。

**远程架构偏差（2026-11-08）**：现有实现经 SSH 直接读取远端 Pharos 偏好中的 checkout 映射，而非请求远端 Pharos 服务；此前远程项目跳转验证仍是旧路径证据。目标为由远端 Pharos 提供 host-scoped 项目关联和 Session 信息，详见 [架构决策与审计](RFC-006-UNIFIED-CLIENT-AND-BACKEND-INTEGRATION.md#remote-pharos-boundary-and-current-deviations)。

项目来自本机 `ProjectStore`，项目 UUID 是稳定标识；路径变更不会改变选中项。项目可展示已发现且与已知 checkout 匹配的本机或远程 Session，并跳转到该会话；活动状态显示来源提供的值，未知即 unknown。列表数量表示当前清单中发现的匹配数，不冒充活跃数或完整总量。清单尚未加载时显示加载状态，没有可用 checkout 时明确提示。

关联按项目 UUID 与 Session 所在 Host 的 checkout 绝对路径匹配，路径先做词法标准化；匹配项目根目录或有路径分隔符的子目录。多个项目嵌套时分配给最长匹配根；相同最长路径有多个项目时不自动归属。不会根据不同主机恰好相同的路径推断项目身份。Host-local 路径由 `HostLocalProjectPaths` 保存在各主机本地，便携注册表不包含这些路径；对明确映射到可信设备的远程主机，桌面优先经其 Pharos Host 只读获取项目 UUID→路径；Peer 不可用时可使用已配置的 SSH 只读备用。两条路径均不可用或没有映射时，该主机归属未知，不沿用旧快照。

`DesktopPharosClientServiceTests.testProjectAssociationsRespectHostPathBoundariesAndStableIDs` 覆盖路径边界、嵌套、同路径歧义、远程同路径排除、未知清单与稳定 ID。`testProjectAssociationWithRealSessionInventoryWhenEnabled` 在隔离 ProjectStore 中按真实本机 Session 的 workspace 创建测试项目，确认实际清单中 12 个匹配；这是只读会话发现与临时项目映射，不代表真实用户项目全部正确关联。`WorkspaceWebViewTests.testProjectSessionOpensTheSelectedConversation` 用模拟清单验证项目列表、unknown 状态、打开准确 Session 和缺少本机路径提示；物理鼠标、用户真实项目全量数据和加载失败/重连仍待验收。

Codex 的 `notLoaded`、`systemError` 和缺失状态现映射为 unknown，不再统一标为 idle；状态枚举核对了本机 0.166.0 生成的 App Server schema。项目头像仍优先读取 UUID 设置，并回退读取旧的本机路径键，避免项目 ID 改动后已有头像丢失。真实完整清单可能因某些后端不可用而不完整；空列表只表示当前清单没有匹配。

## 2026-11-07 远程 checkout 映射

`RemoteProjectPaths` 对 `hosts.json` 配置的 SSH 目标只读运行固定命令，在远端提取 Pharos 偏好中的 `pharos.localProjectPaths.v1`；仅项目 UUID→路径映射经 SSH 返回，不写远端数据、不输出或记录路径值。远端需要 macOS 的 `defaults` 和可用的 `/usr/bin/python3`。输入限制大小和超时；无效 UUID、非绝对路径、重复规范化 UUID 不参与关联。每次清单刷新重新读取，读取失败不使用先前快照；当前界面无法区分未配置与暂时不可达，已知主机列表和 Session 数不能当成完整清单。

mac-air 实际读取 78 个路径条目，并在 186 个发现的远程 Session 中找到与其中一个项目 UUID 的 checkout 相匹配的 Session；测试在隔离 ProjectStore 中构造该 UUID 的测试项目，确认生产桌面服务关联成功。首次测试误把 SSH 别名当作规范主机名，得到零会话并跳过，修正为查 `hosts.json` 后通过。mac-pro 的偏好中未取得映射；不等于其没有项目。`testRemoteProjectPathMapRejectsInvalidAndAmbiguousEntries` 和项目映射测试覆盖无效数据、跨主机同路径、远程独有项目及歧义；WebKit 模拟测试验证可从远程项目打开正确 Session。真实用户注册表全量对应和 SSH 断线恢复仍未验收；真实远程项目打开 Session 的程序驱动测试见下。

## 真实远程 Project 打开 Session（2026-11-07）

`WorkspaceWebViewTests.testRealRemoteProjectOpensSessionWhenEnabled` 读取 mac-air 已有的 checkout UUID 映射和生产服务发现的远程 Codex Session，选择有可读取文本历史的匹配项，在内存 ProjectStore 中放入同 UUID 的测试项目。程序操作生产 WKWebView 项目列表中该 Session 的按钮，核对 Sessions 页选中同一带主机前缀的 ID，且渲染内容包含之前从该远程 Session 读取的历史片段。测试通过，原始摘要为 `internal/evidence/2026-11-07_remote-project-desktop.log`；未记录路径或对话正文，未发送消息。

该测试只覆盖一个可用的 mac-air Codex Session 和程序驱动 WebKit，不代表物理鼠标、DSH 或 Antigravity 的远程项目跳转、全部真实项目或网络故障恢复已验证。复现设置 `PHAROS_REMOTE_PROJECT_UI_TEST=mac-air` 并运行上述 Swift 测试；不存在可匹配且有文本历史的 Session 时标记 skipped。

## 2026-11-07 远程 DSH Project 探针

桌面探针支持 `PHAROS_REMOTE_PROJECT_AGENT=dsh`，并使用独立偏好域、临时项目注册表和隔离 Mesh 路径，仍只读取真实远程清单、checkout 映射及 Session 历史。mac-air 的本次测试发现 185 个带工作目录的 DSH 候选，其中 118 个路径匹配；没有读到文本历史：117 次历史读取报错，1 次没有文本。分类诊断为 116 次 `NSURLError -1011` 和 1 次未收到 DSH 快照，见 `internal/evidence/2026-11-07_remote-project-dsh-error-code.log`。测试被标记 skipped，不代表 Project 跳转通过，也不能据此断言远程 Session 没有数据。根因可能在 Host、隧道、复用流或批量读取流程，尚未确定；应先用单个既有测试 Session 对照连接和快照，再做受控连续读取检查。

相同隔离探针的 Codex 对照找到一项匹配并从真实远程 Project 打开该 Session、渲染历史，通过记录 `internal/evidence/2026-11-07_remote-project-codex-isolated-regression.log`。为隔离测试增加 `PHAROS_PREFERENCES_DOMAIN` 覆盖项；不设置时应用偏好域不变。测试起初未设置禁通知环境，裸 XCTest 因缺少通知 bundle 崩溃，随后才加隔离后重测。那次 `ProjectStore.init` 在崩溃之前执行了对实际 `me.pai.pharos` 偏好 `pharos.launchMeshAtLogin` 写入 true；其先前值未测，不能声称实际偏好未变化。测试未执行项目列表赋值或主动发送消息。

后续确认原批量错误并非所有远程历史不可读：已知测试 Session 的单次及五次连续读取均成功。将远程 `session/follow` 初始快照缩小后，首个问题 Session 的 407 条历史与已知 Session 前后读取均成功；桌面探针找到了匹配 DSH Session，但尚未确认点击后渲染，下一次探针远程 DSH 清单又为空。测试与边界见 [DSH Session 文档](agents/dsh/sessions/2026-11-07_protocol.md)，不能宣称远程 DSH Project 验收通过。

进一步对照：同一测试先用独立 SSH ACP 查询获得 mac-air 185 条 DSH Session，桌面服务随后查询的 SSH 进程以 255 退出，脱敏分类为 connection closed；服务没有获得 DSH 清单。重试和禁用 SSH 复用未改善，已撤回这两种改动。连接被关闭的原因及 UI 渲染失败仍未定位，详见 [DSH Session 文档](agents/dsh/sessions/2026-11-07_protocol.md)。

远程 DSH 清单短暂失败时，桌面服务保留已知 Session 和打开的服务，并将对应 Session 行标为清单暂不可用、最后已知；成功刷新替换清单，主机目标变更不沿用旧绑定。远端 checkout 映射失败时仍不使用旧路径推断 Project。服务生命周期与 WKWebView 标记由模拟测试验证；真实远程重试在故障注入前的首次历史读取失败，尚不能宣称端到端通过，详见 [DSH Session 文档](agents/dsh/sessions/2026-11-07_protocol.md)。

受控 SSH 对照发现，与 mac-air 保持一条独立会话时第二条独立连接被关闭，而复用第一条连接添加转发成功。远程 DSH Host 和它自己的转发已合并到一个受控 SSH 连接，单 Session 与正常释放实测通过；但完整桌面 Project 查询涉及其他独立远程服务，DSH 清单仍因 SSH 255 skipped。详情见 [DSH Session 文档](agents/dsh/sessions/2026-11-07_protocol.md)。

跨服务 SSH 连接共享及缩小 DSH 实时订阅首帧后，程序驱动生产 WebKit 已在 mac-air 从 Project 打开一个真实远程 DSH Session 并渲染历史；Codex 同一流程回归通过。连接建立、测试范围和剩余故障恢复见 [DSH Session 文档](agents/dsh/sessions/2026-11-07_protocol.md)；不代表所有 Project 或物理鼠标均已验证。

## 远程 checkout 映射不可用提示（2026-11-08）

远程主机 SSH 建连失败或 checkout 映射读取失败时，桌面服务在 Project 摘要中报告无法读取映射的主机；Project 页面提示这些主机的 Session 可能缺失，仍显示已有可靠映射的本地及其他主机会话。成功读取空映射不算失败；刷新恢复或主机从配置中移除后提示会随之清除。提示表示无法判断该主机是否属于当前 Project，不代表该主机一定存在相关 checkout。失败时仍不复用旧路径映射。

隔离桌面服务以无效 SSH 目标触发实际连接失败，核对首次失败的两个主机均出现在 Project 摘要；受控 WebKit 测试核对警告和已知会话同时显示、恢复状态清除（`internal/evidence/2026-11-08_project-checkout-final.log`）。真实 mac-air DSH 的 Project→Session 打开及历史渲染再次通过，成功读取的主机没有被误报为 checkout 不可用（`...project-checkout-real-regression.log`）。恢复时的真实网络连接替换及远程 checkout 指令单独失败尚未注入验证；Project Session 清单本身仍可能因各 Agent 清单不可用而不完整，不能把 checkout 映射成功视作清单完整。

## Project 的受控远程 SSH 重连（2026-11-08）

在 mac-air 分别选择一个实际 checkout 匹配且可读历史的 DSH 和 Codex Session，在隔离 ProjectStore 中放入同 UUID 的测试项目；生产桌面从 Project 打开并渲染该 Session 后，关闭本测试持有的共享 SSH 连接，触发生产服务刷新。两次均建立新的共享连接、重新取得非过期 Session 清单和 checkout 映射，项目仍关联原 Session，程序操作 WKWebView 再次从 Project 打开并渲染同一段历史。证据分别为 `internal/evidence/2026-11-08_remote-project-reconnect-dsh.log` 和 `...remote-project-reconnect-codex.log`；测试只读远程历史和映射，未发送消息，检查后未发现测试 scratch 残留。

这是应用主动关闭自有连接后的受控重建，不是物理断网、在途回合或断网时的编辑恢复；每家只验证一个匹配项目/Session，Antigravity 真实远程清单仍不可用，不能外推到其他项目或代理。此前提到连接替换尚未验证的结论由本次受控结果部分更新，真实网络故障和 checkout 指令单独失败仍待验证。

## 本机 Antigravity Project 到 Session（2026-11-08）

本机 Antigravity CLI 1.5.3 的真实清单中选取一个有绝对工作目录的 Session，在隔离 ProjectStore 中按其工作目录构造测试项目；生产桌面服务将该 Session 关联到项目，关联结果仅来自本机（`internal/evidence/2026-11-08_agy-project-live-inventory.log`）。另一个只读测试从真实清单找到可重放文本历史的本机会话，在隔离注册表中创建对应测试项目，经程序操作生产 WKWebView 从 Project 打开该精确 Session，核对选中 ID 与历史片段渲染（`...agy-project-desktop-live.log`）。没有发送提示或记录会话正文，测试配置和项目均为隔离数据并已清理。

这是每次各选一个真实本机会话的验证，不能证明所有用户项目、物理鼠标或远程 Antigravity；真实远程清单仍未取得，相关 Goal/Todo 和远程 HITL 保持未验收。路径边界与模拟 UI 回归见 `internal/evidence/2026-11-08_agy-project-regression.log`。复现需将 `PHAROS_PROJECT_LIVE_TEST=1` 与 `PHAROS_PROJECT_LIVE_AGENT=agy`，或 `PHAROS_LOCAL_AGY_PROJECT_UI_TEST=1`，分别配合独立 `PHAROS_REGISTRY`、`PHAROS_PREFERENCES_DOMAIN`、`PHAROS_HOSTS_FILE`、Mesh 数据目录及禁用通知设置。
