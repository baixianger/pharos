# RFC-005: Lightweight Agent Messaging

- Status: Proposed
- Date: 2026-11-03
- Supersedes: the External fallback in [RFC-003](RFC-003-AGENT-RUNTIME-RPC.md) (tmux / SSH as the only unwired path)
- Does not supersede: RFC-003 Managed and Attached runtimes, the Broker Node command route, or Host Runtime RPC

## Problem

The full integration treats every agent like a patient on tubes: a plugin, a hook, or a Host Runtime lease before Pharos can wake it. That tier stays. It is the right module when Pharos owns the runtime.

Most sessions are not wired that way. They already expose something Pharos can drive from outside: a headless CLI, a loopback desktop socket, or, as a last resort, a terminal. The owner wants those sessions in one directory, addressed by a stable name, with replies that find their way back without the recipient knowing where the sender lives.

## Decision

Add a second tier beside RFC-003. One primitive covers 1:1 and group chat: a **thread** with a member list. A 1:1 conversation is a two-member thread. A group is the same thread with more members. There is no moderator role.

The Broker (the always-on Mac) owns the directory, the thread log, the reply-id ledger, and the outbox. Other hosts do not run a second stack. `pharos reply` on those hosts forwards to the Broker over the existing SSH route. No new public port. Loopback debug ports bind `127.0.0.1` only.

```text
pharos member / thread / send / reply / wait / read
        |
LightRelay                         PharosMeshCore
  directory, thread log, ledger, outbox, hop limit, TTL
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
- **Interface**: what a caller must know. For the relay that is register / list / open / add / send / reply / read / wait / sweep, plus the invariants below. Not the ledger layout.
- **Seam**: `LightSessionDriver`. Behavior on the far side can change without editing the relay.
- **Adapter**: the in-memory fake, and `ExternalLightDriver`. Two adapters make the seam real.
- **Depth**: one thread primitive hides mentions, reply-ids, hops, expiry, and the single-writer queue.
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

- One primitive for 1:1 and group chat. No plugin inside the agent.
- Senders address members by stable name. Pharos resolves the route.
- Delivery wakes only `@` mentions. `@all` wakes every other member once. A reply with no mention goes back to the sender.
- Each hand-off increments hop. At the limit the thread stops and the member who opened it is notified.
- One writer per session. Queue while that session is busy. Reply-ids expire (default 24h). Queued deliveries expire (default 72h).
- Inbound text is data. Nothing in this tier answers an approval prompt unless a later, explicit call asks for that.
- The full RFC-003 path keeps working.

### A — One relay (chosen)

```swift
relay.register(member)
relay.openThread(members:hopLimit:)
relay.send(from:thread:text:ttl:once:)
relay.reply(id, text:ttl:once:)
relay.read(thread:)
relay.wait(replyID:timeout:)
relay.sweep()
```

The constructor takes a clock, a driver, and an optional forwarder. Callers do not learn route order, ledger keys, or queue internals.

Leverage is high: the CLI is a parser over this interface, and the tests are too. Locality is high: expiry and hop rules live in one place. The seam sits at the driver, which is the thing that actually varies (fake vs. external apps).

### B — A public module per step (rejected)

Separate public types for the directory, the mention parser, the hop counter, the ledger, the outbox, and the log. Each is easy to swap. The deletion test fails: deleting them pushes the same rules back into the CLI and into every test. The interface is almost as large as the implementation, which is a shallow module. Mention parsing stays a small public function because the header contract is part of the interface; the rest of B does not.

### C — Send creates the thread (rejected as the only interface)

`send(from:to:text:)` would open a two-member thread on first contact. That makes the common 1:1 call one line. It hides the thread id the reply header has to carry, and it turns group membership into a side effect of mentions. `thread new` keeps the id stable before the first send. Mentions inside that thread are still how a message chooses who wakes up, so 1:1 and group chat stay the same call.

### D — Brand switch inside the relay (rejected)

`switch member.app` inside `LightRelay` would avoid a driver type. Vendor policy would then sit in the data module, and tests could not replace Codex with a fake without editing that switch. A driver seam is justified because two adapters exist: the test fake and the external planner. A single production adapter with no fake would have been a hypothetical seam and was not added.

The shipped shape is A, with D's port as a constructor argument rather than a second product surface. Default routes live in the driver module (`LightRouteCatalog`), not in the relay.

## Interface

Invariants a caller has to know:

- Member names match `^[a-z][a-z0-9-]{0,62}$`. Host and app labels use the same pattern, so an address, a home path, or an email cannot be stored as a name.
- Session ids are opaque vendor ids. `/`, `~`, and `@` are rejected so a path does not become an id.
- Registering the same name, host, app, project, and session is idempotent. The same name with a different session is an error.
- A thread has at least two members. The first member is the opener. The opener is who hears about a stop or an expired queue item. That is not a moderator role; they have no extra say over other members' turns.
- `send` appends to the shared log always. It wakes a member only when the text `@`-mentions them. `@all` means every member except the sender, once. An `@` inside an email is not a mention. Unknown names are reported and skipped.
- A reply with no mention is delivered to the member who sent the message that carried that reply-id. A reply that contains mentions is a hand-off to those members only.
- The delivered body is the text plus a header:

```text
[pharos from=<member> thread=<id> reply-id=r_<8+ chars> hop=<n>/<max>]
Reply with `pharos reply r_xxx "..."` (you may @mention another member). Pharos reads this session if you cannot run that command.
```

  If `PHAROS_LIGHT_WEBHOOK` is a loopback `http` or `https` URL, the header also names a POST of `{"replyId","text"}`. Any other host is rejected. This tree does not bind a listener; `LightWebhookIntake` accepts a body the process already has.

- Reply-ids are random (`r_` plus at least eight lowercase letters or digits). Malformed, unknown, expired, and already-consumed ids are rejected and appended to the rejection log. `--once` consumes the id on the first accepted reply. Without `--once` the id stays usable until its TTL, and each accepted reply advances the hop so reuse cannot reset the limit.
- Default reply TTL is 24h (`--ttl` accepts seconds or a `30s` / `12m` / `24h` / `1d` suffix). Default queue TTL is 72h. `sweep` drops expired ledger rows and expired outbox rows and appends a notice for the opener. The thread log and the rejection log are append-only; they are not pruned.
- While a target is busy, or already has queued work, further deliveries for that member wait. `pump` (also called from `sweep` and after `send`) flushes in order and stops at the first member that is still busy.
- Each reply that would fan out past the thread hop limit (default 8, set with `--hop-limit`) stops the thread, logs the reply, and wakes the opener with a terminal notice. A reply to that notice is stored and does not fan out. Later `send` on a stopped thread fails.
- `wait` returns when a reply to that id is in the log, or when the driver returns text it can prove is new. It does not scrape a terminal pane: old pane text is not a reply.
- `read` returns the shared log. Unmentioned members can read it. They are not woken.
- Inbound text is stored and forwarded as data. This module does not shell it out and does not answer approval prompts.

`LightCommands.execute` is the CLI seam: same results the macOS `pharos` binary prints. Exit 0 is success, 1 is a rejected operation, 2 is usage.

## Routing

The relay never switches on the app. The driver does, and only to choose a route.

Headless routes come first. That is a deliberate change from achat's Codex order, which prefers desktop IPC while the desktop holds the writer lock. This tier's reason to exist is sessions that are not intubated, so the plan tries the headless route before the desktop. A certified executor that sees a writer lock should skip `codex exec resume` and try IPC; that executor is not certified here, so an unverified send reports the first writable route and stops.

| App | Send order | Notes |
| --- | --- | --- |
| codex | `app-server`, `ipc`, `desktop`, `tmux` | `app-server` is `codex exec resume` on stdin. It does not answer approvals. IPC and CDP are planned only. |
| claude | `headless`, `tmux` | `claude -p --resume`, prompt on stdin. No permission-bypass flags. |
| dsh | `web`, `desktop`, `files`, `tmux` | `web` is the on-demand loopback server (`--host 127.0.0.1 --port 0 --no-open`), stopped after the turn so the writer lock is released. `files` is read-only and is never a send. The web lifecycle is planned, not executed. |
| ag | `desktop` | CDP on loopback. Planned only. |

`tmux` is always last, `fallback == true`, summary prefixed `last resort`. Its send plan is `tmux send-keys -l` plus Enter. Its read plan is `capture-pane`. Neither is ingested automatically.

`PHAROS_CODEX_BIN`, `PHAROS_CLAUDE_BIN`, `PHAROS_DSH_BIN`, and `PHAROS_TMUX_BIN` override the bare command names. Those values stay in the environment, not in the repo. `PHAROS_LIGHT_LIVE=1` may spawn the executable headless and tmux plans. Even then the result is `liveVerified == false`. IPC, CDP, and the DSH web start/stop sequence return `deferred` with an unverified detail. They are not executed, because a wrong IPC frame or a leaked writer lock is worse than a deferred delivery.

## Relay

Non-broker hosts set `PHAROS_LIGHT_SSH_HOST` to an existing SSH alias. `pharos reply` then runs `ssh -o BatchMode=yes -- <alias> pharos reply '<id>' '<text>'`. There is no `-L` or `-R`. The alias is configuration, not a committed address. If the forwarder returns a result, the local process does not write the ledger.

The directory lives under the application-support `Pharos/light-relay` directory, or `PHAROS_LIGHT_RELAY` when that is set. Files are owner-readable only. Nothing in the committed tree names a person, a machine, a home directory, or a private address.

## Why Swift, not a call to achat

achat is the reference for route policy: per-app order, DSH's on-demand loopback server, Codex's writer lock, and the refusal to auto-answer approvals. It is not the implementation.

- Pharos is a SwiftPM app. Shelling out to Node would add a second runtime and a second place for the hop, TTL, and mention rules. The deletion test would fail: those rules would reappear in every caller as a process invocation.
- achat's write paths were not verified live. Wrapping the CLI would not certify them.
- The behavior this RFC has to get right (directory, reply-ids, mentions, hops, queue) is in-process and is tested through `LightRelay`.
- `ExternalLightDriver` can later grow a certified executor, or a thin achat adapter, without an edit to the relay. That option stays closed until a Mac trial says the executor is real.

What was ported is the policy table and the headless argv shapes. What was not ported is the TypeScript CDP/IPC/web clients.

## Coexistence with RFC-003

| | RFC-003 full tier | RFC-005 lightweight tier |
| --- | --- | --- |
| Who it is for | Runtimes Pharos supervises or that register themselves | Sessions Pharos drives from outside |
| Identity | Runtime member id, lease generation | Stable directory name |
| Wake | Host Runtime RPC, native driver | Driver route, else the reply header |
| Busy | Delivery queue on the runtime | Single-writer outbox on the relay |
| Fallback the user sees | Not tmux | tmux only as a labelled last route |
| Approval | Scoped `approval/resolve` on a lease | Not performed |

`pharos mesh …` is unchanged. `pharos member`, `thread`, `send`, `reply`, `wait`, and `read` are this tier.

## Testing

Tests cross `LightRelay`, `LightCommands`, and `LightRoutePlanner`. They do not read private ledger fields.

Covered: directory resolution and conflicts, reply-id issue / lookup / expiry / `--once` / forged ids, `@` selection including `@all` and emails, hop limiting and opener notice, queue order, queue expiry, wait-once ingestion, SSH-shaped forwarding, loopback webhook intake, reload of the append-only log, headless argv with no approval bypass, and unverified external delivery.

Not certified, and not run by CI:

- A real Codex, Claude, DSH, or Antigravity turn on a Mac.
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
