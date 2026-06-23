# Changelog

Maps Pharos versions to git history. Newest at top.
`MARKETING_VERSION` / `BUILD_NUMBER` live in `version.env`.

---

## Unreleased

## v0.2.0 — 2026-06-23

**Issues & project log (Linear-style, single-user).** Native issues with status,
priority, labels + filtering, milestones/cycles, manual ordering, markdown bodies,
parent/sub-tasks + relations, attachments, ⌘K jump, and cross-project search.
Agents drive them from the CLI.

**Dashboard.** A cross-project home screen — stat tiles, issues-by-status,
needs-attention, agents working, milestones, and a recent-activity feed with a
group switcher. Mirror: `pharos overview`.

**Mesh — agent chat rooms.** Agents talk to each other over the CLI (no MCP, no
hooks): `pharos mesh` / `chat` with `say` · `@mention` · `ask` (send + park for the
reply) · `wait` · `join` (returns history) · `history` · `rename` · `delete`. A
local unix-socket broker, durable per-room transcripts, mention-only delivery. A
read-only room view in the window (chat + room list) and a Dashboard card;
`project#number` references auto-link to issues. Validated with live Claude↔Codex
chat.

**CLI is the core.** Removed MCP in favor of `pharos` (and `chat`, the same binary
invoked differently). Settings → CLI tab installs the commands (no sudo) and the
agent **skills** (`mesh`, `pharos`) into `~/.claude/skills`; `pharos skill install`.

**Safe deletes.** Undo-first soft-delete Trash (30-day), confirms scaled to blast
radius, "forget" vs "destroy", audited.

**Multi-machine.** iCloud Drive data location + per-host checkout paths; peer git
status over SSH. (Settings → Sync.)

**Reliability & polish.** Running-agent tracking reconciles against live tmux
(restart-safe) with per-issue sessions; project rename in-app; menu-bar lighthouse
icon; Wick-style sidebar with pinned Dashboard + Chat Rooms entries.

- Personal identity: bundle id `me.pai.pharos`, `© 2026 Pai` (no company info).

## v0.1.0

- Phase 0 scaffold: SwiftUI + Liquid Glass (macOS 26) project manager, built as
  a pure SwiftPM app (no Xcode project).
- Project registry (local folders + GitHub), groups, JSON persistence.
- Git status panel, launch Claude Code / Codex with a project-level YOLO toggle,
  GitHub clone-to-local. Lighthouse app icon.
