# dsh-plugin-pharos

A DeepSeek Harness (dsh) plugin that gives a dsh agent native tools to drive
Pharos — the mesh, issues, and project log — plus automatic @mention delivery.

When the local Pharos Host Runtime is available, every DSH session also
registers its driver, durable conversation, capabilities, and Web surface over
the RFC-003 Unix-socket JSON-RPC protocol. Registration is additive: older or
unavailable runtimes retain the existing conservative Mesh polling fallback.

Zero runtime dependencies: it registers raw Cordis tools that shell out to the
pharos CLI, so there is no version drift against the harness's own tool registry.

## Install

    # 1) install the plugin into a profile (web or headless)
    dsh plugin --profile web add file:/absolute/path/to/dsh-plugin-pharos

    # 2) enable it — add one row to the profile's patch layer
    #    ~/.dsh/profiles/web/cordis.patch.yml
    - id: pharos-tools
      name: dsh-plugin-pharos
      # optional: prefix for per-session mesh nicks
      config:
        nickPrefix: my-agent
        # pollIntervalMs: 3000  # 0 disables idle-session wakeups

(Pharos itself will automate both steps later — the equivalent of
pharos mesh install-hooks --dsh.)

## Configuration

| Env | Default | Meaning |
|---|---|---|
| PHAROS_BIN | pharos (PATH) | Absolute path to the Pharos CLI. Set it to Pharos.app/Contents/MacOS/Pharos if pharos is not on PATH. |
| PHAROS_MESH_NICK | (unset) | Fallback nick prefix when config.nickPrefix/config.nick is not set. |
| PHAROS_MESH_TCP | (unset) | Not needed — the pharos CLI resolves its own broker endpoint. |

## Tools

| Tool | Args | Runs |
|---|---|---|
| pharos_list | — | pharos list --json |
| pharos_mesh_send | text, room, mention? | pharos mesh send … |
| pharos_mesh_recv | nick | pharos mesh recv <nick> |
| pharos_mesh_who | — | pharos mesh who |
| pharos_issue_add | project, title, body?, priority? | pharos issue add … |
| pharos_issue_list | project | pharos issue list <project> --json |
| pharos_update_add | project, text, issue? | pharos update add … |

## Automatic @mention delivery

Each DSH session is bound separately using its own `agent.session.id`. The
plugin derives a unique room nick from that ID, joins the configured room, and
passes the same ID explicitly to `send` and `recv`; the Web process is only the
host and never becomes the shared identity. The plugin polls the broker without
consuming messages and uses DSH's native `agent.followup()` primitive to wake an
idle session when directed mail arrives. The first-step listener remains as a
fallback and never injects a duplicate notification. When the session is
disposed it leaves its room alias using an identity guard, so a stale process
cannot remove a replacement session.

This is the in-process equivalent of the Claude/Codex Stop hook. Plain room
messages remain transcript-only; only explicit `@mentions` wake DSH agents.

## Plugin contract

Cordis plugin shape: named exports name / inject / apply, no default export.
It injects tools + agents + timer, registers raw ToolDefinitions into the host
tool registry, and prepends one agent/pre-step listener.
