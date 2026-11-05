# Changelog

Maps Pharos versions to git history. Newest at top.
`MARKETING_VERSION` / `BUILD_NUMBER` live in `version.env`.

---

## v0.11.1 — 2026-07-21

**Local-first distributed Mesh.** macOS, iOS, and Linux now keep signed local
replicas and synchronize over identity-addressed Iroh connections. There is no
global Broker writer; offline project, issue, room, message, and attachment
changes converge deterministically after reconnect.

**Recoverable trust management.** Pairing is signed, expiring, and single-use;
re-pairing the same cryptographic identity refreshes routing without weakening
collision checks. Trusted-device removal now advances an atomic signed
membership epoch on macOS, iOS, and the shared CLI. Offline surviving devices
receive the same transition on reconnect, while omitted keys retain no current
RPC authority. Key rotation uses pair-new, verify-sync, then revoke-old.

**Cross-platform proof.** The same schema and protocol compile for macOS, iOS,
and Linux. SwiftPM has 299 passing tests and the iOS simulator suite has 26.
CI builds and tests macOS and iOS, builds the pinned Rust Iroh library and Linux
CLI, installs the resulting Debian package, and runs a migration cutover,
rollback, and re-cutover drill. The legacy TCP Broker remains an explicit
rollback path only.

---

## v0.8.0 — 2026-07-16

**One durable data authority.** The Mesh Broker now owns projects, issues,
updates, Trash, chat, and attachments. macOS and iPhone retain offline caches;
iCloud is imported once and is no longer a competing live synchronization path.

**Conflict-safe multi-client writes.** Project registry snapshots carry SHA-256
revisions and use compare-and-swap writes. Every accepted replacement backs up
the prior Broker snapshot, while an offline or conflicting Mac edit is preserved
locally instead of silently overwriting another client.

**Clean Broker/Host separation.** Checkout paths, SSH keys, terminal and agent
runtime state stay on each execution Host. Remote launches ask that Host to
resolve its own path, while Linux can run the same headless data Broker and CLI
from the signed Debian package.

## v0.7.0 — 2026-07-15

**Persistent cross-platform Mesh.** The broker and wire protocol now live in a
portable `PharosMeshCore`, with a standalone `pharos-mesh` executable for Linux
servers. Messages receive stable IDs, replies retain a safe preview of their
target, and image/PDF attachments use checksum-verified binary transfer with a
25 MiB limit and atomic storage.

**Native group-chat interaction.** macOS and iPhone chat views add quoted reply
cards, attachment pickers, previews and downloads, plus a more compact
Slack/Discord-inspired room and message layout. Legacy transcripts remain
readable without migration.

**Always-on personal Broker.** macOS can target an explicit headless Tailscale
endpoint instead of electing one of the paired Macs as Hub. The Linux service is
hardened with systemd, persists transcripts and files under
`/var/lib/pharos-mesh`, and needs none of the AppKit/project-launching CLI.

**Linux Release and APT automation.** GitHub Releases build signed `amd64` and
`arm64` Debian packages, publish checksums, and deploy a signed APT repository
through GitHub Pages so Ubuntu/Debian users can install and upgrade with `apt`.

## v0.6.0 — 2026-07-15

**Stable room names across native tabs.** A room now supplies the same dynamic
title to SwiftUI navigation and the underlying AppKit window, instead of the
room view racing the tab bar with a fixed `Chat Rooms` title. Deferred window
adoption always reads the newest title, and stale room-list/history requests no
longer navigate a tab back or replace the transcript after a fast room switch.

**Restore remote wake after upgrading an old pairing.** If the modern
`peerHost` route is empty but the retired ComputerName preference still exists,
Pharos now searches the current Tailscale Macs and restores the peer IP only
after an exact reachable SSH match. Existing modern pairings are never changed,
and ambiguous or offline machines remain unpaired instead of being guessed.
Peer discovery now also excludes phones, Linux nodes, and offline Macs instead
of listing or SSH-probing them as pairing candidates.

**Complete chat-room toolbar on first click.** The toolbar now fetches the
current room snapshot before presenting its popover, instead of opening from an
empty cache and filling it after SwiftUI has committed the first layout.

**Room-scoped agent identity.** Mesh delivery, unread mailboxes, state hooks,
and poke routing now use the immutable coding-agent session ID; `@codex` is
resolved as a display alias inside the current room. Two rooms may therefore
each contain a member named `codex` without the later join stealing the other
room's pane. Local and remote spawned-agent tmux names are room-scoped too.

**Self-healing Codex presence.** Pharos no longer leaves an idle Codex member
shown as busy when its Stop hook goes missing. A periodic ground-truth check
requires the registered tmux pane, a live Codex process in that pane's full
process tree, and the visible idle composer before correcting the roster. The
broker applies that correction conditionally, so a newer busy hook always wins;
every automatic poke also repeats the pane check immediately before typing.

**Add chat members on either Mac.** The room toolbar's Add Member sheet now
chooses this Mac or the paired Mac, then uses the same SSH, tmux, and per-server
Keychain-unlock path as remote project launches. `pharos mesh spawn` gains
`--host <ssh>`. Claude and Codex both boot, join, and are confirmed through the
shared mesh broker.

**Codex auto-poke parity in group chat.** An `@CodexMember` mention now follows
the same automatic nudge path as Claude, locally or over SSH. The safe unknown-
state probe recognizes Codex's `›` composer and rejects its `Working` state;
ambient broadcasts without an @mention still do not wake the whole room.

**Centralized agent management.** The Dashboard is now the single place to
rename, attach, stop, and remove mesh agents. Display names can change without
changing the immutable session identity, and room managers can remove stale or
unwanted members. Stopping an agent removes all of that session's room aliases.

**Reliable local and remote agent controls.** Pharos records the exact tmux
server behind every pane, so Attach, Stop, and wake actions reach the intended
session even across Macs. Older registrations are resolved safely by inspecting
the peer's live tmux servers; already-ended sessions are cleaned from the
Dashboard, while ambiguous matches are refused instead of risking the wrong
process.

**Independent window and tab titles.** Dashboard, Chat Rooms, and Project keep
stable content titles while native macOS tabs show Dashboard, the selected room,
or the selected project. Switching or creating tabs no longer lets the window
title overwrite the tab label.

**Broader Codex installation support.** Pharos now launches the CLI bundled
inside Codex.app as well as Homebrew, local-bin, npm-global, nvm/fnm, mise,
asdf, and Volta installations. Detection and launch use the same resolved
executable, eliminating false “Codex not found” errors from GUI PATH differences.

**Pharos for iPhone foundation.** The companion app now includes Projects,
Agents, Issues, Chat, and Settings tabs, mesh-backed registry access, SSH key
setup, remote tmux control, agent spawning, and an interactive remote terminal.

## v0.5.0 — 2026-07-13

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
