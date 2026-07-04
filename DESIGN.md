# Pharos — Design & Spec

Pharos is a macOS launcher/dashboard for dev projects: add repos, group them,
see git state, and fire Claude Code / Codex into them. Think "mission control for
your projects" — the GUI version of a tmux + yolo + open-in-desktop workflow.

## Decisions (locked)

| Question | Decision | Why |
|---|---|---|
| Name | **Pharos** (lighthouse) | A beacon overseeing all projects; fits the Greek-myth naming (lelantos). |
| Grouping model | **Tags + smart groups** | Manual tags can overlap (a project is both `work` and `active`); smart groups auto-derive from parent dir / git org / status and stay synced with disk. Folder-only can't express overlap; manual-only drifts. |
| iPhone / remote control | **Skipped for v1** | Opening Finder/terminal on a desktop is a *local GUI side-effect* — useless from afar. If revisited, build a Tailscale-bound headless agent-runner + monitor, web UI first; not a native iOS GUI launcher. |
| UI framework | **SwiftUI + Liquid Glass, macOS 26** | Native, matches the requested theme. Xcode 26.5 / Swift 6.3 confirmed. |
| Packaging | **SwiftPM, no .xcodeproj** | CLI-buildable; `Scripts/` assembles + ad-hoc signs the `.app`. |

## Data model

- **Project**: `name`, `localPath?`, `githubRemote?`, `tags[]`, `yolo` (default on), `addedAt`.
  A project may be local-only, GitHub-only, or both.
- **SidebarItem**: `.all` | `.tag(String)` | `.smart(String)`.
- **Smart groups** (P0): derived from each project's parent folder name. Future rules:
  git remote org, "dirty / needs attention", "has open PR", last-opened recency.
- Persistence: JSON at `~/Library/Application Support/Pharos/projects.json`.

## Services

- **Shell** — `Process` wrapper for git/open.
- **GitService** — branch, last commit (hash/subject/relative), dirty, ahead/behind
  upstream, branch count, worktree count. Runs off-main via `Task.detached`.
- **LaunchService** — reveal in Finder; open Ghostty at path; launch claude/codex
  in a new Ghostty window honoring the project's yolo flag.

## Agent integration (verified feasible)

- **Claude Code**: sessions in `~/.claude/projects/<encoded-path>/*.jsonl`.
  Resume: `claude --resume <id>` / `claude -c`. Yolo: `--dangerously-skip-permissions`.
- **Codex**: sessions under `~/.codex/sessions/…` + `~/.codex/session_index.jsonl`.
  Resume: `codex resume <id>` / `--last`. Headless: `codex exec`.
  Yolo: `--dangerously-bypass-approvals-and-sandbox`.

P2 will parse these into a per-project tabbed session list with one-click resume.

## ⚠️ Technical risk #1 — placing windows on a specific Desktop (Space)

macOS has **no public API** to move a window to a Space or create a Space. A new
window only ever opens on the *currently active* Space. Options:

1. **Private CoreGraphics (CGS) APIs** (`CGSAddWindowsToSpaces`, space-create) — what
   yabai / WindowManager use. Works for a personal (non-App-Store) build; can break
   across OS updates. **Preferred**, wrapped in a `SpacesService` to isolate the risk.
2. Keyboard-shortcut + Accessibility automation — can switch to existing desktops but
   can't cleanly *create* one.
3. Require yabai — needs SIP partially disabled. Too heavy to mandate.

Prototype this before committing to the feature. Fallback: open on the active Space
and let the user move it (the current manual `desk1.sh`/`desk2.sh` behavior).

## Roadmap

- **P0 (done)** — Liquid Glass 3-column shell · add local/GitHub project · tags +
  smart groups · JSON persistence.
- **P1** — open Finder/terminal/editor · launch claude/codex with project yolo toggle ·
  git panel · GitHub clone-to-local.
- **P2** — agent session browser + resume · worktree manager · desktop placement.
- **P3** — ⌘K command palette · menu-bar item · per-project playbooks · notifications.

## Mesh delivery (decided 2026-07-04)

The agent chat room guarantees @-mention delivery to a **live, joined** session:

- The broker mirrors each nick's in-RAM mailboxes to a local signal file
  (`mesh-state/unread/<nick>.json`, exists ⇔ unread pending) on every deliver
  and drain; `mesh-state/presence.json` maps nick → project dir (recorded at
  join) so hooks resolve cwd → nick. Both live in always-local App Support —
  never iCloud — and are wiped on daemon start (they mirror RAM, no more).
- Delivery is a Claude Code **Stop hook** (`pharos mesh unread --hook-stop`,
  wired by `pharos mesh install-hooks`): zero-daemon (pure file read),
  fail-open (every failure path exits 0), loop-safe (`stop_hook_active`).
  It blocks the stop with the unread messages; the agent consumes them with
  `pharos mesh recv <nick>` (drains all rooms) and replies.
- The UI's human input parses `@nick` into real delivery targets (the broker
  is mention-only; a broadcast reaches nobody's mailbox).
- **Accepted contract — the idle ceiling.** The room is tmux-agnostic: we don't
  know whether a session lives in tmux, so a Pharos-side tmux keystroke push is
  not a universal option. Hooks work for ANY session; a session idling at its
  prompt runs no hooks and gets delivery on its next activity (next turn
  boundary or human prompt). That ceiling is accepted, not a bug.
- Join/leave is human-initiated; re-summon replays via join's history catch-up.
- The hook command always embeds the **absolute binary path** first (a session's
  runtime PATH need not contain `pharos`), bare `pharos` only as fallback, `true`
  as the terminal fail-open. The Stop-block's "Stop hook error" label is Claude
  Code's own rendering of `decision: block` — no non-error-labeled block form
  exists (verified against the probed hooks reference); only the reason text is ours.
- **Next stage (deferred, approved 2026-07-04): csg-based tmux-guarded
  reachability.** Where csg knows a session is tmux-wrapped, push delivery into
  the pane actively, lifting the idle ceiling for those sessions; the hook path
  stays the universal fallback for everything else. Also parked there: presence
  staleness sweep → *offline* marking (mailbox kept, hard leave only on clean
  SessionEnd), SessionEnd auto-leave, PostToolUse/UserPromptSubmit delivery,
  roster online badges.

## Open questions

- Terminal of choice is hardcoded to Ghostty in `LaunchService` — make it configurable
  (Terminal/iTerm/Ghostty/WezTerm)?
- One Ghostty window with native **tabs** per agent vs tmux panes/windows — see the
  workflow note; likely a per-user preference setting.
- Editor targets (VS Code / Cursor / Zed / Xcode) as configurable launch actions.
