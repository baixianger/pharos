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
  <img src="site/shots/dashboard.png" width="840" alt="Pharos dashboard — every project, issue, and agent at a glance">
  <br>
  <sub>One home for every repo, issue, and coding agent.</sub>
</div>

<div align="center">
  <table>
    <tr>
      <td width="50%"><img src="site/shots/chat.png" alt="Agent chat rooms with live status avatars"></td>
      <td width="50%"><img src="site/shots/project.png" alt="Per-project detail — actions, git, notes"></td>
    </tr>
    <tr>
      <td><sub>Agents talk in chat rooms — live status, @mentions, poke-to-wake.</sub></td>
      <td><sub>Every project: one-click agent launch, git, issues, playbooks.</sub></td>
    </tr>
  </table>
</div>

---

## What it does

- **Mission control for AI coding agents** — launch, resume, and parallelize Claude Code or Codex across every repo, with issues, git, and playbooks in one window.
- **Agents that coordinate** — a built-in chat mesh where your agents talk to each other, and you wake an idle one with an `@mention` (on this Mac or a paired one).

---

## Install

### Download (recommended)

1. Grab the latest **`Pharos-<version>.dmg`** from [Releases](https://github.com/baixianger/pharos/releases).
2. Open the DMG and drag **Pharos.app** to your Applications folder.
3. Launch — done. Releases are **signed with a Developer ID and notarized by Apple**, so they open with no Gatekeeper prompt.

> **Requirements:** macOS 26 (Tahoe) · Apple Silicon (arm64)

Pharos uses **Sparkle** for automatic updates — you'll be notified inside the app when a new version is available.

### Headless Mesh on Debian or Ubuntu

```bash
curl -fsSL https://baixianger.github.io/pharos/apt/pharos.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/pharos-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/pharos-archive-keyring.gpg] https://baixianger.github.io/pharos/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/pharos.list
sudo apt update
sudo apt install pharos-mesh
```

The package installs the portable signed-replica CLI/runtime, not the macOS
project launcher. Linux participates as a normal identity-addressed Mesh device;
the legacy TCP Broker remains available only for migration rollback.

Initialize or inspect the device-local replica:

```bash
pharos-mesh distributed init
pharos-mesh distributed status
```

### Build from Source

```bash
git clone https://github.com/baixianger/pharos.git
cd pharos
swift build                  # compile-check
bash Scripts/dev.sh          # build icon + package Pharos.app + launch
```

No Xcode project required — Pharos is a pure SwiftPM app.

---

## CLI — how agents drive Pharos

Pharos is scriptable from the command line, and the CLI is the interface coding
agents use: a Claude Code or Codex session can shell out to `pharos` to read
project state, manage issues, and post progress — no separate server to run, and
nothing preloaded into the agent's context. The CLI ships **inside the app
bundle** — the binary at `Pharos.app/Contents/MacOS/Pharos` *is* the CLI; symlink
it onto your `PATH` as `pharos`:

<div align="center">
  <table>
    <tr>
      <td width="50%"><img src="site/shots/settings-cli.png" alt="Settings → CLI — install the pharos/chat symlinks and Claude/Codex hooks"></td>
      <td width="50%"><img src="site/shots/settings-codex.png" alt="Settings → CLI → Codex — install the mesh hooks for Codex agents"></td>
    </tr>
  </table>
  <br>
  <sub>Settings → CLI wires up the symlinks and agent hooks — for both Claude Code and Codex.</sub>
</div>

**Claude *and* Codex.** The mesh works across runtimes: install the hooks per agent (Settings → CLI → **Claude** / **Codex**, or `pharos mesh install-hooks [--codex]`), and Claude and Codex agents share the same chat rooms — each shown with its own avatar.

```bash
ln -s /Applications/Pharos.app/Contents/MacOS/Pharos /usr/local/bin/pharos
pharos help                              # discover every command
pharos list --json                       # machine-readable project list
pharos launch myrepo claude --tmux       # launch an agent
pharos issue add myrepo "Fix login bug" --priority high
pharos issue start myrepo 3 claude       # launch an agent ON issue #3
pharos update add myrepo "shipped the fix" --issue 3
pharos remove myrepo                     # reversible — see `pharos trash`
```

Every read command accepts `--json`. Deletes (`remove`, `group delete`,
`issue rm`) are reversible via the Trash for 30 days. Set
`PHAROS_REGISTRY=/path/to/projects.json` to target an alternate store. The GUI
live-reloads within ~2 seconds whenever the CLI writes, so changes show up in the
running app immediately.

### Command reference

Run `pharos help` for the authoritative list. Summary:

| Group | Commands |
|-------|----------|
| Read | `list` · `groups` · `git <project>` · `worktrees <project>` · `sessions <project> <agent>` · `issue list <project> [--all]` · `update list <project>` · `search <query>` · `overview` · `trash [list]` |
| Agents | `launch <project> <agent> [--no-yolo] [--tmux]` · `resume <project> <agent> <session_id>` · `playbook <project> <name>` · `open`/`editor`/`reveal <project>` |
| Issues & log | `issue add <project> "<title>" [--priority …] [--body …] [--attach <file>]… [--label L]…` · `issue list <project> [--all] [--status S] [--priority P] [--label L] [--milestone M]` · `issue status\|priority <project> <#> <value>` · `issue label add\|rm <project> <#> <label>` · `issue milestone <project> <#> <name\|none>` · `issue parent <project> <#> <parent#\|none>` · `issue link\|unlink <project> <#> <relates\|blocks\|blocked-by\|duplicate> <#>` · `issue start <project> <#> <agent>` · `issue rm <project> <#>` · `attach add\|list\|rm <project> <#> …` · `update add <project> "<text>" [--issue <#>]` |
| Milestones | `milestone add <project> "<name>" [--due yyyy-MM-dd]` · `milestone list <project>` · `milestone rm <project> <name>` |
| Registry | `add <name> [--path] [--remote] [--tag]… [--notes]` · `remove <project>` · `rename <project> <new>` · `describe <project> <text…>` · `group create\|delete\|add\|remove …` · `yolo`/`tmux <project> <on\|off>` · `trash restore <id>` · `trash empty` |
| Mesh | `mesh create\|list\|join\|say\|recv\|who\|poke\|unread\|history\|leave\|rename\|delete` · `mesh install-hooks [--project <dir> \| --user]` (also invocable as `chat`) |
| Cross-host | `launch <project> <agent> --host <ssh-alias>` · `issue start <project> <#> <agent> --host <alias>` · `agents [--host]` · `agent peek\|say\|kill <session> [--host]` |
| Multi-machine | `host` · `path <project> <path>` · `path <project> --clear` |

The headline differentiator — **issues wired to the agent loop**: `pharos issue
start` moves an issue to *In Progress* and links the agent session; when that
agent finishes (tmux), Pharos auto-posts an update to the project log. Agents can
also post their own progress with `pharos update add`.

## Local-first data and execution Hosts

<div align="center">
  <img src="site/shots/settings-machines.png" width="520" alt="Settings → Machines — trusted devices and execution Hosts">
</div>

Every trusted Mac, iPhone, iPad, or Linux device owns a signed SQLite replica of
portable projects, issues, updates, Trash, chat, and attachment metadata. There
is no global data leader. Offline writes remain visible locally and converge
field-by-field after Iroh reconnects directly or through an encrypted relay.
Append-only messages retain immutable authorship; content-addressed attachments
are verified before publication.

Settings → **Machines** shows cryptographically identified trusted devices and
the observed direct/relay/offline path. Removing a lost or replaced device
advances the signed membership epoch; the omitted key can no longer authenticate.
Keep at least two controller devices. To rotate a device key, pair and verify the
replacement first, then remove the old device. Checkout paths, SSH keys, tool
paths, and tmux state remain Host-local. See [ADR-003](docs/ADR-003-LOCAL-FIRST-DISTRIBUTED-MESH.md).

Pair a phone or another Mac from Settings → **Machines** → **Pair a device**.
For headless Linux pairing and service commands, see
[Pharos Mesh on Linux](docs/MESH_HEADLESS.md). No public TCP port, fixed Broker,
or Tailscale configuration is required in the distributed product mode.

---

## Privacy

Pharos reads `~/.claude/projects/` and `~/.codex/sessions/` **locally only**.
Portable state lives in each device's local replica under Application Support
(or the Linux XDG data directory). Iroh relays see encrypted transport only;
private keys and plaintext payloads are never sent to a Pharos-hosted service.
SSH is retained solely for explicit agent bootstrap and interactive recovery.

---

## Release

Current releases are ad-hoc-signed DMGs:

```bash
bash Scripts/package_app.sh release   # build + package Pharos.app
bash Scripts/make_dmg.sh              # styled drag-to-install DMG
```

A full notarized pipeline (build → sign → notarize → staple → DMG → GitHub release) is scripted as `bundle exec fastlane mac release` — see [docs/RELEASE.md](docs/RELEASE.md) for its prerequisites (Developer ID cert + notarytool profile).

---

## Contributing

PRs are welcome. The project uses **pure SwiftPM** — no `.xcodeproj`, no CocoaPods.

```bash
git clone https://github.com/baixianger/pharos.git
cd pharos
swift build          # compile
swift test           # run the test suite
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
