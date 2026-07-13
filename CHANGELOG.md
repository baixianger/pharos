# Changelog

Maps Pharos versions to git history. Newest at top.
`MARKETING_VERSION` / `BUILD_NUMBER` live in `version.env`.

---

## Unreleased

**Codex agents join the chat mesh.** Codex sessions now participate as
first-class mesh members alongside Claude Code. Settings → CLI → **Codex**
(or `pharos mesh install-hooks --codex`) wires `~/.codex/hooks.json` so a Codex
agent reports live state, surfaces unread @mentions, and can be poked awake —
the same as Claude. Codex agents wear a distinct blue-robot avatar (a `>_`
terminal face) vs Claude's Clawd; `join` auto-detects which runtime it's in.
Note: Codex has no Notification/SessionEnd hooks, so it reports busy/stopped but
not blocked/idle/gone, and its hooks need a one-time trust approval
(`--dangerously-bypass-hook-trust`). The CLI-settings tab is now split into
**CLI / Claude / Codex**.

**Broadcast messages in chat rooms.** A room `say` with no `@mention` now reaches
**everyone** in the room — it lands in every member's mailbox and each sees it at
their next turn boundary, but nobody is poked (ambient). `@name` stays the
directed, urgent path: the named agent is poked awake or interrupted mid-turn.
(Considered but rejected: a broadcast that *also* pokes everyone — always-on poke
would wake a whole room on every casual line. Pre-0.4.0 a no-`@` message reached
nobody's mailbox at all; this replaces that.)

## v0.4.0 — 2026-07-13

**Poke idle agents from chat.** @mentioning an agent now *wakes* it for real.
Claude Code lifecycle hooks report each session's live state (busy /
blocked-on-permission / stopped / idle / gone) into the mesh, `join` records the
agent's tmux pane + host, and Pharos types a nudge into that pane — on this Mac
or a paired one over SSH — but only when the agent is verifiably idle. Busy
agents receive the message mid-turn (PostToolUse hook); a 10s sweeper re-pokes
anyone left idle with unread; anything unreachable (not in tmux, waiting on a
dialog) is handed to you in a notice instead of guessed at. Every uncertainty
degrades to the turn-boundary hook delivery — never to a wrong keystroke.

**Redesigned chat rooms.** Messenger-style room view: rooms as a tab strip
(right-click to rename/delete), avatar bubbles whose Clawd pixel-art pose tracks
each agent's live status, full markdown message bodies with tappable
`project#number` issue links, and `@` member autocomplete. Rooms and presence
now survive a broker restart.

**Stop running agents from the GUI (Pharos#7).** A Stop button wherever a
running session surfaces — the project-detail agent badge, per-issue running
rows, and the dashboard "Agents working" card — kills its tmux session (local or
over SSH) behind a confirmation dialog. New `pharos mesh who` / `poke` CLI verbs.

## v0.3.0 — 2026-07-10

**Cross-host agents.** `pharos launch <project> <agent> --host <ssh-alias>` and
`pharos issue start … --host` spawn a detached tmux agent on another Mac over
SSH/Tailscale: per-host path resolution from the synced registry, macOS keychain
auto-unlock (per tmux-server security session), ready-prompt wait + Remote
Control URL capture, and issue-brief injection. Drive surface from any machine:
`pharos agents [--host]`, `pharos agent peek|say|kill <session> [--host]`.

**One mesh hub, in the data model (Pharos#5).** Hub identity moved into the
synced store (`meshHubHostID`) — every Mac reads the same answer, so a second
hub is impossible by construction. The Settings toggle claims/releases the role;
a deposed hub self-demotes on its next launch. Satellites pair at app startup
and follow the hub through the app-managed `mesh-endpoint` dial file — zero
per-agent env config, fail-open when the hub is unreachable. (v1's blocking
`mesh ask`/`wait` gave way to say/@mention → unread signal → `recv`, delivered
by the Stop/SessionStart hooks.)

**Remote issue tracking.** Issue↔session links record which host the tmux
session lives on; the reconcile sweep probes remote hosts over SSH (5s timeout,
30s cache, never clears links for an unreachable host), so a remotely-started
issue shows as running and auto-logs "Agent finished" when its session ends.

**Registry split-brain fixed (Pharos#6).** A `pharos` symlink invocation doesn't
resolve Bundle.main to the app bundle, so the CLI read a per-process defaults
domain, missed the iCloud data-location pref, and silently kept its own registry
— GUI and CLI diverged. All pref access now routes through `PharosPrefs`
(explicit app domain from any front door), with a one-time data unification
(backups kept beside both files).

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
