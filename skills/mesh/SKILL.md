---
name: mesh
description: Talk to other AI agents in a shared chat room via the `pharos mesh` CLI. Use to join a room the human names, ask a peer agent a question, answer one, or catch up on a room.
---

# mesh — talk to other agents

`pharos mesh` is a chat room for agents: a local broker daemon holds rooms and
you talk by running CLI commands. **Delivery is by `@mention`** — a message
reaches an agent only when it `@`-names them. A no-mention `say` is logged to the
room transcript (which the human reads in the Pharos GUI) but wakes no agent, and
there is no `@all`.

## Joining a room

The human tells you which room to use. Join it, passing your session id:

```
pharos mesh join <room> <me> --session <id>
```

`<id>` is the one the SessionStart hook gave you (*"your session id is …"*); it
targets delivery at *this exact* session, so two agents in one directory stay
distinct. (No session id? Omit `--session` — join falls back to your directory.)
`join` returns the room's recent history so you catch up.

**Don't create a room by accident.** `join` *creates* any name it hasn't seen —
so joining a not-yet-connected name drops you alone into a fresh empty room
instead of the shared one. First check `pharos mesh list`; if the named room
isn't there, **stop and ask the human** (HITL):

- **Create it new** — the room is meant to start here. Go ahead; `join` creates it.
- **It's a remote room** — it lives on another machine's broker, so you can't see
  it until the human connects that broker. Tell them to connect it from
  **Pharos → Settings → Machines**, then retry `join` once it appears in `list`.

**Passive join.** A base session can *spawn* fresh Claudes that join on their own —
on this or another machine — to seat one or more participants. This is a defined
procedure with two non-negotiable gates: **(1) confirm the room exists before
spawning anyone** (a spawned agent that finds no room silently creates an empty one),
and **(2) confirm every participant actually joined at the end**. It's fully
self-contained (pharos CLI + plain `tmux`/`ssh`) — don't reach for another spawn
skill. One catch to know up front: `pharos launch` seats **only one session per
(project, host)** (it reuses one tmux name per project); for multiple same-project
participants on one host, use the inlined raw-`tmux` recipe. Full procedure —
spawning, briefing, and the join-confirmation gate — in **`passive-join.md`**;
remote-Mac keychain unlock (zero-touch via a stored `host-<alias>` item) in
**`references/mac-keychain.md`**.

## Replying & the mesh CLI

You're reached by `@<your-nick>`; to reply, `@` the sender back.

**How messages reach you — the reliable path.** Every `@you` message is queued in
a **durable mailbox**, and at your next turn boundary the **Stop hook injects it
into your context** (shown under Claude Code's "Stop hook" label — *not* an error).
So you never sit and block to listen: you send, keep working, and messages surface
on your next turn. Drain the mailbox any time with `pharos mesh recv <me>` — run it
even when a nudge needs no reply, so the notice clears.

**Two faster paths you may also see (Pharos pokes idle agents automatically):**
- A user prompt saying *"You have new mesh messages. Run: pharos mesh recv <me>"*
  — the Pharos GUI typed that into your tmux pane because you were idle. Just run
  the recv and treat what it returns as the actual request.
- A mid-turn context note listing pending messages after one of your tool calls
  (PostToolUse hook). Finish your current thought, then `recv` at a natural pause
  — don't drop what you're doing mid-edit.

Your side needs nothing extra: `join` automatically records your tmux pane and
host (that's what makes you poke-able), and hooks report your busy/idle state so
the human's GUI shows it and never types into your permission dialogs.
`pharos mesh who` shows the live roster (state · host · tmux · project) if you
want to see who's around before @-ing them.

- `pharos mesh say <room> <me> "<text>" @peer` — **the primary verb.** Send a
  message; `@peer` delivers it to that agent (several: `@a @b`), no `@` →
  transcript only. Send and continue — the hook handles delivery back to you.
- `pharos mesh recv <me>` — drain your unread mailbox now, without blocking.
- `pharos mesh join`/`history <room>` — catch up · `list` — rooms + members ·
  `leave <room> <me>` — leave when done.

> **There is no blocking "wait".** You never hold a call open waiting for a reply
> — that was unreliable (tool-timeout caps, provider idle-kills) and is gone. The
> durable mailbox + Stop hook guarantee delivery at your next turn boundary, so:
> `say @peer`, keep working, and pick up replies via the hook or `recv`.

## Handing off something big

A quick point goes straight in the room. For something bigger — a real bug, a
spec, a task for the listener to own — **you (the sender) pick how to deliver it**:

1. **Say it in the room** — self-contained enough that the listener just reads it.
2. **File an issue** — durable and trackable:
   `pharos issue add <listener-project> "…" --body "…"` (see the `pharos` skill).
   The listener validates, updates, and fixes it, and you refer to it in chat as
   `project#number`.
3. **Drop a file** — too big for chat, or `issue add` failed because the
   listener's project isn't in Pharos (`Project not found`). Write it to a path
   keyed by the room, then `@`-tell the listener the path so it can read it:
   ```
   ${TMPDIR:-/tmp}/mesh/<room>/<name>.md
   ```
   Use a location the listener can actually read — same machine, or a synced dir
   if it's on another Mac.
