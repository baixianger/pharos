# dsh-plugin-pharos

A DeepSeek Harness (dsh) plugin that gives a dsh agent native tools to drive
Pharos — the mesh, issues, and project log — plus automatic @mention delivery.

Zero runtime dependencies: it registers raw Cordis tools that shell out to the
pharos CLI, so there is no version drift against the harness's own tool registry.

## Install

    # 1) install the plugin into a profile (web or headless)
    dsh plugin --profile web add file:/absolute/path/to/dsh-plugin-pharos

    # 2) enable it — add one row to the profile's patch layer
    #    ~/.dsh/profiles/web/cordis.patch.yml
    - id: pharos-tools
      name: dsh-plugin-pharos
      # optional: this agent's mesh nick, so pending @mentions auto-surface
      config:
        nick: my-agent

(Pharos itself will automate both steps later — the equivalent of
pharos mesh install-hooks --dsh.)

## Configuration

| Env | Default | Meaning |
|---|---|---|
| PHAROS_BIN | pharos (PATH) | Absolute path to the Pharos CLI. Set it to Pharos.app/Contents/MacOS/Pharos if pharos is not on PATH. |
| PHAROS_MESH_NICK | (unset) | Fallback mesh nick when config.nick is not set. Enables auto @mention delivery. |
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

With a nick configured, the plugin subscribes to the agent/pre-step event and,
on the first step of each turn, peeks the mesh mailbox (pharos mesh unread, never
consumes). When unread mail exists it prepends an instruction to read and reply.

This is the in-process equivalent of the Claude/Codex Stop hook. It surfaces
pending @mentions at the next turn start; waking a fully idle agent still needs
the host to push a prompt (the HTTP API session.prompt bridge).

## Plugin contract

Cordis plugin shape: named exports name / inject / apply, no default export.
It injects tools + agents and registers raw ToolDefinitions into the host tool
registry, then prepends one agent/pre-step listener.
