---
summary: Historical WIP research and validation from before the Rust migration; current implementation may differ.
---

# 讨论记录：工单、门槛与 worker 工作质量（2026-11-11）

状态：想法草稿，排在 Rust 后端迁移（RFC-007）之后。未提交、未 push。
来源：用户与 Pharos（PM）2026-11-11 凌晨讨论，起因是 DeepSeek 开源的 `dsh-superagent-prototype`。
研究报告（Page）：https://cursor.com/canvas/store-57293075-3e3f-43db-9dcd-c48ddaba94e0/de110096-a7e0-45bd-a528-1fda6b44e0bd
源码浅克隆（box）：/workspace/pharos-research/2026-11-11_dsh-superagent/src （提交 8c32a9d）

## 1. dsh-superagent 是什么
- 不是提示词合集，是一个常驻后台的 AI 助理程序：盯着 IM 和 GitHub 通知，把活派给 worker，做完替 worker 回复人。
- 结构：一个 Router（只负责沟通、派活）+ 多个 Worker（每个任务一个 session、一个 git worktree，不直接对人说话）。
- 本质上就是 Pharos PM（Grok Bot）现在干的事；区别是它把规矩写进代码，而不是靠 agent 自觉。

## 2. 核心结论：把 gate 从"自觉"搬进"代码"
- 现在 Pharos PM 的门槛（只在测试目录发真消息、不 push、不碰公司电脑、不假装投递成功）都写在规矩里，靠自觉遵守。
- 目标：系统不让做，而不是"我答应不做"。换谁当 PM 都一样安全。
  - 工具权限按角色分：沟通层拿不到写文件工具。
  - 动手前先开授权单（Mandate）：谁要求、按哪条规则放行、允许动多大范围。
  - 超出范围直接拒绝；回复超字数直接发不出去（工具层限制）。

## 3. 讨论 vs 干真活
- 讨论：Thread 里随便聊，不留手续，不动任何东西。
- 干真活：改代码、跑命令、发消息，必须开一张工单 → 过门槛 → 留记录 → 派给隔离的 worker。
- 原则：聊天自由，动手严格。现状问题：@ 一下 agent 它可能直接开干，两者混在一起。

## 4. 工单（Ticket）模型
- 不是每个 Thread 一张，而是每件"要动手的事"一张；一个 Thread 下可挂多张工单。
- Thread = 上层聊天记录 + 下层挂着的工单列表（状态：待办 / 在做 / 做完 / 已过滤）。
- 工单记录：来源消息、请求人、放行规则、允许范围（目录/机器）、负责 worker、结果。
- 该工单的后续消息直接路由给接单的 worker（订阅直通），不经 PM 转手。
- 没被放行的消息也记录，状态 filtered + 原因。
- 任何改动都能追溯：谁、为什么、凭什么。

## 5. 委派新 worker 也走工单
- 开 worker = 花额度 + 占机器 + 给权限，所以本身就是"干真活"。
- 记录：谁让开的、属于哪张工单、用哪个 agent（Codex / Cursor / dsh / agy）、哪台机器、能动哪个目录、何时算完。
- 好处：不会有没人管的 worker；开之前按额度规则挑 agent；工单关闭时回收 worker 和 worktree。
- 现在 Rust 迁移里手工开 Cursor agent 就是这个流程的人工版，以后由 Pharos 自动按工单执行。

## 6. 记录每个 worker 的工作质量
- 工单关闭时自动打分，只记客观数据：
  - 首次交付是否通过验收；
  - 被退回几次、原因；
  - 用时、额度消耗；
  - 是否越界（改了范围外的文件等）。
- 例子（2026-11-10 Rust 第二批）：cli-thread 首交代码检查（clippy --all-targets）不过被退回；adapter-codex 5 次真机测试挂 1 次被退回。
- 用途：积累后看出哪个 agent 适合哪类活，派活按成绩 + 额度挑，而不只看额度。
- 用户反馈：Antigravity "丢三落四"。有记录后可以量化（例如 N 张工单里几张漏了验收步骤），规则可写成：Antigravity 额度多但只派简单、好验收的活（调研、文档）；核心代码交给 Codex / Cursor；成绩变好再放宽。

## 7. 其他可借鉴点（来自研究报告，均已在源码核实）
- 给提示词写测试：提示词里的工具名、参数、字数必须与代码一致，否则测试失败。
- 文档守卫测试：新增源码文件未登记到架构文档则测试失败。
- 健康检查退出码 0/1/2/3：正常 / 可重启修复 / 外围组件故障需人看 / 等待配置需人看。
- 前台命令超 5 秒自动转后台，新消息不被长命令卡住。
- 事件攒批处理（webhook 几秒内合并）。
- 报告分五档 + 单独的"需要人回答的问题"字段。

## 8. 下一步（待用户确认）
- 写成正式 RFC（工单 / Mandate / worker 生命周期 / 质量记录），排在 RFC-007 Rust 迁移之后。
- 落点建议：Mandate + 工单 → Rust 后端 Thread/HITL；worker 生命周期 → Runtime；质量记录 → store schema 新表。
