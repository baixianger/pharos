# Pharos Roadmap

**Pharos — your vibe coding project manager.** Mission control for running AI
coding agents (Claude Code, Codex) across many repos: launch, organize, resume,
and track agent work — in yolo mode, in parallel, at speed.

> **Status: v0.2 → v1.0 shipped.** All milestone goals below are implemented
> (build + 22 tests green). A few items need on-device verification or your
> credentials/decisions — see **Manual follow-ups**.

## The core loop

1. See every project + its activity at a glance. ✅
2. Launch an agent into any project (yolo / tmux / terminal / editor). ✅
3. **Resume** a past agent session (Claude + Codex). ✅
4. Run agents **in parallel** safely (worktrees). ✅
5. **Place & track** agent windows (desktops + running-agent dots). ✅\*
6. **Know** when an agent finished (notifications). ✅

\* Desktop placement uses private APIs — verify on-device.

## Milestones

### v0.2 — Resume & Parallel
- [x] Agent session browser + resume (Claude + Codex tabs, one-click resume).
- [x] Worktree manager (list/create/switch/remove; "new agent in a worktree").
- [x] Running-agent awareness (live `pharos-*` tmux dots + Attach).

### v0.3 — Cockpit
- [x] ⌘K command palette (fuzzy jump + per-project quick actions).
- [x] Menu-bar item (per-project launch submenus + Quit).
- [x] Notifications when an agent finishes.
- [x] Desktop/Space placement (private SkyLight; degrades gracefully). *on-device test*
- [x] Editor launch + per-project playbooks.
- [x] Multi-tab detail view (Overview / Git / Worktrees / Sessions).

### v0.4 — Ship-ready
- [x] Developer ID signing + notarization pipeline (`Scripts/sign-and-notarize.sh`, `docs/RELEASE.md`). *needs Apple creds*
- [x] Sparkle auto-update (dormant until keys configured). *needs EdDSA keys + appcast host*
- [x] Onboarding + real error states (alerts; launch/clone preflight).
- [x] Settings depth (terminal/editor/appearance/defaults, folder-scan, agent args, peer, MCP).
- [x] Tests (22) + CI runs `swift test`. (Strict concurrency blocked only by Sparkle's MainActor isolation — kept Swift 5 mode, documented.)
- [x] Performance: `AsyncSemaphore` caps concurrent git queries to 6 (was ~150 procs on launch).
- [x] Accessibility: labels on controls; decorative visuals hidden from VoiceOver.
- [ ] Localization (en/zh) — **deferred** (single-user tool; revisit if distributed).
- [ ] Cache git info across launches — **not done** (only the concurrency cap landed).

### v0.5 — Open & Connected
- [x] ~~MCP server (`Pharos --mcp`, stdio JSON-RPC)~~ — **superseded in v1.1 by the `pharos` CLI** (one front door; agents shell out, nothing preloaded into context). Removed 2026-06-20.
- [x] Multi-machine over SSH (peer-host git drift per project). *needs SSH host config + on-device test*

### v1.0 — Market
- [x] Landing page + screenshots (`site/` — drop real PNGs into `site/shots/`).
- [x] Licensing / pricing decision doc (`docs/LICENSING.md`) + placeholder `LICENSE`. *your call*
- [x] Cross-project status (open PRs + CI per repo via `gh`).

## Manual follow-ups (need your input or hardware)
- **Signing/notarization:** provide Apple Developer ID + a `notarytool` profile (see `docs/RELEASE.md`).
- **Auto-update:** generate Sparkle EdDSA keys, set `SUPublicEDKey` in `package_app.sh`, host the appcast (`docs/SPARKLE.md`).
- **Desktop placement & SSH peer:** verify on a multi-Space Mac / with a real `~/.ssh/config` host.
- **Landing screenshots:** drop real PNGs into `site/shots/x1–x3.png`.
- **Licensing:** pick an option from `docs/LICENSING.md` (current default: proprietary).

## What's genuinely next (post-v1.0 polish)
- Cache git/status across launches + debounce refresh.
- Localization if/when distributed.
- "Needs input" agent detection (not just "finished").

### v1.1 — Next (requested 2026-06-19)

**Design principle:** Pharos is **single-user** — a solo "vibe coder" driving AI
agents. Borrow Linear's *UX*, NOT its multi-user machinery: no teams, no
human assignees, no permissions/members, no collaboration. The only "who" that
matters is which **agent / session / worktree** is working an item.

- [x] **MCP → CLI tool (CLI is the core).** Logic lives in `PharosCore.swift`;
  the `pharos` CLI (`CLI.swift`) is the headless front door over it (the GUI is
  the other). Discoverable (`pharos help`), scriptable, `--json`-capable,
  testable (`PHAROS_REGISTRY` override), ships inside the app bundle.
  **MCP was then removed entirely (2026-06-20)** — the CLI is a superset, agents
  shell out to it, and dropping the server means nothing is preloaded into an
  agent's context (token savings). The roadmap originally said "don't drop MCP";
  this decision overrode that.

- [x] **Native issues & project log (Linear-style UX, single-user).** Shipped:
  per-project **issues** (number, title, status backlog/todo/in_progress/done/
  canceled, priority none→urgent, body — NO human assignees/teams) on `Project`,
  plus a **project-update feed** (notes + agent auto-posts). Logic on `StoreData`
  (pure, tested); GUI "Issues" tab + "Project Log"; full CLI (`pharos issue
  add|list|status|priority|start|rm`, `pharos update add|list`). Headline
  differentiator wired: `issue start` moves the issue to In Progress + links the
  agent session, and `ProjectStore.postAgentFinished` auto-posts an update when
  that tmux session ends. Issue deletes are soft (Trash, 30-day restore). Model
  kept clean for a possible future one-way Linear export (not built).

- [x] **Safe deletes — undo first, confirm by blast radius (safety).** Prefer
  reversible **soft-delete / trash with a restore window** over interruptive
  dialogs (blanket confirms cause click-through fatigue). Scale friction to
  consequence: "forget a project" (reversible) needs nothing; deleting files on
  disk or removing a worktree with uncommitted changes needs a strong confirm
  that **shows what's lost** (or type-to-confirm). Distinguish "forget" from
  "destroy." Pharos's OWN destructive ops (incl. yolo agents) should be
  reversible/auditable, not just guarded by a UI prompt. Audit all delete paths
  (`MCPServer.swift`, `ProjectStore.swift`, UI actions, issues).

**Suggested order:** safety → CLI → issues. *(All three done.)*

### v1.2 — Multi-machine & rich issues (requested 2026-06-20)

- [x] **Multi-machine sync (iCloud Drive) with per-host path auto-adapt.**
  Settings → Data location moves the registry into iCloud Drive (plain
  CloudDocs folder — no entitlement, any signing). Project *data* (issues, log,
  notes, tags) syncs; the machine-specific local checkout path becomes a
  **per-host map** (`Project.localPaths`, keyed by computer name via
  `HostIdentity`), resolved on load / captured on save in both `ProjectStore`
  and `PharosCore`. A project not checked out on this host shows "Set local
  folder…" (GUI) / `pharos path <project> <path>` (CLI); `pharos host` prints the
  key. Each Mac reads only its own path, so sync never clobbers it.

- [x] **Rich issue composer + attachments.** Modal composer (`IssueComposer`):
  title, multi-line body, priority, **image/file attachments** (drag-drop / file
  picker / paste; image thumbnails). `IssueAttachment` model; bytes stored via
  `AttachmentStore` under `<registry dir>/attachments/<issueID>/` (syncs with the
  rest of the data dir). CLI `issue add … --attach <file>` (repeatable). Trash
  parity: attachment files are retained while the issue sits in the Trash and
  swept only when it's permanently purged (orphan sweep on load / empty).

- [x] **Issue detail + attachment management polish.** `IssueDetailSheet` (open
  an issue): body + attachment grid with inline image previews (click → in-app
  QuickLook), editable title/description, add/remove attachments. Richer paste
  (file / image / PDF / RTF / text). CLI `pharos attach add|list|rm`. **Peer host
  key** setting: SSH peer-drift reads the peer's path from `localPaths`.

### v1.3 — Issue organization & navigation (requested 2026-06-21)

- [x] **Labels + filtering.** `Issue.labels` (single-user freeform tags). GUI
  label chips on rows + add/remove in the detail sheet; Issues-tab filter bar
  (text + status + label). CLI `issue add --label`, `issue label add|rm`,
  `issue list --label/--status/--priority`.
- [x] **⌘K quick-jump to issues.** The command palette now returns issues
  (matched by `#number`, title, or label) alongside projects; selecting one jumps
  to its project and opens it (`ProjectStore.requestedIssue` → detail sheet).
- [x] **Kanban board view.** Issues tab has a List/Board toggle; the board groups
  issues into status columns (backlog/todo/in_progress/done/canceled). Drag a card
  to another column to change its status (`.draggable`/`.dropDestination`); text +
  label filters still apply.
- [x] **Recent activity view.** A cross-project feed (toolbar → Activity) of all
  recent issues (by last update) and project-log updates, newest first, filterable
  (All / Issues / Updates). Click an entry to jump to it (`ActivityView`).

### v1.4 — Cycles, ordering, markdown (requested 2026-06-21)

- [x] **Markdown rendering** for issue bodies + project-log notes (`MarkdownText`,
  a dependency-free renderer adapted from Wick's `WickMarkdown`: headings, bullet
  / numbered lists, fenced code, inline bold/italic/code/links).
- [x] **Manual issue ordering** — drag a board card within / across columns to
  reorder; persisted via `Issue.sortOrder` (`StoreData.moveIssue` renumbers the
  destination column 0…n). Board sorts by `sortOrder`.
- [x] **Cycles / milestones** — `Milestone` on `Project` + `Issue.milestoneID`.
  GUI: milestone picker in the detail sheet (+ New milestone…), filter-bar
  milestone menu, flag chip on rows/cards. CLI: `milestone add|list|rm`,
  `issue milestone <#> <name|none>`, `issue list --milestone`.

### v1.5 — Relations & search (requested 2026-06-21)

- [x] **Issue relations + sub-tasks.** `Issue.parent` (sub-tasks, cycle-guarded)
  + `Issue.relations` (relates / blocks / blocked-by / duplicate, dual-written so
  the inverse stays in sync). Detail sheet: parent picker, sub-task list, link
  list (add/remove); rows/cards flag blocked + sub-task counts. CLI: `issue
  parent <#> <parent#|none>`, `issue link|unlink <#> <kind> <#>`.
- [x] **Cross-project search.** `pharos search <query>` over every project's
  issues (title / body / labels / number); ⌘K now matches issue bodies too, so
  the palette is a live cross-project search.

### v1.6 — Dashboard (requested 2026-06-22)

- [x] **Dashboard / overview.** `DashboardView` is the home screen (no project
  selected; toolbar Overview button + sidebar entry): a **group-tab switcher** up
  top, then stat tiles (projects / open issues / blocked / agents), issues-by-
  status, needs-attention (blocked + urgent), agents working, milestone progress,
  and the **recent-activity feed** (All / Issues / Updates) at the bottom — the
  standalone Activity view was merged in. All clickable. CLI: `pharos overview`.
- [x] **Window title fix.** The native tab/window title is now `"<project> —
  Pharos"` (was the bare project name, which made the Dock/window list look like
  a different app, e.g. "camoufox-MCP"); the dashboard home is titled "Pharos".

### v1.7 — Tracking reliability & polish (requested 2026-06-22)

- [x] **Running-agent reliability.** `runningSessions()` now returns `nil` when
  tmux is unavailable (vs. empty) so links are never falsely cleared; finish
  detection reconciles each issue's `activeSession` against the *live* tmux set
  (`StoreData.reconcileAgentLinks`) on every poll, on launch, and on refresh —
  so a restart or a finish-while-closed self-heals instead of going stale.
  Per-issue session names (`pharos-<slug>-<kind>-i<n>`) end same-project
  collisions; the project dot now prefix-matches. Issue launches only link a
  session when run in tmux (non-tmux can't be tracked).
- [x] **Rename a project in the app** (sidebar context menu → Rename…,
  clash-checked) — `ProjectStore.rename`. (Notes/paths were already editable.)
- [x] **One-click CLI install** (Settings → Command line → "Install command"):
  symlinks the bundled binary as `pharos` into the first writable PATH dir
  (`/opt/homebrew/bin` → `/usr/local/bin` → `~/.local/bin` → `~/bin`).
- [x] **Dashboard entry in the sidebar.** A "Dashboard" row pinned at the top of
  the sidebar (selected when no project is) — the obvious entry point to the
  overview, alongside the toolbar button.
