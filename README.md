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

## Features

### Launch & Resume Agents
- Launch **Claude Code** or **Codex** into any project in one click — yolo mode, tmux pane, your default terminal, or editor.
- **Resume** past agent sessions (Claude `~/.claude/projects` + Codex `~/.codex/sessions`) without losing context.
- Run agents **in parallel** safely using git worktrees: create, switch, and remove worktrees from inside the app.

### Organize Projects
- Add local folders or GitHub repos; group them with tags and smart groups.
- Commit-activity sparkline on every project row — see what's been touched at a glance.
- Cross-project status: open PRs and CI state per repo via `gh`.
- Import multiple repos from GitHub with checkbox multi-select and group assignment.

### Git & Worktrees
- Per-project git panel: branch, status, recent commits, and drift from remote.
- Worktree manager — list, create, switch, remove — wired directly to "launch agent in a new worktree."
- Multi-machine peer git drift over SSH (configure a peer host in Settings).

### Cockpit
- **⌘K command palette** — fuzzy jump to any project or quick action.
- **Menu-bar item** — per-project launch submenus without switching windows.
- **Native window tabs** — one tab per project, standard macOS tab bar.
- Desktop/Space placement so agent windows appear exactly where you want them.
- Notifications when an agent finishes.
- Per-project playbooks for repeatable launch sequences.

### MCP Server
- Run `Pharos --mcp` to expose **21 MCP tools** over stdio — let another AI agent (Claude Code, Codex, any MCP client) drive Pharos programmatically.

### Multi-Machine
- Peer git drift tracking per project over SSH — see how far a remote machine has diverged.

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

Any MCP-compatible agent can drive Pharos programmatically. Run Pharos in server mode:

```bash
Pharos.app/Contents/MacOS/Pharos --mcp
```

### Claude Code config snippet

Add to your `~/.claude/claude_desktop_config.json` (or your agent's MCP settings):

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

### Available tool categories (21 tools)

| Category | Tools |
|----------|-------|
| **Read** | `list_projects`, `list_groups`, `git_status`, `list_worktrees`, `list_sessions` |
| **Action** | `launch_agent`, `resume_session`, `run_playbook`, `open_terminal`, `open_editor`, `reveal_in_finder` |
| **Write** | `add_project`, `remove_project`, `rename_project`, `set_description`, `add_to_group`, `remove_from_group`, `create_group`, `delete_group`, `set_yolo`, `set_tmux` |

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
