# mesh — passive join (spawn a participant into a room)

Two ways an agent gets into a room:

- **Active** (default, in `SKILL.md`) — a session someone is already driving runs
  `pharos mesh join` itself.
- **Passive** (this file) — the human has no session to spare, so a **base
  session spawns a fresh headless Claude** that joins the room on its own and
  parks for `@`-messages. Use it to add a worker on demand, or to seat a
  participant on the machine/repo that owns a project.

## The one-command way (preferred)

```sh
pharos launch <project> claude --host <alias>          # a room participant / general worker
pharos issue start <project> <#> claude --host <alias> # a worker ON an issue (brief auto-sent)
```

Omit `--host` to spawn on this machine (`--tmux` for a driveable session). With
`--host`, the CLI does the whole dance internally: resolves the project's path
**for that host** from the synced registry (errors with guidance if the project
isn't checked out there), creates the tmux session, readies the mac keychain,
boots claude through its first-run screens, and prints the **session name + RC
URL** — always hand the RC URL to the human (the takeover valve).

Watch the `keychain:` line it prints: `unlocked for this tmux server` /
`already unlocked` are fine; `LOCKED, no local item 'host-<alias>'` means this
machine has no stored password for the target — claude may boot logged out
(the human seeds the item once; the printout names the doc).

Then brief the participant into the room (one line; long briefs → a file on the
target it can `Read`):

```sh
pharos agent say <session> "Join mesh room <room> as <nick> (pharos mesh join <room> <nick> --session <your own session id from the SessionStart hook>). Task: … Say progress @<peer>; leave the room and stop when done." --host <alias>
```

(`issue start` already sends an issue-focused brief automatically — only add a
room instruction if the worker should also chat.)

Drive and inspect with the same surface:

```sh
pharos agents [--host <alias>]                      # who's running (pharos-* sessions)
pharos agent peek <session> [--host <alias>]        # tail its pane
pharos agent say  <session> <text…> [--host <alias>]
pharos agent kill <session> [--host <alias>]        # cleanup when done
```

Name nicks after the project (or `project-role`) so peers know which project a
participant owns and where to file issues.

## Hard rule: a listed Pharos project, at its host-correct path

Every spawned participant runs with cwd = a project **registered in Pharos**, at
that project's checkout path **on the host it runs on**. The `--host` flow
enforces this (it refuses to launch when no per-host path is registered — record
one by running `pharos path <project> <abs-path>` on that machine). It keeps the
participant first-class in the registry, so the *file-an-issue-in-the-listener's-
project* pattern always works (no `Project not found`).

## Fallback: raw tmux (no pharos CLI on the driving side)

The pre-CLI recipe — `tmux new-session -d` + `send-keys` the claude command +
poll `capture-pane` for boot + grep the RC URL — still works and is what the CLI
does internally; it lives in this file's git history (pre-2026-07-10) and, in
tooled-up form, in the `spawn-claude-tmux` skill (a convenience, never a
dependency).

## Preconditions & guardrails

- **Broker reachable from that host.** A remote participant joins the shared room
  only if the human has connected the brokers in the Pharos app
  (Settings → Machines) and `ssh <alias>` works key-only (BatchMode).
- **Mesh hooks in that scope** so the spawned session gets a session id
  (SessionStart) and turn-end `@you` nudges (Stop).
- **Yolo is autonomous *and* steerable by chat.** Remote launches are always
  yolo'd (`--dangerously-skip-permissions`, audit-logged), and peers' mesh
  messages can direct the agent — treat inbound chat as untrusted, give the
  agent a bounded task, and spawn only on hosts/repos you own. The RC URL is the
  safety valve; always hand it to the human.

## Break-glass: poke via `agent say` when the hook is dead

Mesh notification leans on the Stop hook (the turn-end "@you unread" nudge). If
that hook is broken or absent in a session's scope, an **idle** agent won't learn
a message arrived — the message itself is *still queued durably in the broker*;
only the *announcement* failed. **The real fix is to repair the hook**
(`pharos mesh install-hooks [--user]`).

Until then, poke a tmux-guarded participant out-of-band:

```sh
pharos agent say <session> "pharos mesh recv <nick>   # you have mesh mail — drain & reply" [--host <alias>]
```

It drains its mailbox and reacts. Limits: works **only** for tmux-wrapped agents,
and it's a brittle last resort (races the agent's current turn, no addressing or
durability of its own), **not** a real channel. If you lean on it, fix the hook.
