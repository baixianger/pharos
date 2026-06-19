<div align="center">
  <img src="assets/lighthouse-logo.png" width="120" alt="Pharos lighthouse icon">
  <h1>Pharos</h1>
  <p><strong>Your vibe coding project manager.</strong></p>
  <p>Mission control for running AI coding agents across all your repos — launch, resume, parallelize, and track agent work at speed.</p>
</div>

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2026-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://swift.org)
[![Liquid Glass](https://img.shields.io/badge/UI-Liquid%20Glass-blueviolet.svg)](https://developer.apple.com/design/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/baixianger/pharos/pulls)

</div>

---

<div align="center">
  <img src="site/shots/x1.png" width="760" alt="Pharos — project sidebar and a project's detail view">
  <br>
  <sub>One window for every repo and every coding agent.</sub>
</div>

---

## Features

### Organize

**Local and GitHub projects in one registry.** Add a local folder, a GitHub remote URL, or both — Pharos keeps a single unified project list regardless of where code lives.

**Tag groups and a watchlist-style sidebar.** Assign any number of tag-based groups to a project; the sidebar shows each group as a named section, exactly like a stock-app watchlist. Switch between "All Projects" and any group in one click.

**Commit-activity sparklines.** Every row in the project list shows a compact commit-frequency sparkline so you can see which repos have been active without opening them.

**Commit-activity heatmap.** The project detail view surfaces a GitHub-style heatmap of daily commit counts, giving you an at-a-glance history of how heavily a project has been worked.

**GitHub import with multi-select.** Pharos can fetch your GitHub repo list via `gh` and let you checkbox-select multiple repos at once, optionally assigning them to a group on import.

**Per-project notes and description.** Each project has a free-text notes/description field shown in the detail pane — useful for capturing context, links, or the current task for each repo.

### Launch Agents

**One-click launch of Claude Code or Codex.** Pick a project, pick an agent, and Pharos opens your configured terminal and starts the agent in that project's directory. No manual `cd` or command-line invocations required.

**Per-project yolo and tmux defaults.** Toggle yolo mode (passes `--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox`) and tmux mode (wraps the agent in a persistent tmux session) per project — set them once, launch fast forever.

**Terminal and editor choice.** Pharos respects your preference: choose Ghostty, macOS Terminal, iTerm, Warp, or WezTerm as your terminal, and VS Code, Cursor, Zed, Xcode, or Sublime Text as your editor. The same preference drives both GUI launches and MCP-triggered launches.

**Desktop and Space placement.** Configure which macOS desktop Space agent windows should land on, so your agent never hijacks the wrong Space.

**Per-project playbooks.** Save named shell commands ("run tests", "deploy staging", etc.) as playbooks attached to a project. Run them in one click from the UI or via the `run_playbook` MCP tool.

### Resume and Parallelize

**Browse and resume past sessions.** Pharos indexes `~/.claude/projects/` for Claude Code sessions and `~/.codex/sessions/` for Codex sessions, listing them newest-first per project. Resuming a session is a single click — Pharos opens the right terminal with the correct resume flag.

**Git worktree manager.** Create, list, switch, and delete git worktrees from within Pharos. Each worktree gets its own checkout on a separate branch, so multiple agents can work the same repo in parallel without stepping on each other.

**Running-agent detection and attach.** Pharos detects active agent processes and lets you attach to an existing session rather than launching a duplicate.

### Cockpit

**⌘K command palette.** A fuzzy-search palette lets you jump to any project or trigger any quick action (launch, open terminal, open editor, reveal in Finder) from the keyboard, from anywhere in the app.

**Menu-bar quick launch.** The Pharos menu-bar item shows a per-project submenu, letting you launch an agent or open a terminal without switching to the main window.

**Native macOS window tabs.** Pharos uses standard macOS tab bars — open one tab per project and switch between them like browser tabs, without losing your place in any project's detail view.

**Agent-finish notifications.** macOS notifications fire when a watched agent process exits, so you know when a long-running task is done without polling.

### Git and Multi-Machine

**Per-project git panel.** The project detail view shows current branch, dirty/clean status, commits ahead and behind the remote, and the most recent commit — pulled live via git.

**Open PRs and CI status.** For GitHub-backed projects, Pharos uses `gh` to surface the count of open pull requests and the conclusion of the latest CI run (success, failure, in progress) alongside the local git state.

**Peer git drift over SSH.** Configure a peer host (another Mac) in Settings, and Pharos will SSH into it to compare each project's HEAD, branch, and dirty count against your local copy — useful for keeping two machines in sync. Per-project, you can override the remote directory path if it differs from your local one.

---

## Install

### Download (recommended)

1. Grab the latest **`Pharos-<version>.dmg`** from [Releases](https://github.com/baixianger/pharos/releases).
2. Open the DMG and drag **Pharos.app** to your Applications folder.
3. Launch. Pharos is notarized and Developer ID–signed — no Gatekeeper warning.

> **Requirements:** macOS 26 (Tahoe) · Apple Silicon (arm64) or Intel (x86_64 universal binary)

Pharos uses **Sparkle** for automatic updates — you'll be notified inside the app when a new version is available.

### Build from Source

```bash
git clone https://github.com/baixianger/pharos.git
cd pharos
swift build                  # compile-check
bash Scripts/dev.sh          # build icon + package Pharos.app + launch
```

No Xcode project required — Pharos is a pure SwiftPM app.

---

## MCP Server

Pharos ships a built-in stdio JSON-RPC MCP server. Run `Pharos --mcp` and any MCP-capable client (Claude Code, Codex, or any other agent) can drive the full Pharos registry: read project state, launch agents, resume sessions, manage worktrees, and mutate project metadata — all 21 tools. The GUI live-reloads within ~2 seconds whenever a tool call writes to the registry, so changes are immediately visible in the running app.

### Config for Claude Code

Add a project-level `.mcp.json` at the root of your repo:

```json
{
  "mcpServers": {
    "pharos": {
      "command": "/Applications/Pharos.app/Contents/MacOS/Pharos",
      "args": ["--mcp"]
    }
  }
}
```

Or register it globally with the CLI:

```bash
claude mcp add pharos -- /Applications/Pharos.app/Contents/MacOS/Pharos --mcp
```

### Config for Codex

Add to `~/.codex/config.toml`:

```toml
[mcp_servers.pharos]
command = "/Applications/Pharos.app/Contents/MacOS/Pharos"
args = ["--mcp"]
```

### Tool reference

#### Read tools

| Tool | Arguments | Description |
|------|-----------|-------------|
| `list_projects` | _(none)_ | List all projects Pharos manages: name, local path, GitHub remote, tags, notes, yolo, and tmux defaults. |
| `list_groups` | _(none)_ | List all groups with the number of projects in each. |
| `git_status` | `project` | Git status for a project: branch, dirty flag, commits ahead/behind remote, and last commit (hash, subject, relative time). |
| `list_worktrees` | `project` | List a project's git worktrees: name, branch, path, and whether it is the main worktree. |
| `list_sessions` | `project`, `agent` (`"claude"` or `"codex"`) | List past agent sessions for a project, newest first: session id and title. |

#### Action tools

| Tool | Arguments | Description |
|------|-----------|-------------|
| `launch_agent` | `project`, `agent`, `yolo` (bool, default `true`), `tmux` (bool, default `false`) | Launch Claude Code or Codex in a project's local directory using the configured terminal. |
| `resume_session` | `project`, `agent`, `session_id` | Resume a past agent session by id in a project's local directory. |
| `run_playbook` | `project`, `playbook` | Run one of a project's saved playbooks (a named shell command) in the configured terminal. |
| `open_terminal` | `project` | Open the configured terminal at a project's local directory. |
| `open_editor` | `project` | Open the configured editor at a project's local directory. |
| `reveal_in_finder` | `project` | Reveal a project's local directory in Finder. |

#### Write tools

| Tool | Arguments | Description |
|------|-----------|-------------|
| `add_project` | `name` (required); `localPath`, `githubRemote`, `tags` (array), `notes` (optional) | Add a new project to the registry. |
| `remove_project` | `project` | Remove a project from the registry by name. |
| `rename_project` | `name`, `new_name` | Rename a project. |
| `set_description` | `name`, `description` | Set (or replace) a project's notes/description. |
| `add_to_group` | `name`, `group` | Add a project to a group; creates the group if it does not exist. |
| `remove_from_group` | `name`, `group` | Remove a project from a group. |
| `create_group` | `name` | Create an empty group. |
| `delete_group` | `name` | Delete a group and strip its tag from all projects. |
| `set_yolo` | `name`, `value` (bool) | Set a project's yolo default (skip agent permission prompts on launch). |
| `set_tmux` | `name`, `value` (bool) | Set a project's tmux default (wrap agent launches in a persistent tmux session). |

---

## Privacy

Pharos reads `~/.claude/projects/` and `~/.codex/sessions/` **locally only**. No session data, file paths, or identifiers are transmitted to any remote server. All app state lives in `~/Library/Application Support/Pharos/`.

---

## Release

Pharos is distributed as a notarized DMG, built and published with one command:

```bash
bundle exec fastlane mac release
```

This runs the full pipeline: build → sign → notarize → staple → DMG → GitHub release. See [docs/RELEASE.md](docs/RELEASE.md) for prerequisites (Developer ID cert + notarytool profile).

---

## Contributing

PRs are welcome. The project uses **pure SwiftPM** — no `.xcodeproj`, no CocoaPods.

```bash
git clone https://github.com/baixianger/pharos.git
cd pharos
swift build          # compile
swift test           # run the 22-test suite
bash Scripts/dev.sh  # build + launch locally
```

A few things to keep in mind:

- Pharos targets **macOS 26** and uses Liquid Glass APIs not available on earlier OS versions.
- Keep the SwiftPM build green (`swift build` + `swift test`) — CI runs this on every PR.
- Match the existing code style (Swift 6 strict concurrency where possible; Sparkle's MainActor isolation is a known exception, documented in the codebase).
- For significant changes, open an issue first to discuss the approach.

---

## License

[MIT](LICENSE) © 2026 Pai
