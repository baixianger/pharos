# ADR-005: Independent macOS Mesh service

- Status: Accepted and live-verified
- Date: 2026-07-24
- Owner: Pai

## Context

The distributed Mesh has two different kinds of work:

1. durable local operations such as creating rooms, sending messages, and
   updating projects in the signed SQLite replica; and
2. continuous runtime work such as serving the Iroh endpoint, pulling peer
   replicas, publishing Host presence, receiving Host commands, and waking
   local agents.

The `pharos mesh` CLI already performs the first kind directly against the
local replica. It is intentionally short lived and does not start an Iroh
endpoint.

On Linux, `pharos-mesh distributed sync-serve [--host]` performs the second
kind as a `systemd` service. On macOS, the same work currently lives in
`DistributedMeshSupport` inside the `Pharos.app` process. Closing all windows
does not stop the runtime while the application remains alive, but quitting
the application makes the Mac unavailable. A room or message first created on
another device cannot reach the Mac's local replica, and no incoming message
can wake a local agent.

Chat durability does not depend on a GUI, but cross-device availability
currently does. A personal agent Host should remain reachable independently of
whether its management UI is open.

ADR-003 assigned the macOS networking runtime to the app. This ADR supersedes
that part of ADR-003. It does not change the local-first data model, trust
group, replication rules, or partitioned Host authority.

## Requirements

### Functional

- A configured Mac serves and synchronizes its Mesh after login without
  launching `Pharos.app`.
- Quitting the app does not change the Mac's Mesh availability.
- The service receives remote messages and wakes only eligible local agents
  using the existing structured-hook rules.
- The service publishes Host presence and executes signed, generation-bound
  Host commands.
- App, CLI, hooks, and service use the same device identity, trust group,
  replica, attachment store, Host bindings, and delivery receipts.
- The app can display live route, sync, presence, and service-health state.
- Pairing and membership operations that require an online endpoint remain
  available through the app and CLI.
- Installation, update, repair, status, restart, and removal are
  script-diagnosable.

### Non-functional

- There is exactly one local owner of the device's Iroh endpoint.
- A crash must not leave the Mac permanently offline.
- An app update must not create a second device identity or trust group.
- Service downtime must not block safe local writes.
- Restart and redelivery must preserve the existing idempotency and Host
  command receipt guarantees.
- Local IPC must not create a new remote-control or arbitrary-shell boundary.
- Logs and diagnostics must not contain keys, invitation bearer secrets,
  message text, attachment contents, or private tmux details.

### Constraints

- Pharos remains a pure SwiftPM macOS application.
- The service runs as the logged-in user because it owns that user's tmux
  resources, files, and agent hooks. It is not a root daemon.
- The product remains local-first with no global Broker or data leader.
- The app is currently ad-hoc signed in development and may be moved or
  replaced during packaging.
- macOS, CLI, and hooks already share a protected mode-0600 identity file and a
  SQLite WAL replica under Application Support.

## Decision

Pharos will install a user-level `launchd` service named:

```text
me.pai.pharos.mesh-service
```

The service runs the packaged helper in distributed Host mode:

```text
pharos-mesh distributed sync-serve --host --relay production
```

It is the sole owner of the macOS Iroh endpoint and continuous Mesh runtime.
`Pharos.app`, `pharos`, and hooks are clients of the local replica and the
service; none of them starts a second network endpoint.

The service is the macOS equivalent of the existing Linux
`pharos-mesh.service`, with a user LaunchAgent replacing `systemd`.

## Component model

```text
                         trusted devices
                    direct QUIC / Iroh relay
                               |
                               v
              +----------------------------------+
              | me.pai.pharos.mesh-service       |
              |                                  |
              | one Iroh endpoint                |
              | anti-entropy loop                |
              | pairing + membership RPC         |
              | Host presence + signed commands  |
              | agent wake coordinator           |
              +----------------+-----------------+
                               |
                 local framed UDS, same UID only
                               |
           +-------------------+-------------------+
           |                   |                   |
      Pharos.app          pharos CLI             hooks
           |                   |                   |
           +-------------------+-------------------+
                               |
                 shared signed SQLite WAL replica
                 attachments / bindings / receipts
```

There are two local interfaces:

1. **SQLite/filesystem data plane.** App, CLI, hooks, and service open the same
   local replica. Existing multi-process author-chain retries and SQLite
   `BEGIN IMMEDIATE` transactions remain the concurrency mechanism.
2. **Unix-domain control plane.** The service exposes bounded runtime
   operations and ephemeral observations that do not belong in the durable
   replica.

The service does not become a data authority. A local write remains committed
when its signed event is durably inserted into the replica, even if the
service is temporarily unavailable. Synchronization resumes after restart.

### Low-latency convergence

Pharos follows the same separation used by Iroh Docs:

- signed replica events, membership epochs, and sync vectors are durable
  truth; and
- a live notification is only an invalidation hint that asks a peer to run
  its normal verified synchronization immediately.

The first implementation sends `sync.hint.v1` over the existing authenticated
Iroh RPC connection whenever the local sync vector changes. The operation has
no body. It contains no message text, target agent, presence, or proposed
Host action. The receiver authorizes the remote Endpoint ID and current
membership epoch, then immediately prioritizes a bounded pull from that exact
Endpoint. Hints for a peer already being pulled are coalesced into one
follow-up pull, so a write racing the active session is not stranded. An
unreachable unrelated peer cannot delay this fast path. Periodic one-second
pulls remain as repair after a lost hint or reconnect.

The hint path is deliberately transport-independent. If MeshKit exposes
Iroh Gossip in the future, the same content-free hint can be published on a
trust-group topic while signed range reconciliation remains the only source of
replicated state. Gossip must never become the durable chat log.

After synchronization, only the Host that owns an agent reads its local
structured hooks, process, and tmux bindings and decides whether a directed
message is eligible to nudge it. Remote presence is a short-lived display
projection, not an input to that authorization decision.

## Runtime ownership

### Single endpoint owner

The service acquires an exclusive runtime lock before binding Iroh:

```text
DistributedMesh/v1/runtime.lock
```

The lock is held for the process lifetime. Binding without the lock is a
fatal startup error with a diagnostic naming the current owner when known.

`DistributedMeshSupport` does not bind during normal configured operation. It
becomes an app-facing adapter over:

- the shared replica for durable state; and
- the local service client for live state and network-required operations.

There is no automatic GUI fallback that binds the endpoint. A fallback would
turn a slow or partially starting service into two processes claiming one
device identity. When the service is unavailable, the app shows cached data
and an explicit **Repair Mesh Service** action.

### Process lifetime

The LaunchAgent uses:

- `RunAtLoad = true`;
- `KeepAlive` for abnormal termination;
- a short launchd throttle interval to avoid a crash loop;
- `ProcessType = Background`;
- stdout/stderr redirected to a privacy-safe Pharos service log.

The service performs graceful shutdown on `SIGTERM`:

1. stop accepting new local control requests;
2. stop scheduling sync rounds;
3. finish or durably leave resumable Host command receipts;
4. close the Iroh endpoint and UDS;
5. release the runtime lock.

On restart it runs the existing Host-command recovery before advertising
healthy status.

The service is user-session scoped, not system scoped. "Always available"
means after the user logs in. Supporting Mesh before login is deliberately out
of scope because the service must not execute user tmux resources as root.

## Local control protocol

The service listens on a mode-0600 Unix-domain socket inside the mode-0700
distributed Mesh directory:

```text
DistributedMesh/v1/runtime.sock
```

Startup removes a stale socket only after acquiring `runtime.lock`. The
implementation validates the Darwin `sun_path` limit before installation.

The protocol uses the existing bounded framed request/response primitives with
a distinct local protocol version. Version one supports:

| Operation | Purpose |
|---|---|
| `health` | build ID, PID, uptime, protocol version, active group, endpoint state |
| `status` | last successful sync, per-peer direct/relay/offline state, last bounded error |
| `sync-now` | schedule a bounded anti-entropy round; never wait indefinitely |
| `locate-agent` | resolve the authoritative Host for one agent |
| `stop-agent` | execute a signed, generation-bound stop on the owning Host |
| `issue-invitation` | issue an invitation through the sole online endpoint |
| `revoke-device` | certify and apply a membership transition |
| `fetch-attachment` | fetch verified blob bytes into the shared local blob store |

Durable room, message, project, issue, unread, and attachment metadata
operations continue to use the local replica directly. They are not needlessly
serialized through the service.

The socket's parent directory and socket mode are the first boundary. The
server additionally verifies the connecting process UID using the Darwin peer
credential API. Requests have strict size limits, deadlines, enumerated
operations, schema versions, and a bounded concurrent request budget so a
slow attachment or Host request does not block health diagnostics. There is no operation for an arbitrary
executable, shell command, tmux target, filesystem path, or untrusted text to
be typed into a terminal.

Agent wake prompts remain fixed trusted strings. Message content is never
copied into a tmux command.

## Identity and storage

The service opens `MeshLocalReplica.openDefault(headless: true)`.

All macOS surfaces continue to use:

```text
~/Library/Application Support/Pharos/DistributedMesh/v1/
  headless-device-identity-v1.json
  replica-v1.sqlite
  replica-v1.sqlite-wal
  replica-v1.sqlite-shm
  runtime.lock
  runtime.sock
  ...
```

Installation must fail closed if the protected identity has not been
bootstrapped. It must never call an isolated `--data-dir` path that creates a
new identity. The installer first compares:

- local device ID;
- Endpoint ID;
- active trust-group ID; and
- membership epoch

between the current product replica and a one-shot helper status result.

SQLite WAL permits the service and short-lived clients to coexist. Local event
authoring already retries sequence/hash races against the committed author
head. Schema migrations remain one-process-at-a-time transactions. A new
service build must open all currently supported replica schemas before it
replaces the running build.

## Installation and updates

### Stable executable

The LaunchAgent must not point into `.build` or a developer checkout.

Packaging includes the signed `pharos-mesh` helper. Installation copies it
atomically to a stable user-owned runtime path:

```text
~/Library/Application Support/Pharos/Runtime/pharos-mesh
```

The copy preserves its executable mode and code signature. Before activation,
the installer verifies that it is the expected product helper and that
`distributed sync-serve` is supported.

The LaunchAgent plist lives at:

```text
~/Library/LaunchAgents/me.pai.pharos.mesh-service.plist
```

The service commands are exposed through a product CLI rather than requiring
users to call `launchctl` directly:

```text
pharos mesh service install
pharos mesh service status [--json]
pharos mesh service restart
pharos mesh service repair
pharos mesh service uninstall
```

`install`, `restart`, and `repair` are idempotent. `status` is read-only.
`uninstall` stops the service and removes its plist/runtime binary/socket but
does not delete identity, replica, attachments, bindings, receipts, or logs.
A full device reset remains a separate explicit destructive action.

### Upgrade handoff

An update follows this order:

1. copy a staged helper beside the stable runtime binary;
2. retain the prior helper;
3. boot out the old LaunchAgent;
4. atomically replace the stable helper;
5. bootstrap the LaunchAgent;
6. verify `health` reports the new build ID, online state, and the exact same
   device ID, Endpoint ID, trust-group ID, and membership epoch.

If verification fails, restore the previous helper and restart it. Replica
schema changes must obey their own forward/backward compatibility rules; binary
rollback never rewrites or deletes replica data.

## App, CLI, and hook behavior

### Pharos.app

At launch the app:

1. opens the local replica;
2. connects to the local service;
3. subscribes/polls for bounded live snapshots;
4. displays cached durable state even if the service is down.

The app reports these states separately:

- `Service running` / `Service unavailable`;
- `Endpoint online` / `Endpoint reconnecting`;
- per-peer `direct` / `relay` / `offline`;
- `Replica pending` / last successful sync time.

Quitting the app closes only its local client connection.

### CLI

Safe local writes remain available when the service is down. CLI output must
distinguish:

```text
committed locally; Mesh service unavailable, replication pending
```

from:

```text
committed locally; replication scheduled
```

Commands requiring a remote endpoint fail with a bounded, actionable service
error. Normal invite, revoke, locate, presence, and stop operations never
silently launch an in-process Iroh endpoint. Joining or leaving a trust group
uses an explicit bounded handoff: stop the LaunchAgent, acquire the same
runtime lock for one onboarding operation, close it, then bootstrap the
LaunchAgent again.

### Hooks and local agents

Hooks continue to record structured lifecycle evidence directly in private
Host-local storage. The service reads that evidence, reconciles exact tmux seat
claims, and owns remote-message wake delivery.

The service must use structured hook state as authoritative. It must not infer
idle/busy/gone from pane text, ANSI output, model suggestions, or terminal
capture.

## Failure behavior

| Failure | Required behavior |
|---|---|
| App quits | No network or presence change |
| Service crashes | launchd restarts it; local writes remain available |
| Network disappears | endpoint reports reconnecting; events remain queued locally |
| Peer is offline | bounded sync round ends; other peers continue syncing |
| Stale UDS exists | lock owner decides; never delete another live process's socket |
| Duplicate service starts | second process fails before binding Iroh |
| Service dies during Host command | durable receipt recovery resumes idempotently |
| Helper update fails | prior verified helper is restored |
| Replica is newer than helper | fail closed with upgrade-required diagnostic |
| Disk is full | preserve committed data, report degraded state, avoid restart storm |
| Identity is absent/mismatched | fail closed; never create a replacement device silently |
| User logs out | launchd stops the user service; no claim of availability before next login |

One unreachable peer must not block synchronization with healthy peers.
Per-peer requests retain bounded read/write deadlines and overlapping bounded
sync rounds remain capped.

## Observability

`pharos mesh service status --json` is the primary diagnostic contract. It
includes:

- service/build/protocol versions;
- PID, uptime, restart count when available;
- device ID and abbreviated Endpoint ID;
- active trust-group ID and membership epoch;
- endpoint `starting|online|reconnecting|failed`;
- last successful sync timestamp;
- per-peer path and last bounded error category;
- Host command recovery count;
- pending local event count when cheaply available.

Human output may include device display names but not keys, tickets, payload
text, attachment names, tmux sockets, pane IDs, cwd values, or command bodies.

Logs use stable event names and error categories. The service writes one
privacy-safe startup record and does not log every one-second healthy sync
round.

## Migration

The migration is deliberately staged.

### Stage 1: service foundation

- Extract the app's endpoint/router/sync loop into a reusable
  `DistributedMeshRuntime`.
- Keep the app as runtime owner.
- Add deterministic start/stop and status snapshots plus isolated tests.

### Stage 2: local service

- Add the local UDS server/client and runtime lock.
- Run the helper manually in `sync-serve --host` against isolated test data.
- Prove App/CLI/service multi-process WAL behavior.

### Stage 3: LaunchAgent

- Add install/status/restart/repair/uninstall commands.
- Package the stable helper and LaunchAgent.
- Verify restart after crash, logout/login, sleep/wake, and network changes.

### Stage 4: ownership cutover

- Install and verify the service while the old app runtime is stopped.
- Change the app to service-client mode.
- Remove all normal app paths that call `IrohEndpointRuntime.bind`.
- Preserve an explicit development-only in-process runtime for isolated tests,
  never enabled in a packaged product.

### Stage 5: production acceptance

- Quit Pharos and verify iPhone still reports the Mac online.
- Create a room on iPhone and join/send from a fresh Mac CLI.
- Send an iPhone message to an idle local agent and verify one wake.
- Restart/kill the service during sync and Host command execution.
- Upgrade and roll back the helper without changing device/group identity.

The old legacy Broker/Node LaunchAgents are removed only after distributed
service acceptance. Their labels must never run alongside the new service in
normal product mode.

## Verification requirements

Automated:

- runtime lock excludes a second endpoint owner;
- UDS rejects a different UID, oversized frames, unknown operations, and
  expired requests;
- service and CLI concurrently author events without corrupting the author
  chain;
- incoming replication becomes visible to an already-running app;
- service crash during accepted/executing Host commands preserves exactly-once
  behavior;
- offline peers do not starve healthy peers;
- stale socket, stale PID, corrupt plist, missing helper, and incompatible
  schema repair tests;
- installation and upgrade preserve exact device, Endpoint, group, and epoch
  identity;
- uninstall preserves all user data.

Live:

- Mac mini remains available on iPhone with every Pharos window closed;
- Mac mini remains available after `Pharos.app` quits;
- a new iPhone room reaches the Mac CLI without reopening the app;
- an incoming directed message wakes the correct idle tmux agent;
- sleep/wake and Wi-Fi changes converge through direct or relay paths;
- logout stops the service and next login restores it;
- helper crash is recovered by launchd without manual intervention.

Passing `swift test` and observing a live process are not sufficient on their
own. Production acceptance was completed on 2026-07-25: with `Pharos.app`
terminated and the exact local Codex session idle, an iPhone message in
`misc` directed to `@pharos-dev` synchronized over the independent
LaunchAgent, woke that session once, and was drained and replied to without a
listener or polling process.

## Trade-offs

### Benefits

- Chat and Host availability no longer depend on GUI lifecycle.
- macOS and Linux share one runtime model.
- One endpoint owner removes app/CLI binding races.
- App crashes and UI updates no longer interrupt agent delivery.
- Service health becomes independently diagnosable.

### Costs

- A local IPC protocol and service lifecycle become maintained product
  surfaces.
- Packaging and updates require an atomic helper handoff.
- App UI must separate durable replica state from ephemeral service state.
- Multi-process migration and schema compatibility need explicit tests.
- A login-scoped background process consumes a small continuous resource
  budget.

## Rejected alternatives

### Keep the runtime in `Pharos.app`

This preserves less code but makes Host availability and message delivery
depend on a management UI process.

### Let every CLI command run one sync round

This can reduce stale `Room not found` errors but does not receive messages
while no command is running, publish continuous presence, wake agents, or
recover Host commands.

### Let both the app and service bind the same identity

This creates ambiguous endpoint ownership, duplicate synchronization, and race
conditions during slow startup and updates.

### Run a root LaunchDaemon

The service would cross user boundaries and would not naturally own the user's
tmux sessions, files, and hook observations. Root is unnecessary and expands
the security boundary.

### Persist all live state into the replicated database

Presence and connection paths are expiring observations, not durable truth.
Replicating them would make stale Host state appear authoritative.

## Revisit as the system grows

- Use an `SMAppService`-managed agent instead of a directly managed user
  LaunchAgent if distribution/notarization policy requires it.
- Replace polling local status with a streamed subscription after the bounded
  request protocol is proven.
- Add an optional content-free push wake path for a logged-out or sleeping Mac;
  it must not become a correctness dependency.
- Replace authenticated point-to-point sync hints with Iroh Gossip when the
  Apple binding exposes it and measurements justify topic fan-out. Keep
  vector/range reconciliation as authoritative state.
- Move more local mutations behind the service only if measured SQLite
  contention or schema migration coordination requires it.
