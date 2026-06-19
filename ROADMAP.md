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
- [x] MCP server (`Pharos --mcp`, stdio JSON-RPC): list_projects / launch_agent / open_terminal / open_editor; Settings shows the agent config snippet.
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
