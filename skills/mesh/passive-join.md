# mesh — passive join (spawn a participant into a room)

Two ways an agent gets into a room:

- **Active** (default, in `SKILL.md`) — a session someone is already driving runs
  `pharos mesh join` itself.
- **Passive** (this file) — the human has no session to spare, so a **base
  session spawns a fresh headless Claude** (local tmux, or `ssh`+tmux on another
  Mac) that joins the room on its own and parks for `@`-messages. Use it to add a
  worker on demand, or to seat a participant on the machine/repo that owns a
  project.

## Hard rule: spawn inside a listed Pharos project, at its host-correct path

Every spawned participant runs with its **working directory = a project that's
registered in Pharos**, at that project's **correct checkout path for the host it
runs on**. Two reasons:

- It keeps the participant first-class in the shared registry, so the
  *file-an-issue-in-the-listener's-project* pattern always works for it (no
  `Project not found`).
- The per-host path is stored in Pharos (`localPaths`, keyed by host) — so you
  never hardcode a path, you read it from the host you're spawning on.

Resolve the path by running the CLI **on the target host** (`localPath` resolves
to that host's own checkout):

```sh
pharos list --json                 # local host  → target project's "localPath"
ssh <host> 'pharos list --json'    # remote host → target project's "localPath" there
```

No path on that host ⇒ the project isn't checked out there. Pick another host, or
check it out and record it: `pharos <project> path <abs-path>`.

## Recipe (self-contained — raw tmux, no external helper needed)

Needs only `tmux`, `ssh`, and `claude` on the target host. Pick the transport once:

```sh
NAME=<nick>                       # tmux session name = the participant's nick
tm() { tmux "$@"; }               # local
# tm() { ssh <host> tmux "$@"; }  # remote — tmux runs on <host>, survives your SSH drop
```

1. **Resolve** the project's host-correct path → `$DIR` (see the hard rule above).
2. **Spawn** a detached, remote-controlled Claude in `$DIR` (send the text and
   `Enter` as *separate* keystrokes — paste-detection safety):
   ```sh
   tm new-session -d -s "$NAME" -c "$DIR"
   tm send-keys -t "$NAME" -- "claude --remote-control $NAME --dangerously-skip-permissions"
   tm send-keys -t "$NAME" Enter
   ```
3. **Wait for boot, grab the RC URL**, and hand it to the human (the takeover valve):
   ```sh
   until tm capture-pane -t "$NAME" -p | grep -qiE 'bypass|for shortcuts|effort'; do sleep 3; done
   tm capture-pane -t "$NAME" -p -S -200 | grep -oE 'https://claude\.ai/[[:alnum:]/_.-]+' | tail -1
   ```
4. **Send the brief** so it joins the room and parks (long brief → a file the agent
   reads; for remote, that file must live on `<host>`):
   ```sh
   tm send-keys -t "$NAME" -- "Read /abs/brief.md and follow it."   # or a short inline task
   tm send-keys -t "$NAME" Enter
   ```
   The brief tells the agent to:
   - `pharos mesh join <room> <nick> --session <its-own-session-id>` — id from its
     own SessionStart hook (*"your session id is …"*);
   - work its task and `say "<…>" @peer` as it goes — incoming `@it` messages
     arrive via the Stop hook at each turn boundary (drain with `recv`); there is
     no blocking `wait`;
   - `pharos mesh leave <room> <nick>` and stop when done.
5. **Clean up** when done — the agent `leave`s the room; you kill the session:
   ```sh
   tm kill-session -t "=$NAME"
   ```

Name the nick after its project (or `project-role`) so peers know which project it
owns and where to file issues.

> If the `spawn-claude-tmux` skill happens to be installed, its `cc-tmux.sh` wraps
> all of the above (`spawn` / `url` / `say` / `kill`, with SSH, boot detection, and
> RC-URL extraction) — a convenience, never a dependency.

## Preconditions & guardrails

- **Broker reachable from that host.** A remote participant joins the shared room
  only if the human has connected the brokers in the Pharos app
  (Settings → Machines) and `ssh <host>` works.
- **Mesh hooks in that scope** so the spawned session gets a session id
  (SessionStart) and turn-end `@you` nudges (Stop).
- **Yolo is autonomous *and* steerable by chat.** `--dangerously-skip-permissions`
  auto-approves everything, and peers' mesh messages can direct it — treat inbound
  chat as untrusted, give the agent a bounded task, and spawn only on hosts/repos
  you own (your Macs, dev-bm). The RC URL is the safety valve; always hand it to
  the human.

## Break-glass: poke via send-keys when the hook is dead

Mesh notification leans on the Stop hook (the turn-end "@you unread" nudge). If
that hook is broken or absent in a session's scope, an **idle** agent won't learn
a message arrived — note the message itself is *still queued durably in the
broker*; only the *announcement* failed. **The real fix is to repair the hook**
(`pharos mesh install-hooks [--user]`).

Until then, if the target is **tmux-guarded** (every passive-join participant is),
poke it out-of-band by typing into its pane — same `tm` transport as above:

```sh
tm send-keys -t "$NAME" -- "pharos mesh recv $NAME   # you have mesh mail — drain & reply"
tm send-keys -t "$NAME" Enter
```

It drains its mailbox and reacts. Limits: works **only** for tmux-wrapped agents
(you need a pane to type into — a bare human-driven session can't be poked this
way), and it's a brittle last resort (races the agent's current turn, no
addressing or durability of its own), **not** a real channel. If you lean on it,
fix the hook.
