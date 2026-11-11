---
summary: Session composer needs per-agent dynamic permissions, model selection and attachment transport; current controls do not prove these capabilities.
---

# Session 输入能力与验证清单

用户要求输入框参考 DSH 的交互，按每个 Session 的真实 Agent 和主机动态提供权限模式、模型与附件，不把不同厂商的同名概念强行视为等价。保持右侧 Session 档案。范围仍限 CLI 或明确公开的协议，不接入厂商桌面 GUI 私有状态。

## 初始代码检查（2026-11-08，后续变更见下文）

- 右侧 Session 控件的模型选项来自 `ConversationDetailsView.availableModels` 硬编码；操作要求匹配 `sessionMember`，并以 Session 标题调用 `setMemberModel` / `setMemberMode`，桌面实现转给成员服务。这不是按真实 Session ID 获取各 Agent 动态目录和设置的证据。模式 UI 目前限制为 `safe` / `yolo`，不能表示各家真实权限能力。
- Codex 后端的 `selectSessionModel` 当前无实际设置，`setSessionMode` 对请求错误使用 `try?`；这不能证明生产路径能安全变更模型或权限。不得以现有控件或模拟测试声称已完成。
- Session 发送接口目前接受纯文本，输入框加号当前是 steer/queue 菜单；历史结构含附件不代表可从桌面发送。图片与普通文件均需分别验证，尤其跨机器传输不能直接复用本机文件路径。

## 待办与验收

- [ ] 以 Session ID 和所属主机获取每家当前能力、当前值及可选项；未知、不可用、加载失败与空列表区别呈现，不硬编码为共有模式。
- [ ] 在输入框提供各家原生可用的权限或执行策略；保留原生语义及作用范围，明确与逐次 HITL 审批、沙箱和模型工作模式的区别。设置失败可见，禁止吞错或虚报成功；验证生效时机、重新打开与不同 Session 隔离。
- [ ] 按各家实际目录提供模型选择及适用的 reasoning/effort；按精确 Session 和主机路由，显示真实当前值及切换失败，验证下一回合、运行中回合和重连语义。模型列表不等于账号实际有权使用该模型。
- [ ] 研究并实现各家可用的图片、文本文档及其他文件传输：选择/拖放、类型和大小、上传进度与失败重试、移除与提交、历史重放；原始数据和临时路径的生命周期须符合各家协议。
- [ ] 对本地和远程主机分别验证：本机附件不可默认视为远端路径；验证跨主机字节传输、Session 归属、可访问性和清理。能力不可获得时解释并记录，不伪造或静默降级。
- [ ] 三家分别以已授权、隔离的真实测试 Session 验证模式与模型的真实生效、图片/文件实际收发和历史；记录版本、数据路径、结果、未支持和未测情况。原始证据放 `internal/evidence/`，摘要写入各 Agent 的 `sessions/` 文档。

## 协议研究起点（待对照安装版本验证）

- DSH：上游 [Web 模型选择](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/client/ui-model-selection/README.md) 描述按 Session 和 provider 分组的模型与 effort；[附件子系统](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/attachment.md) 描述持久附件及按接收 Agent 绑定的上传。该文档是当前 master，不证明本机或 mac-air 旧版本具备相同 API 或效果。
- Codex：OpenAI [app-server 指南](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server) 描述 `model/list` 可供选择器使用，并明确目录不是权限保证。具体版本的图像、文件、设置和切换时机需核对其生成 schema 和真实服务。
- Antigravity：项目先前的 ACP `session/new` 已观察模型、模式和配置；[ACP 模式](https://agentclientprotocol.com/protocol/v1/session-modes)、[配置选项](https://agentclientprotocol.com/protocol/v1/session-config-options)和[Prompt](https://agentclientprotocol.com/protocol/v1/prompt-turn)说明通用协议的候选接口。本机及远程具体 options、设置 RPC、图片/资源内容和版本差异仍待重新核对，不根据 ACP 通用协议推断此 CLI 必然支持。

## 状态

Codex 输入区已按其原生 Goal 语义接入 `/goal` 查询、创建、暂停、恢复和清除；专用远程真实桌面已验证上述流程及已有目标拒绝与草稿保留。参见 [Codex Session 协议](agents/codex/sessions/2026-11-07_protocol.md)；各家命令语义仍需分别验证。

2026-11-08：需求已加入当前队列；初始代码检查和上游文档起点已由下列进展部分更新，三家动态权限、模型选择和附件发送的完整流程仍未全部实现或验证。后续按真实 Session 数据链、各家 HITL/Goal/Todo 工作并行相关性顺序继续，完成一项更新一项，记录限制。

用户再次确认：输入框须提供随真实 Agent 动态变化的权限与执行模式、可选模型，以及加号中的图片和文档等附件；逐家研究实际支持范围并完成可支持的传输，不支持或拿不到的数据如实记录。此项保留在队列中，不以已有局部实现视为整体完成。


### Antigravity 1.5.3 实测补充

本机隔离 ACP Session 的初始化声明图片和嵌入上下文能力，`session/new` 和 `session/load` 返回模式、动态模型和 `model`/`thought_level`/`mode` 配置。`plan` 设置响应成功后重载报告 `default`，尚不证明设置生效或持久。生产桌面已将该配置接入输入区并处理配置更新通知；本机真实 ACP 的模式和模型选择响应已验证，但推理实际生效、远程 SSH 和附件发送仍未验证。详见 [Antigravity Session 协议](agents/antigravity/sessions/2026-11-07_protocol.md)。


### Antigravity 输入区动态配置补充

真实 `agy 1.5.3` 的 `session/set_config_option` 使用 `sessionId`、`configId`、`value`，桌面输入区现在按返回的 select 配置生成模式、模型及其他选项，按精确 Session 更新并处理配置通知。本机真实 ACP 的 UI 切换模式和模型、返回值及无新增回合已验证；测试使用模拟清单和本地 ACP，不是远程 SSH 或推理生效验收。其余 Agent、权限策略、附件及重连仍待完成。详见 [Antigravity Session 协议](agents/antigravity/sessions/2026-11-07_protocol.md)。

本机真实 ACP 后续验证了嵌入式文本 resource 被模型读取；跨进程重放将其转换成普通文本，包含内容和 URI，但不保留原 resource 类型。生产发送和桌面附件尚未接入，须先处理 ACP 异步失败与草稿保留；图片和二进制未验证。详见 [Antigravity Session 协议](agents/antigravity/sessions/2026-11-07_protocol.md)。

后续已按 Session 声明的 `embeddedContext` 接入 UTF-8 文本附件；桌面等待 ACP 回合完成后清草稿，模拟拒绝保留文字和文件，本机真实 ACP 经 WKWebView 读取并回复文本内容。重放的资源类型丢失仍存在，真实远程、图片、PDF/二进制和断线恢复未验收。见 [Antigravity Session 协议](agents/antigravity/sessions/2026-11-07_protocol.md)。


### DSH 模型目录与切换

真实 mac-air 0.2.1-rc.2 可读取 provider 分组目录和指定 Session 的 next selection；输入区按 Session 显示 provider/model，不把全局默认值当作 Session 值；后续已接入模型切换与模型事件，并在输入区提示可能改变新 Session 的默认模型。隔离真实 DSH Host + mock 目录的桌面切换已验证；实际推理、远程 SSH、reasoning effort、附件及权限边界仍待完成；本机权限预设已接入，见下文。两次探针出现额外 journal 记录，其中一次确认为 `session/end-seed`，原因未明；详见 [DSH Session 协议](agents/dsh/sessions/2026-11-07_protocol.md)。


本机 DSH 0.2.2-rc.1 独立配置探针也可读取目录和 Session，但返回零 provider、无当前选择；仅代表该隔离配置，见 `internal/evidence/2026-11-08_dsh-local-model-catalog.log`。


隔离本机 DSH 0.2.2-rc.1 对 mock-two 的桌面切换证实 Session 变更及隔离 profile 默认值更新；显式 patch 固定默认值的对照未观察到默认更新，原因未明，因此 UI 明示“可能”而非保证。详情见 [DSH Session 协议](agents/dsh/sessions/2026-11-07_protocol.md)。


### DSH 权限预设接入

输入区现按 Host 目录显示 DSH Session 原生权限预设，完全权限和实验性 auto 需要界面确认；Session 命令成功后必须核对投影。独立本机真实 DSH Host 的只读、完全权限确认/取消/恢复流程已测，默认权限未变；mac-air 只读目录已测。未在远端或用户 Session 修改权限，auto 后端及权限生效的真实工具行为仍未验收。详见 [DSH Session 协议](agents/dsh/sessions/2026-11-07_protocol.md)。


### DSH 文件回执进展

本机独立 DSH Host 和 Session 服务已支持按 Session 暂存文件并提交文件回执；journal 可回放文件 ID/名称/大小，新 Host 启动后也读回附件 ID 和名称。文本与 PNG 的测试字节持久化和消息记录已核对，但 PNG 目前经普通文件通道，不证明图像理解；桌面选择、重启后下载字节及接收结果不明时的恢复仍未实现或验证。远程传输的后续结果见下文和 [DSH Session 协议](agents/dsh/sessions/2026-11-07_protocol.md)。

补充：mac-air 真实 DSH 上已验证服务将一份小文本文件跨 SSH 传送到专用 Session，模型回复其随机文件内容；独立 Host 亦能重放文件元数据及完成回复。其余类型、桌面入口、下载、断线和恢复仍待验证，详见上述协议文档。

后续已为 DSH 接入桌面选文件与提交：mac-air 真实模型经程序驱动 WKWebView 回复附件随机内容，受控测试覆盖失败保留和 Session 隔离。当前限制最多五个文件、合计 10 MB；系统选择器人工操作、拖放、图片视觉和其他 Agent 尚未验收。见 [DSH Session 协议](agents/dsh/sessions/2026-11-07_protocol.md)。

### 普通文本与 steer 草稿（2026-11-08）

Session 的普通发送和 steer 现与命令、附件一样按请求 ID 等待结果：失败保留草稿，确认成功才清除提交时未被编辑的文本；等待期间切换 Session 或编辑后改回原文也不会清除新的编辑。同一 Session 等待确认时不重复投递。程序操作 WebKit 的受控测试覆盖失败、成功、重复提交、编辑和切换；Codex 连接变化的生产桌面路径模拟测试确认错误可见、草稿保留且没有启动回合。线程输入不在本次改动范围。

Antigravity ACP 的 `session/prompt` 响应在回合结束时返回；桌面纯文本发送现等待该响应，以免异步拒绝后清空草稿。等待期间可编辑，但该 Session 的下一次提交要等当前结果。模拟 ACP 拒绝后文字和附件保留；本机真实 Session 经程序操作 WebKit 发起权限请求、拒绝并完成后，未更改的草稿清空（`internal/evidence/2026-11-08_session-text-draft-desktop-live-final.log`）。该次无后续助手正文，不能称为完整回复验证；首次真实测试因 XCTest 通知初始化异常中止，使用隔离配置禁用通知后复测通过。详情见 [Antigravity Session 协议](agents/antigravity/sessions/2026-11-07_protocol.md)。

ACP 结果丢失时，是否已执行可能未知；保留草稿不代表安全自动重试。真实断网、其他代理异步拒绝、跨进程草稿恢复和物理输入仍未验收。

另修复 steer 提交临时覆盖原回合 ID、失败后把原回合误标为停止的问题；受控视图模型测试覆盖失败后原回合仍运行以及原回合结束事件正确清除状态。steer 的真实断线和已接收但响应丢失仍未验收。

相关 ACP、Thread 桥、输入和状态回归共 38 项，其中 31 通过、7 项按环境条件跳过、0 失败（`internal/evidence/2026-11-08_session-text-draft-regression-complete.log`）。
