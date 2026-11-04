# RFC-005: Lightweight Agent Messaging

- Status: Proposed
- Date: 2026-11-03
- Supersedes: the External fallback in [RFC-003](RFC-003-AGENT-RUNTIME-RPC.md) (tmux / SSH as the only unwired path)
- Does not supersede: RFC-003 Managed and Attached runtimes, the Broker Node command route, or Host Runtime RPC

## Problem

The full integration treats every agent like a patient on tubes: a plugin, a hook, or a Host Runtime lease before Pharos can wake it. That tier stays. It is the right module when Pharos owns the runtime.

Most sessions are not wired that way. They already expose something Pharos can drive from outside: a headless CLI, a loopback desktop socket, or, as a last resort, a terminal. The owner wants those sessions in one directory, addressed by a stable name, with replies that find their way back without the recipient knowing where the sender lives.

## Decision

Add a second tier beside RFC-003. The heart of it is a **member registry** and **point-to-point messages** routed by member id. A recipient is told who sent the copy they received. They are not told who else was copied.

A thread is an email conversation, not a chat room:

- A **new** message (not a reply) mints a thread id. There is no `thread new`, no membership list, and no `thread add`.
- A reply names a reply-id. The thread id is inherited from the message that reply-id was issued for, the way `In-Reply-To` / `References` work. The replier never passes a thread id.
- Sending to several member ids at once, or `@`-mentioning someone in a reply, is more 1:1 deliveries that carry the same thread id. Like CC. Each copy gets its own reply-id.
- Participants are **derived** from who has sent or received in that thread. They are not stored. Two participants render as a direct message. Three or more render as a group. That is a view over one code path, not a type.
- A fresh non-reply message starts a new thread. That is how the topic changes.
- The only discovery operation is listing registered members.

The first cut of this RFC shipped the rejected shape: a thread object with a stored roster, `thread new` / `thread add`, and `@all` expanding that roster. The owner rejected it. Delivery is always 1:1, and a recipient must not learn a roster they were not told about in the message text.

The Broker (the always-on Mac) owns the registry, the per-thread append-only log, the reply-id ledger, and the outbox. Other hosts do not run a second stack. `pharos reply` on those hosts forwards to the Broker over the existing SSH route. No new public port. Loopback debug ports bind `127.0.0.1` only.

```text
pharos member / send / reply / wait / read / thread list|show
        |
LightRelay                         PharosMeshCore
  registry, point-to-point send, reply inheritance,
  derived participants, per-thread log, ledger, outbox
        |
LightSessionDriver                 seam
  ExternalLightDriver              PharosRuntime  (route policy; live turns unverified)
  in-memory fake                   tests
        |
SSH forwarder                      only when PHAROS_LIGHT_SSH_HOST is set
```

RFC-003 still answers "how do we drive a runtime Pharos owns?" This RFC answers "how do we address a session Pharos does not own?" A member may exist in both tiers. This tier does not register Host Runtime leases and does not write Mesh mailboxes.

## Glossary

Terms from the codebase-design vocabulary, used here as specified:

- **Module**: `LightRelay` is the deep module. The route catalog plus `ExternalLightDriver` is a second module behind a seam.
- **Interface**: what a caller must know. For the relay that is register / list members, send, reply, read, wait, list/show threads, and sweep, plus the invariants below. Not the ledger layout, and not a roster.
- **Seam**: `LightSessionDriver`. Behavior on the far side can change without editing the relay.
- **Adapter**: the in-memory fake, and `ExternalLightDriver`. Two adapters make the seam real.
- **Depth**: point-to-point send plus reply-id inheritance hides thread minting, derived participants, hops, expiry, and the single-writer queue.
- **Leverage**: CLI, a future Mac UI, and the tests all cross that interface.
- **Locality**: a hop-limit bug is fixed in the relay, not in each caller.

Dependency categories for the deepened module:

| Dependency | Category | How tests cross it |
| --- | --- | --- |
| Mentions, hops, ledger, queue ordering | In-process | Call the relay |
| Directory files | Local-substitutable | Temporary directory |
| `pharos reply` from another host | Remote but owned | Injected forwarder, in-memory adapter in tests |
| Codex, Claude, DSH, Antigravity, tmux | True external | Injected driver. The external adapter's plans are tested; live app turns are not |

## Design it twice

Constraints any interface had to meet:

- Delivery is point-to-point. A group is a presentation over several 1:1 copies, not a room the recipient can see.
- No plugin inside the agent. Senders address members by stable id. Pharos resolves the route.
- The only discovery operation is listing the registry. A recipient does not learn other recipients from the header.
- A reply never takes a thread id. The reply-id carries the thread.
- Each hand-off increments hop. At the limit the thread stops and the originator (the member who sent the first message) is notified.
- One writer per session. Queue while that session is busy. Reply-ids expire (default 24h). Queued deliveries expire (default 72h).
- Inbound text is data. Nothing in this tier answers an approval prompt unless a later, explicit call asks for that.
- The full RFC-003 path keeps working.

### A — Email threading on one relay (chosen)

```swift
relay.register(member)
relay.send(from:to:text:ttl:once:hopLimit:)   // mints a thread; one log line, N deliveries
relay.reply(id, text:ttl:once:)               // inherits the thread; CC via @mention
relay.read(thread:) / relay.read(replyID:)
relay.listThreads() / relay.show(thread:)     // participants derived, kind is direct or group
relay.wait(replyID:timeout:)
relay.sweep()
```

The constructor takes a clock, a driver, and an optional forwarder. Callers do not learn route order, ledger keys, or queue internals. The thread id is in the owner log and in the per-copy header so `thread show` works. The reply command does not accept it.

Leverage is high: the CLI is a parser over this interface, and the tests are too. Locality is high: inheritance, hop, and expiry live in one place. The seam sits at the driver, which is the thing that actually varies (fake vs. external apps).

### B — A thread with a stored roster (rejected; this was the first cut)

```swift
relay.openThread(members:hopLimit:)
relay.addMember(name, to:)
relay.send(from:thread:text:)   // @mentions choose who wakes; @all expands the roster
```

One room type for 1:1 and group looks simple, and it keeps the thread id stable before the first send. It is the wrong module. Membership becomes something the system stores and something a delivery can reveal. `@all` only works if a roster exists, which tells every recipient that the others exist. The owner rejected this after it had been implemented: a group is several 1:1 deliveries that happen to share a thread id, and participants fall out of who was actually copied.

### C — A public module per step (rejected)

Separate public types for the directory, the mention parser, the hop counter, the ledger, the outbox, and the log. Each is easy to swap. The deletion test fails: deleting them pushes the same rules back into the CLI and into every test. The interface is almost as large as the implementation, which is a shallow module. Mention parsing stays a small public function because the header contract is part of the interface; the rest of C does not.

### D — Brand switch inside the relay (rejected)

`switch member.app` inside `LightRelay` would avoid a driver type. Vendor policy would then sit in the data module, and tests could not replace Codex with a fake without editing that switch. A driver seam is justified because two adapters exist: the test fake and the external planner. A single production adapter with no fake would have been a hypothetical seam and was not added.

The shipped shape is A. D's port is a constructor argument rather than a second product surface. Default routes live in the driver module (`LightRouteCatalog`), not in the relay. Hiding the thread id from the log as well as from the reply command was considered and rejected: the owner still needs `thread show`, and the header still names the thread so a human can read it. Agents answer with the reply-id only.

## Interface

Invariants a caller has to know:

- Member names match `^[a-z][a-z0-9-]{0,62}$`. Host and app labels use the same pattern, so an address, a home path, or an email cannot be stored as a name.
- Session ids are opaque vendor ids. `/`, `~`, and `@` are rejected so a path does not become an id.
- Registering the same name, host, app, project, and session is idempotent. The same name with a different session is an error. Listing members is the only discovery operation.
- `send(from:to:text:)` requires at least one recipient other than the sender. An unknown id in `to` is an error and does not mint a thread. Duplicate ids collapse. The call mints a thread whose originator is the sender, appends one message, and delivers one copy per recipient. Each copy has its own reply-id, hop 1, and the same thread id. `@` tokens in a new send are body text, not extra recipients. `@all` is not special.
- `reply` looks up the reply-id and uses that message's thread. It always delivers back to the previous sender, then adds one more 1:1 copy for each `@` of a registered member (not the replier, de-duplicated). An `@` of someone who is not registered is unresolved, not fatal. An `@` inside an email is not a mention.
- Participants are the originator plus every message sender and delivery target in the log, first time seen, registered members only. `listThreads` and `show` compute them. The snapshot does not store them. Kind is `direct` at two or fewer and `group` at three or more.
- Tokens after `--` are the message. A trailing `--json` stays text. It is not an option.
- The delivered body is the text plus a header that names the sender, the thread, this copy's reply-id, and the hop. It does not list other recipients. A hop-limit stop notice omits the `pharos reply` line:

```text
[pharos from=<member> thread=<id> reply-id=r_<8+ chars> hop=<n>/<max>]
Reply with `pharos reply r_xxx "..."` (you may @mention another member). Pharos reads this session if you cannot run that command.
```

  If `PHAROS_LIGHT_WEBHOOK` is a loopback `http` or `https` URL, the header also names a POST of `{"replyId","text"}`. Any other host is rejected. This tree does not bind a listener; `LightWebhookIntake` accepts a body the process already has.

- Reply-ids are random (`r_` plus at least eight lowercase letters or digits). Malformed, unknown, expired, and already-consumed ids are rejected and appended to the rejection log. `--once` consumes the id on the first accepted reply. Without `--once` the id stays usable until its TTL, and each accepted reply advances the hop so reuse cannot reset the limit.
- Default reply TTL is 24h (`--ttl` accepts seconds or a `30s` / `12m` / `24h` / `1d` suffix). Default queue TTL is 72h. `sweep` drops expired ledger rows and expired outbox rows and appends a notice for the originator. The thread log and the rejection log are append-only; they are not pruned.
- While a target is busy, or already has queued work, further deliveries for that member wait. `pump` (also called from `sweep` and after `send` or `reply`) flushes in order and stops at the first member that is still busy. The queue is per member, so two new sends (two threads) to one busy member still leave in order.
- Each reply that would pass the thread hop limit (default 8, set with `--hop-limit` on `send`) stops the thread, logs the reply, and wakes the originator with a terminal notice. That notice does not tell the originator to run `pharos reply`. A reply to that notice is stored and does not fan out. A later reply on the stopped thread fails. A new `send` is a new thread and is not blocked by the stop.
- `wait` returns when a reply to that id is in the log, or when the driver returns text it can prove is new. It does not scrape a terminal pane: old pane text is not a reply. A wait that is still pending when the timeout ends exits 2.
- `read --thread` returns that thread's log. `read r_xxx` resolves the reply-id to the same log and does not record a rejection when the id is bad. The log is for the owner and for an agent that needs context. It is not a roster pushed to recipients. `thread show --json` includes that same log as `messages`.
- Inbound text is stored and forwarded as data. This module does not shell it out and does not answer approval prompts.

`LightCommands.execute` is the CLI seam: same results the macOS `pharos` binary prints. Exit 0 is success, 1 is a rejected operation, 2 is usage or a `wait` that is still pending.

## Routing

The relay never switches on the app. The driver does, and only to choose a route.

Headless routes come first. That is a deliberate change from achat's Codex order, which prefers desktop IPC while the desktop holds the writer lock. This tier's reason to exist is sessions that are not intubated, so the plan tries the headless route before the desktop. A certified executor that sees a writer lock should skip `codex exec resume` and try IPC; that executor is not certified here, so an unverified send reports the first writable route and stops.

| App | Send order | Notes |
| --- | --- | --- |
| codex | `app-server`, `ipc`, `desktop`, `tmux` | `app-server` is `codex exec resume` on stdin. It does not answer approvals. `ipc` and `desktop` are one `achat codex send`. |
| claude | `headless`, `tmux` | `claude -p --resume`, prompt on stdin. No permission-bypass flags. |
| dsh | `web`, `desktop`, `files`, `tmux` | `web` and `desktop` are `achat dsh send`. achat owns the on-demand loopback server (`--host 127.0.0.1 --port 0 --no-open`) and stops it after the turn. `files` is read-only and is never a send. |
| ag | `desktop` | `achat ag send`. CDP stays in achat. |
| cursor | `cursor-agent`, `desktop` | Design. Headless is `cursor-agent --resume <id> -p`. Desktop is CDP. The workspace is the folder. Pharos accepts app id `cursor` and delegates both routes to achat. It does not spawn `cursor-agent`. |

`tmux` is always last, `fallback == true`, summary prefixed `last resort`. Its send plan is `tmux send-keys -l` plus Enter. Its read plan is `capture-pane`. Neither is ingested automatically.

`PHAROS_CODEX_BIN`, `PHAROS_CLAUDE_BIN`, `PHAROS_DSH_BIN`, and `PHAROS_TMUX_BIN` override the bare command names. Those values stay in the environment, not in the repo. `PHAROS_LIGHT_LIVE=1` may spawn the headless and tmux plans. Even then `liveVerified` stays false. With that switch, a desktop, ipc, or web route (and Cursor's `cursor-agent` route) is one achat call, not a Pharos CDP or IPC client:

```text
achat <app> send --host local --json --session <id> --no-webhook "<header+body>"
achat <app> read --host local --json --session <id> --open
```

`achat read` has no timestamps. Pharos records `repliesBefore` (a read before send, or the count achat returns on send) and treats a later read with a higher `replies` count as the new reply. `achat <app> wait` exists and blocks; `pharos wait` polls `read` instead. Without `PHAROS_LIGHT_LIVE=1` those routes stay deferred.

## Relay

Non-broker hosts set `PHAROS_LIGHT_SSH_HOST` to an existing SSH alias. `pharos reply` then runs `ssh -o BatchMode=yes -- <alias> pharos reply '<id>' -- '<text>'`. `wait`, `read`, and `thread list|show` use the same SSH route and keep the Broker's exit code (`wait` still pending is 2). There is no `-L` or `-R`. The alias is configuration, not a committed address. If the forwarder returns a result, the local process does not write the ledger.

The directory lives under the application-support `Pharos/light-relay` directory, or `PHAROS_LIGHT_RELAY` when that is set. Files are owner-readable only. Nothing in the committed tree names a person, a machine, a home directory, or a private address.

## Why Swift, not a call to achat

achat is the reference for route policy: per-app order, DSH's on-demand loopback server, Codex's writer lock, and the refusal to auto-answer approvals. Messaging rules stay in Swift.

- Pharos is a SwiftPM app. Shelling out to Node for hops, TTL, or mentions would add a second place for those rules. The deletion test would fail: they would reappear in every caller as a process invocation.
- achat's write paths were not verified live. Wrapping the CLI would not certify ordinary sends.
- The behavior this RFC has to get right (directory, reply-ids, mentions, hops, queue) is in-process and is tested through `LightRelay`.

Session creation delegates to the achat executable (`PHAROS_ACHAT_BIN`, default name `achat`) and passes `--json`. Desktop, ipc, and web delivery do too, so Pharos does not reimplement those routes. The binary path is personal config and is not committed. achat's own source is not vendored.

What stays in Swift for ordinary sends is the policy table and the headless argv shapes (`codex exec resume`, `claude -p --resume`). What was not ported is the TypeScript CDP/IPC/web clients.

## Session creation

`pharos session new --host H --app dsh|ag|codex|cursor --workspace PROJECT|DIR` creates a session on that Pharos node and, on success, registers a member so `pharos send` can address it. The default member name is `<app>-<host>-<workspace>` (slug), overridable with `--name`. The same name with a different session is an error and does not replace the existing member. `--path DIR` is the directory when `--workspace` is only a project name. A `--workspace` that contains `/` or starts with `~` is the directory, and the project name is its last component.

`pharos session workspaces --host H --app A` lists the projects achat can see on that node.

`--host local`, `localhost`, this machine's hostname and its short name, and `PHAROS_SELF_HOST` / `PHAROS_NODE_NAME` run in-process and register the member. `--here` is what a forward runs on the target: it returns JSON and does not register. A remote host is `ssh -o BatchMode=yes` of `pharos session … --here`, with no tunnel. The caller never falls back to its own machine. `--title` is the first message achat's `new` accepts. Codex and Antigravity with no `--title` send `Pharos session ready. Reply READY.` instead of surfacing a raw achat error. Antigravity's `new` opens a blank conversation and has no id until that first message is sent. Pharos passes the text. achat must insert it and press Enter (the send button stays disabled after insertion) and return `sessionId` or `state.conversation`. Until achat does that, Pharos stops with that contract in the error and does not register a member. `--dry-run` asks achat for the plan, does not launch, and does not register a member. `--launch --dry-run` also reports the resolved port, the probe (`ready`, `runningWithoutDebug`, `portHeldByOther`, `absent`), and `would-launch` yes or no. It does not start the app.

Route choice stays in achat (`achat <app> probe` and achat's own config). Codex reaches the app through app-server/IPC and does not need a debug port. DSH can use its on-demand web server. Pharos does not require `PHAROS_<APP>_CDP_PORT` and does not probe a debug endpoint unless `--launch` is set.

`--launch` is opt-in, on `new` and on `workspaces`, and it is the only path that needs an app executable and a debug port. The target applies one check, then stops:

| Probe | Result |
| --- | --- |
| Debug endpoint answers and belongs to this app | Reuse it |
| App process is up, endpoint is not | Do not kill it. Ask the owner to quit and relaunch. A relaunch of the same app reuses the running instance and would ignore the debug flag |
| Port answers as something else | Touch nothing |
| Nothing is there | Start the configured executable with `--remote-debugging-address=127.0.0.1` and wait until the endpoint belongs to the app |

The port is the first value that is set: `PHAROS_DSH_CDP_PORT`, `PHAROS_AG_CDP_PORT`, or `PHAROS_CODEX_CDP_PORT`; else `cdpPort` in the achat config (`PHAROS_ACHAT_CONFIG` or `ACHAT_CONFIG`, under `defaults.<app>` or the top-level app entry); else the launch default dsh `9301` and Codex `9302`. Antigravity has no compiled-in port. `--launch` with no port is `debug port is not configured`, and nothing is spawned. App executables stay `PHAROS_DSH_APP`, `PHAROS_AG_APP`, and `PHAROS_CODEX_APP`.

`session new` lists workspaces on the target and, when the project is missing, runs project add before `achat new`. `--no-add-project` is the strict switch: the command fails with `project is not registered` and does not call `new`. That flag is forwarded as achat's `--no-add-workspace`, because achat `new` also adds a missing workspace unless told not to. Status `added` or `already` continues into session create. `needs_user_action` stops session new and surfaces the hint. A send addresses a member that already has a session. A route that has to open one uses this same add and stops only on `needs_user_action`.

## Project registration

`pharos project list|add --host H --app dsh|ag|codex|cursor --path DIR` registers a workspace in that app. `project list` reports the same `addable` as `project add`: DSH is `ui` when its desktop debug endpoint is up, and `api` when the desktop is absent. It uses the same target-node path as session creation: the caller forwards `pharos project … --here`, or leaves one inbox job when the node is offline. The caller does not run achat, and it does not fall back to its own machine. `--no-queue` returns `node offline` immediately. `--dry-run` does not register a project. Add is idempotent: the target lists projects and returns `already` when the path is already there.

The deep module stays `LightRelay` for the inbox. Project add is a small seam on `LightSessionService`: one capability (`addable`) and one achat contract. achat owns the per-app adapter. Pharos does not open the app's files.

Contract, on the target only:

```
achat <app> workspace list --host local --json
achat <app> workspace add <path> --host local --json [--name N] [--dry-run]
```

`PHAROS_ACHAT_BIN` is the executable. A project row is `{name, path}`. Statuses are `added`, `already`, `needs_user_action`, `node offline`, and `queued`. `addable` is `api`, `ui`, or `restart`.

`restart` means a live app would throw away an out-of-band write. Pharos does not write the file and does not tell the owner to drop one in. It returns `needs_user_action`.

Verified on a Mac, and left to achat rather than reimplemented here:

| App | Where projects live | What Pharos asks for |
| --- | --- | --- |
| codex | `~/.codex/state_5.sqlite`, through experimental app-server `project/list`, `project/create`, and `project/delete`. The client sends `capabilities.experimentalApi: true`. `project/create` takes `{idempotencyKey, name, roots:[{path}]}` and is idempotent. Trust entries in `config.toml` are optional | `addable: api`. No debug port and no file edit |
| dsh 0.2.1 | `~/.dsh/storages/workspace.json`. There is no CLI command. `workspace/create {request:{path}}` on a `dsh web` server is idempotent. The desktop app is the single writer and rewrites the whole file, so a web-side add made while the desktop is running is lost | Desktop debug endpoint ready: `addable: ui` (Add workspace through that UI). Desktop not running: `addable: api`. Desktop running without a debug port: `addable: restart`, status `needs_user_action`, and nothing is written. A port owned by another process is left alone |
| antigravity | One JSON file per project under `~/.gemini/config/projects/<uuid>.json`, written by the app's language server with a private token. Files dropped while the app is running are not loaded, and that directory is off limits | `addable: ui` only, and only when the debug endpoint belongs to Antigravity (Create New Project, then the folder picker). Otherwise `needs_user_action`. Pharos does not write that directory |

The probe table applies when a debug port is configured. Codex is always `addable: api` and is not probed. DSH and Antigravity with no configured port are handed to achat (`api` and `ui`) instead of failing with `debug port is not configured`. Cursor is `addable: api` and is not probed. Its project is the workspace folder. achat will own `cursor-agent --resume <id> -p` and the desktop CDP route. Pharos only accepts the app id and delegates.

## Cursor

Cursor is installed on the Mac mini. This tier does not implement it yet beyond the app id.

| Route | What it is |
| --- | --- |
| `cursor-agent` | Headless resume: `cursor-agent --resume <id> -p`. The workspace is the folder the agent was opened in. |
| `desktop` | CDP on `127.0.0.1`, same loopback rule as the other desktop apps. |

Pharos send, read, and wait for those routes are `achat cursor send|read|wait`. Session create and project add are `achat cursor new` and `achat cursor workspace list|add`. The local install and the achat driver are still to be written on the achat side.

## Node inbox

Each machine is a Pharos node. A node is online when a heartbeat is inside the Broker's 70s window. `pharos session pull` (and `session heartbeat`, the same call) records that heartbeat and returns waiting jobs. There is no heartbeat daemon in this tier. When the heartbeat is missing or stale, presence is `ssh -o BatchMode=yes -o ConnectTimeout=5 <H> pharos --version`. A zero status runs the real command directly and does not record a heartbeat, so the probe does not pull jobs. A failed probe is `node offline`, with `last-seen` when a heartbeat was recorded and `last-seen never` when it was not, and that request is queued. A reachable machine is not reported offline. The caller does not describe a machine as unreachable, and it does not create the session or deliver the message on its own machine.

The Broker keeps one inbox per node in the same store as the single-writer outbox (`state.json`, queue TTL 72h). `enqueue` appends a job. The node `pull`s on heartbeat and may see the same id again until `ack` removes it. A repeated id, or a second ack, is ignored. `sweep` drops expired jobs. That is the whole queue. There are no exchanges, routing keys, topics, priorities, consumer groups, or an external message broker.

`session new`, `session workspaces`, `project list`, and `project add` enqueue when the node is offline, and report `queued` plus the request id. `--no-queue` returns `node offline` immediately. A forward that does not come back with a result is the same offline path, not a local achat call. When the node completes a `session-new` job, the Broker registers the member from that result. A `needs_user_action` result is terminal: the job is acked and not retried.

A send to a member whose node has gone offline since its last heartbeat waits in that node's inbox. The driver on the caller is not invoked. A member whose node has never heartbeated is unchanged, so a local directory still delivers.

`pharos session pull --node H` records the heartbeat and prints waiting jobs. `pharos session ack <id> [--result JSON]` removes the job and, for a created session, registers the member.

## Coexistence with RFC-003

| | RFC-003 full tier | RFC-005 lightweight tier |
| --- | --- | --- |
| Who it is for | Runtimes Pharos supervises or that register themselves | Sessions Pharos drives from outside |
| Identity | Runtime member id, lease generation | Stable directory name |
| Wake | Host Runtime RPC, native driver | Driver route, else the reply header |
| Busy | Delivery queue on the runtime | Single-writer outbox on the relay |
| Fallback the user sees | Not tmux | tmux only as a labelled last route |
| Approval | Scoped `approval/resolve` on a lease | Not performed |

`pharos mesh …` is unchanged. `pharos member`, `send`, `reply`, `wait`, `read`, `thread list|show`, `session`, and `project` are this tier. `thread new` and `thread add` are usage errors.

## Testing

Tests cross `LightRelay`, `LightCommands`, and `LightRoutePlanner`. They do not read private ledger fields.

Covered: directory resolution and conflicts, a new send minting a thread, multi-recipient send as N 1:1 copies that share a thread id and hide each other from the header, reply-id inheritance of that thread, `@` on a reply adding copies without replacing the previous sender, `@all` left unresolved, derived participants and direct/group kind, participants absent from the snapshot, reply-id issue / lookup / expiry / `--once` / forged ids, hop along a reply chain and the originator notice, queue order across two sends to one member, queue expiry, wait-once ingestion, SSH-shaped forwarding, loopback webhook intake, reload of the append-only log, headless argv with no approval bypass, unverified external delivery, session-new argument mapping and achat JSON, member registration and name collision, dry-run, the launch decision table, a missing debug port only when `--launch` is set, launch defaults (dsh 9301, Codex 9302) with env and achat-config overrides, session create without a debug port, `--host local` and a configured self alias running in-process, an SSH `pharos --version` probe that runs a reachable node directly and queues only when the probe fails, node-offline queue and `--no-queue`, no local fallback when a forward fails, inbox pull/ack/expiry, duplicate request ids, project add by path (including the already-registered no-op), the `api` / `ui` / `restart` decision, `needs_user_action` without writing app files, session new auto-adding a missing project, `--no-add-project` refusing to create, `needs_user_action` stopping session new, achat send/read for desktop routes with reply-count harvest, a default first message for Codex and Antigravity, `--launch --dry-run` reporting port/probe/would-launch, a hop-limit notice without a reply invitation, `thread show --json` messages, `wait` exit 2 on timeout, SSH forward of wait/read/thread, DSH list `addable` matching add, and app id `cursor` delegated to achat.

Not certified, and not run by CI:

- A real Codex, Claude, DSH, or Antigravity turn on a Mac.
- A real `achat` create against a live desktop app, a real `--launch` of that app, and a real `workspace add` in Codex, DSH, or Antigravity.
- Desktop IPC frames, CDP, and the DSH "start web, call, stop" cycle.
- `PHAROS_LIGHT_LIVE=1` against a bundled `codex` binary.
- SSH forwarding to a live Broker.
- Binding the loopback webhook listener.

`swift build` of the macOS app target needs a Mac. On Linux, build and test `PharosMeshCore` and `PharosRuntime` (see the package manifest: the SwiftUI test target is macOS-only).

## Security

- Agent text is untrusted. The relay stores it. It does not evaluate it.
- Approval popups are not answered.
- Reply-ids are unguessable random tokens, checked against the ledger, and logged when rejected.
- Webhooks that are not loopback are refused.
- Debug binds in the planned DSH and CDP routes are `127.0.0.1` only.
- No new listening port is opened by this change.
- `--launch` binds the debug port to `127.0.0.1` only. An endpoint that belongs to another process is left alone.
- Environment variables override debug ports. The compiled launch defaults are the public achat ports (dsh 9301, Codex 9302). Antigravity's port stays in achat config or `PHAROS_AG_CDP_PORT`. No personal path is written into the tree.

## Addendum (2026-11): addressing, intents, webhook members

- **Addressing is by parameters only.** `send --to/--cc` and `reply --cc` name every
  recipient. `@name` in a body is plain text; an unaddressed registered member yields a
  `hint:` line (stderr / `hints` in JSON), never a delivery. A reply goes back only to
  the sender of the message it answers, plus `--cc`. Harvested replies are never copied.
- **Intents** (`--intent`): `ask` (default for send; delivered, reply expected),
  `inform` (delivered FYI, no reply expected), `answer` (default for reply; recorded in the
  thread for the asker and delivered only with `--deliver` on the send or the reply),
  `discuss` (delivered each turn; `--rounds N`, default 4, still bounded by the hop limit;
  `DONE` or the cap closes it and the originator is asked for a one-line conclusion that is
  recorded in the thread). Intent is stored on the thread and each message and shown by
  `thread show`. Tickets issued with FYI/answer/cc/recorded copies are not harvested by `wait`.
- **Headers** say the intent; FYI and answer headers say "do not reply unless you need
  clarification" and carry no `pharos reply` invitation.
- **Webhook members** (`--app webhook`) are remote assistants reached by HTTPS POST of the
  delivery envelope to a named config in `~/.config/pharos/webhooks.json` (mode 600; secret
  from stdin/file/env, never argv, never printed). They answer with `pharos reply`; there is
  no harvest. Delivery needs `PHAROS_LIGHT_LIVE=1`, like every live route.
- Agents are encouraged (not required) to delegate messaging to a subagent that returns only
  the conclusion. See `pharos help chat` and `skills/pharos-chat/SKILL.md`.
