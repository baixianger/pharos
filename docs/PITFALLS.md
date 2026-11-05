# Pitfalls: limits of the agent CLIs Pharos drives

Things Pharos cannot do (or can only work around) because of a defect or missing feature in the underlying CLI.
Each entry: CLI + version, symptom, repro, impact on Pharos, workaround (if any), upstream status.

---

### Codex: In-session model switch unsupported
- **CLI + version**: `codex-cli 0.166.0`
- **Symptom**: Codex interactive CLI lacks a runtime command or escape sequence to switch the active model mid-conversation without exiting.
- **Repro**: Launch `codex` interactively in a terminal/tmux session. There is no CLI shortcut, slash command, or socket API to switch models on the active session without quitting.
- **Impact on Pharos**: `pharos member model <name> <model>` cannot hot-swap the model in-place inside the running pane.
- **Workaround**: `CLIAgentLifecycle.switchModel` implements graceful restart fallback: verifies agent is not busy (or `--force` passed), sends `/quit` to pane, awaits process termination, and revives the session via `codex resume <sessionID> -m <new-model>` in the same tmux session.
- **Upstream status**: Feature request pending upstream.

---

### Codex: Rollout creation deferred until first prompt (standalone TUI)
- **CLI + version**: `codex-cli 0.166.0`
- **Symptom**: When Codex is launched in TUI mode without an active shared daemon, session metadata and rollout history are only flushed to disk upon submission of the first prompt turn.
- **Repro**: Launch `codex` directly without passing an initial prompt. The thread writer lock and rollout directory remain unpopulated until input is submitted.
- **Impact on Pharos**: Member launch cannot discover the new `sessionID` immediately after process spawn.
- **Workaround**: `CLIAgentLifecycle.launch` waits for rollout discovery; if no rollout appears within a grace window, it automatically sends an opening handshake message (`"Pharos registered this session as member <name>. Reply with exactly: ready"`) to trigger rollout creation, then resolves the `sessionID`.
- **Upstream status**: By design in standalone mode.

---

### Codex: WebSocket-over-UDS framing requirement (raw JSONL fails)
- **CLI + version**: `codex-cli 0.166.0`
- **Symptom**: Writing raw JSONL RPC lines to `~/.codex/app-server-control/app-server-control.sock` results in silent EOF / connection termination without a response. `codex app-server proxy` also fails to bridge plain JSONL because it is a raw byte stream proxy that does not perform HTTP Upgrade or WebSocket framing.
- **Repro**: Send `{"id":1,"method":"initialize",...}\n` over UDS. Connection drops immediately.
- **Impact on Pharos**: Native adapters must implement HTTP/1.1 Upgrade and RFC 6455 masked client framing to communicate with the shared daemon.
- **Workaround**: Use `WebSocketUDS` in Swift (or `tokio-tungstenite` in Rust) to perform the HTTP/1.1 `Upgrade: websocket` handshake before sending masked JSON-RPC text frames.
- **Upstream status**: Protocol requirement by design.

---

### Codex: Multi-client subscription isolation on `thread/start`
- **CLI + version**: `codex-cli 0.166.0`
- **Symptom**: A secondary client connected to the shared daemon receives the global `thread/started` broadcast, but receives zero turn events (`turn/started`, `item/*`, streaming deltas) for turns initiated by other clients.
- **Repro**: Connect Client A and Client B to the same app-server socket. Client A creates a thread via `thread/start` and starts a turn. Client B receives `thread/started` but no `item/agentMessage/delta`.
- **Impact on Pharos**: Multi-client UI and headless daemon workers cannot observe turns simply by listening to daemon broadcasts.
- **Workaround**: Any client wishing to receive turn streams must explicitly call `thread/resume` for that thread ID to register its connection ID into `ThreadManager`'s subscriber set.
- **Upstream status**: By design in `thread_lifecycle.rs`.

---

### Codex: Immediate `thread/resume` failure on empty threads
- **CLI + version**: `codex-cli 0.166.0`
- **Symptom**: Calling `thread/resume` immediately after `thread/start` (before the first user turn finishes persistence) fails with JSON-RPC error `-32600: no rollout found for thread id`.
- **Repro**: Client A calls `thread/start`; Client B immediately calls `thread/resume` on the returned thread ID.
- **Impact on Pharos**: Newly launched sessions cannot be attached by secondary observers until the opening turn completes.
- **Workaround**: Primary connection handles initialization and submits the opening prompt; secondary attachment is deferred until `turn/completed` confirms rollout flush.
- **Upstream status**: Thread storage live-writer requirement.

---

### Codex: First-response-wins approval race across multiple subscribers
- **CLI + version**: `codex-cli 0.166.0`
- **Symptom**: When multiple clients are subscribed to a thread, server approval requests are broadcast to all clients. When one client resolves the approval, the callback is removed (`remove_entry(id)`). A second client attempting to submit a decision receives `could not find callback`.
- **Repro**: Two UIs attached to the same thread; both display approval dialog; both submit an answer.
- **Impact on Pharos**: Competing UIs experience unexpected errors and inconsistent approval states.
- **Workaround**: Pharos maintains a single active ApprovalBroker lease per thread. Only the active lease holder renders actionable approval controls; other attached surfaces render read-only observation state.
- **Upstream status**: Protocol design in `outgoing_message.rs`.

---

### Codex: Memory-only approval state (`waitingOnApproval`)
- **CLI + version**: `codex-cli 0.166.0`
- **Symptom**: `state_5.sqlite` and rollout `.jsonl` files on disk do not record whether a thread is awaiting approval (`waitingOnApproval` or `needsHuman`). Disk inspection only reports `inProgress`.
- **Repro**: Query `thread_turns.status` in SQLite during an interactive permission prompt.
- **Impact on Pharos**: Offline or external file-based monitors cannot detect approval roadblocks.
- **Workaround**: Approval state must be tracked via live daemon subscription (`thread/status/changed` or `thread/read` activeFlags) rather than filesystem polling.
- **Upstream status**: By design; permissions are ephemeral facts in `RuntimeFacts`.

---

### Codex: Lack of monotonic notification sequences or replay
- **CLI + version**: `codex-cli 0.166.0`
- **Symptom**: App-server notifications contain `emittedAtMs` but no sequence IDs. If a connection drops, re-establishing WebSocket does not replay missed streaming deltas.
- **Repro**: Disconnect during turn streaming and reconnect.
- **Impact on Pharos**: Reconnecting clients miss partial turn tokens and events.
- **Workaround**: On reconnect, call `thread/turns/list` and `thread/items/list` to reconcile durable turn state, and deduplicate using `clientUserMessageId`.
- **Upstream status**: Stream transport design.

---

### Antigravity: No local injection channel for active TUI sessions
- **CLI + version**: `agy 1.5.1`
- **Symptom**: Antigravity interactive TUI sessions only accept input via their controlling terminal stdin. The internal language server (`/healthz`) requires ephemeral in-memory CSRF tokens that are never written to disk or environment variables, and `--remote-control` relies on cloud relay infrastructure rather than local sockets.
- **Repro**: Attempt to invoke internal LS RPC endpoints or connect via external sockets without passing terminal stdin.
- **Impact on Pharos**: Active TUI sessions cannot be attached or steered via socket RPC without using tmux keystroke injection.
- **Workaround**: Managed Pharos sessions use `agy acp` (ACP stdio protocol) as the primary control channel. Existing external TUI sessions are treated as read-only Attached sessions (monitoring `transcript.jsonl` and presence locks), falling back to tmux `send-keys` only when explicitly instructed.
- **Upstream status**: Architecture design in TUI.

---

### Antigravity: Stale presence locks after process termination
- **CLI + version**: `agy 1.5.1`
- **Symptom**: `~/.gemini/antigravity-cli/presence/<conversationId>.lock` is a zero-byte file used with advisory `flock`. When an `agy` process terminates or crashes, the lock file remains on disk. Checking file existence incorrectly reports dead sessions as online.
- **Repro**: Inspect presence directory after killing an `agy` process; `.lock` file remains.
- **Impact on Pharos**: False positives in session liveness detection.
- **Workaround**: Never use filesystem presence checks. Open the lock file with non-blocking exclusive lock (`flock(LOCK_EX | LOCK_NB)`): `BlockingIOError` confirms a live process holds the lock; successful acquisition indicates a stale file (release immediately). Do not delete the file.
- **Upstream status**: Standard advisory locking convention.

---

### Antigravity: Headless print mode auto-denies permissioned tools
- **CLI + version**: `agy 1.5.1`
- **Symptom**: When running in headless mode (`agy -p` / `--print`), tools requiring user permissions are automatically rejected with `denied_actions` unless `--dangerously-skip-permissions` is passed. Furthermore, `agy -p --input-format stream-json` treats `--input-format` as the prompt argument.
- **Repro**: Run `agy -p "write file"`; command finishes with denied tool execution.
- **Impact on Pharos**: Headless subagent automation fails silently without approval prompts.
- **Workaround**: For automated non-interactive tasks, explicitly pass `--dangerously-skip-permissions`. For interactive tasks, run via `agy acp`, where `session/request_permission` forwards approval requests to the Pharos UI. Always format CLI arguments as `--print=""` or place `-p` last, pairing `--input-format stream-json --output-format stream-json`.
- **Upstream status**: Security default for headless CLI execution.

---

### Antigravity: Transcript timestamp semantics and `RUNNING` status
- **CLI + version**: `agy 1.5.1`
- **Symptom**: In `transcript.jsonl`, `created_at` records the timestamp when a step was completed and flushed to disk, not when the turn started. Furthermore, `status: "RUNNING"` records the launch of a subagent, not an active in-progress user turn.
- **Repro**: Compare `created_at` on the final transcript line with file `mtime` during long-running tool execution.
- **Impact on Pharos**: Turn start latency and busy state calculation can be misleading if inferred solely from transcript timestamps.
- **Workaround**: Infer turn start from the appearance of `USER_INPUT`; infer completion from the final `PLANNER_RESPONSE` without pending `tool_calls`. Use ACP protocol events or TUI footer classification (`? for shortcuts` vs `esc to cancel`) for real-time busy/idle state.
- **Upstream status**: Transcript journal schema design.

---

### DeepSeek Harness: Exclusive session writer lock
- **CLI + version**: `dsh 0.2.1-rc.5`
- **Symptom**: DeepSeek Harness enforces an exclusive non-blocking advisory file lock `session.lock` on each active session. Attempting to resume or attach to an active session from a second process (via `dsh --profile headless --session-id` or `dsh --profile acp session/resume`) fails immediately with `session/writer-held` (`SessionAlreadyOwnedError`).
- **Repro**: Launch a session in `dsh web`; attempt to run `dsh --profile acp` and resume the same session ID.
- **Impact on Pharos**: Pharos cannot attach a second headless adapter process to an already active web or desktop DSH session.
- **Workaround**: Pharos uses an in-process Cordis plugin (`dsh-plugin-pharos`) running within the primary container process to drive and observe active sessions, or spawns owned sessions via `dsh --profile acp` / `dsh --profile sdk`.
- **Upstream status**: Single-writer consistency design.

---

### DeepSeek Harness: Headless JSON mode is commit-point projection
- **CLI + version**: `dsh 0.2.1-rc.5`
- **Symptom**: `dsh --profile headless --json` emits JSON events only at discrete step commit points rather than token-level streaming chunks. Strings are truncated at 8 KiB and lines at 32 KiB. Failed turns still output a `final` event (often empty), and approval events (`approval/*`) are omitted.
- **Repro**: Run a failing task in headless mode; observe that `final` event is emitted despite failure.
- **Impact on Pharos**: Headless JSON output cannot provide interactive approval flows or smooth typing streams, and success cannot be determined by checking for the existence of `final`.
- **Workaround**: Determine success/failure via process exit code (1 on failure) combined with `turn_end.reason`. For real-time streaming and approval interactivity, use `dsh-plugin-pharos` in-process events or `dsh --profile acp` / `sdk`.
- **Upstream status**: Projection filter design.

---

### DeepSeek Harness: Web API authentication token not persisted to disk
- **CLI + version**: `dsh 0.2.1-rc.5`
- **Symptom**: When `dsh web` starts, an authentication token is printed to `stdout` (`http://127.0.0.1:<port>/?token=...`) to establish a browser session cookie. This token is never persisted to `~/.dsh` or disk.
- **Repro**: Search `~/.dsh` for the web authentication token after starting `dsh web`.
- **Impact on Pharos**: External Pharos processes cannot authenticate against an independently launched user web host.
- **Workaround**: Use web API control only when Pharos manages and spawns the `dsh web` host directly (capturing stdout in memory), or rely on `dsh-plugin-pharos` which communicates over local UDS without requiring HTTP tokens.
- **Upstream status**: Security design to prevent unauthorized local API access.

---

### DeepSeek Harness: CLI help flags mutate profile configuration
- **CLI + version**: `dsh 0.2.1-rc.5`
- **Symptom**: Running `dsh <profile> --help` executes `prepareProfile`, which writes `cordis.yml` to the profile directory. In read-only filesystems or sandboxed environments, this causes an unexpected `EPERM` error.
- **Repro**: Run `dsh web --help` in a directory with read-only permissions.
- **Impact on Pharos**: Introspection and capability discovery via `--help` can trigger side effects or crash in restricted environments.
- **Workaround**: Inspect bundled `package.json` and ASAR manifests directly for CLI introspection, or ensure a writable temporary `DSH_HOME` is provided.
- **Upstream status**: Boot configuration architecture.

---

### DeepSeek Harness: Compressed session logs cannot be tailed
- **CLI + version**: `dsh 0.2.1-rc.5`
- **Symptom**: Session logs stored at `~/.dsh/storages/session_projcache/sessions/*.v4.jsonl.zstd` use concatenated multi-frame zstd compression. Standard streaming utilities (`tail -f`) cannot read plain text records in real time.
- **Repro**: Attempt to run `tail -f` on any `.v4.jsonl.zstd` session log.
- **Impact on Pharos**: Offline transcript readers cannot follow log files line-by-line without decompressing frames.
- **Workaround**: Read session list and status from the uncompressed projection cache (`*.json`), stream live events via in-process plugin or ACP, or decompress complete frames using `zstd -dc` during historical audits.
- **Upstream status**: Storage compression format design.

---

### Antigravity: Idle vs busy prompt classification
- **CLI + version**: `agy 1.5.1`
- **Symptom**: Terminal pane classification cannot rely solely on the prompt prefix `>` because `>` is also printed when echoing user inputs and multi-turn execution transcripts.
- **Repro**: Inspect tmux pane output of `agy` during tool execution vs awaiting prompt input.
- **Impact on Pharos**: Readiness checks and activity classification risk false positives during turns.
- **Workaround**: `AgyPane.classify` checks for the active footer string `? for shortcuts` (which is only rendered when the CLI is idle and listening for interactive user input) while checking for `esc to cancel` to detect active busy state.
- **Upstream status**: By design in TUI renderer.

---

### ChatGPT.app: Private stdio app-server (not attachable)
- **CLI + version**: `codex-cli 0.166.0` / ChatGPT.app `26.1029.61003` (Framework `156.0.8078.79`)
- **Symptom**: Attempting to attach to an active Codex session inside ChatGPT.app finds no listening socket or port; `lsof` shows app-server runs as a private stdio subprocess (`codex app-server --listen stdio://`) with pipes directly to ChatGPT.app.
- **Repro**: Inspect running processes and file descriptors for ChatGPT.app and child app-server processes.
- **Impact on Pharos**: Pharos cannot attach to or drive interactive ChatGPT.app desktop sessions directly.
- **Workaround**: Pharos communicates exclusively with the shared background daemon (`~/.codex/app-server-control/app-server-control.sock`), which is decoupled from ChatGPT.app.
- **Upstream status**: By design in desktop application container.

---

### Codex: `thread/list` filters empty threads without preview
- **CLI + version**: `codex-cli 0.166.0`
- **Symptom**: Immediately after calling `thread/start`, querying `thread/list` returns an empty array `data: []`, causing UI to assume thread creation failed.
- **Repro**: Call `thread/start`; immediately query `thread/list`.
- **Impact on Pharos**: Newly created sessions disappear from the session list until the user sends an opening turn.
- **Workaround**: Populate the local session inventory optimistically using the ID returned by `thread/start`; query `thread/loaded/list` for loaded in-memory threads; refresh `thread/list` only after the first message turn finishes.
- **Upstream status**: Database schema index requirement (`state_5.sqlite` index filters `preview <> ''`).

---

### Codex: `thread/shellCommand` runs unsandboxed without approvals
- **CLI + version**: `codex-cli 0.166.0`
- **Symptom**: `thread/shellCommand` executes commands with full user permissions, bypassing thread sandbox restrictions and approval policies.
- **Repro**: Call `thread/shellCommand` with a destructive or privileged command on a sandboxed thread; command runs without triggering approval requests.
- **Impact on Pharos**: If used as a general execution bridge, it violates security constraints.
- **Workaround**: Never use `thread/shellCommand` for automated agent execution or chat interaction; route all user prompts through `turn/start`.
- **Upstream status**: By design for explicit human terminal commands.

---

### Codex: `ipc.sock` is private desktop IPC, not app-server
- **CLI + version**: `codex-cli 0.166.0`
- **Symptom**: Connecting to `~/.codex/ipc/ipc.sock` and sending JSON-RPC `initialize` or `thread/list` results in connection failure or immediate hang.
- **Repro**: Send JSON-RPC payload over `~/.codex/ipc/ipc.sock`.
- **Impact on Pharos**: Mistaking `ipc.sock` for the app-server control socket causes adapter failures.
- **Workaround**: Always connect to `~/.codex/app-server-control/app-server-control.sock`. Never send traffic to `ipc.sock`.
- **Upstream status**: Private desktop IPC framing protocol.

---

### Codex: Multi-process writer lock collision on same `CODEX_HOME`
- **CLI + version**: `codex-cli 0.166.0`
- **Symptom**: Attempting to resume or run turns on an active thread from two separate app-server processes sharing the same `CODEX_HOME` fails with `already has an active writer` (`WriterLockCoordinator` conflict).
- **Repro**: Spawn two separate `codex app-server` instances; attempt to access the same thread.
- **Impact on Pharos**: Pharos must not spawn per-session app-servers.
- **Workaround**: All Pharos adapters multiplex across the single shared daemon process (`~/.codex/app-server-control/app-server-control.sock`) via `thread/resume`.
- **Upstream status**: By design for storage consistency.

---

### DeepSeek Harness: `pollIntervalMs: 0` disables proactive idle followup
- **CLI + version**: `dsh 0.2.1-rc.5` + `dsh-plugin-pharos 0.2.0`
- **Symptom**: When configured with `pollIntervalMs: 0`, `dsh-plugin-pharos` does not proactively invoke `agent.followup()`, delaying incoming thread deliveries until the user initiates the next turn.
- **Repro**: Send a thread delivery to an idle dsh member when `pollIntervalMs: 0`; member does not wake up.
- **Impact on Pharos**: Multi-agent thread collaboration hangs on idle dsh sessions.
- **Workaround**: Use the RFC-003 Agent Runtime socket delivery loop (`delivery.poll` -> `agent.followup()` -> `delivery.ack`) to proactively wake the container on incoming thread mail.
- **Upstream status**: Configuration default in web profile.

---

### DeepSeek Harness: API cookie and mux socket coupled lifecycle (socket close immediately invalidates cookie with 401)
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: The authentication cookie `dsh-auth-<authority-hash>=v2...` issued by `GET /connect` is strictly coupled to the active multiplexed WebSocket connection. As soon as the `/api/remote.mux` WebSocket closes, the Host destroys the client Peer object. All subsequent unary HTTP requests (`POST /api/*`) bearing that cookie immediately fail with HTTP 401 Unauthorized, and attempting to open a second WebSocket with the same cookie is rejected with HTTP 409 Conflict.
- **Repro**: Call `GET /connect?token=...` -> open `/api/remote.mux` -> invoke `POST /api/session/list` (200 OK) -> close WebSocket -> invoke `POST /api/session/list` again -> returns HTTP 401 Unauthorized.
- **Impact on Pharos**: Any naive reconnection or connection-pooling logic that reuses cached cookies across disconnects will permanently fail with 401.
- **Workaround**: Retain the raw startup token in volatile memory. Whenever the WebSocket closes or errors out, discard the old cookie and execute a fresh `GET /connect?token=<token>&interactions=answer` handshake to obtain a new Peer and cookie before opening a new WebSocket.
- **Upstream status**: By design in `dsh-client-connection` (peer lifecycle is tied to the primary API connection socket).

---

### DeepSeek Harness: `interactions=none` hangs approval requests indefinitely without timeout
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: When connecting via `GET /connect?interactions=none`, attempting to open the `$events` logical stream returns `gateway/interactions-forbidden`. If an agent invokes a tool requiring interactive permission (e.g., shell command in `danger-full-access` mode), the Host records `approval/asked` in session logs but never emits `approval/decided`, never completes the tool call, and hangs the turn indefinitely (observed hanging > 7 seconds with zero timeout or fail-closed abort).
- **Repro**: Connect with `interactions=none`, submit prompt that triggers an interactive approval tool, observe `session/follow` stream.
- **Impact on Pharos**: Headless or passive connections that fail to register as interactive answerers hang active turns and freeze the UI in a perpetual "busy" state.
- **Workaround**: Always connect using `interactions=answer` and open the `$events` logical stream on the mux WebSocket. The adapter must actively monitor the `$events` stream and resolve incoming `approval/request` events via `POST /api/$events/result` (or automatically reject them if no operator UI is attached).
- **Upstream status**: Web Host interactive answerer waterfall design (lacks server-side fail-closed timeout).

---

### DeepSeek Harness: Approvals use `$events` waterfall and `POST /api/$events/result` (not `approval/*` or `userQuestions/answer`)
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: There are no `/api/approval/*` RPC endpoints in the web Host (calling them returns 404). Calling `POST /api/userQuestions/answer` during an active tool approval request fails or has no effect because `userQuestions/answer` is exclusively designed for timed questionnaire prompts in projection state `state: "continued"`.
- **Repro**: Attempt to invoke `/api/approval/answer` or invoke `userQuestions/answer` while an agent is paused on a tool permission check.
- **Impact on Pharos**: Attempting to resolve approvals via `userQuestions/answer` or non-existent approval endpoints leaves approvals unanswered and hangs the turn.
- **Workaround**: Interactive approvals arrive as agent-scoped waterfalls over the `$events` mux stream (`approval/request`). The adapter resolves them by submitting `POST /api/$events/result` with body `{"clientId": "...", "eventId": "...", "outcome": {"kind": "result", "value": "allowed-once" | "rejected"}}`.
- **Upstream status**: By design (Agent-scoped Remote Event waterfall protocol).

---

### DeepSeek Harness: `session/control` is a read-only projection stream (not interrupt/model-switch)
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: `session/control` takes zero request parameters and cannot be used to interrupt turns or switch models. Sending action payloads (`{action: "interrupt"}`) to `POST /api/session/control` fails with `gateway/arguments-invalid`. Opening `session/control` as a stream returns `{type: "baseline"}` and `{type: "projection"}` live feeds.
- **Repro**: Send `{"action": "interrupt"}` to `POST /api/session/control`.
- **Impact on Pharos**: Mid-turn turn cancellation and model switching fail if routed to `session/control`.
- **Workaround**: To cancel/interrupt an in-flight turn, call unary RPC `POST /api/session/cancel` with payload `{"sessionId": "<id>"}`. To switch the active model, call `POST /api/session/selectModel` with `{"sessionId": "<id>", "provider": "<provider>", "model": "<model>"}`.
- **Upstream status**: By design (`session/control` is a live projection feed).

---

### DeepSeek Harness: `session/follow` lacks resume cursor (reconnection requires new snapshot and `session/page`)
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: The `session/follow` multiplexed stream accepts parameters `address`, `assistantStream`, `maxMessages`, and `turnWindow`, but does NOT accept any resume cursor (`cursor`, `afterSeq`, or `Last-Event-ID`). Opening a new follow stream always transmits a fresh initial `snapshot` bounded by `maxMessages` (default 50).
- **Repro**: Execute multiple conversation turns exceeding 50 messages, close the WebSocket, re-open `session/follow`. The snapshot only includes recent messages, and earlier turns between the disconnect and reconnect are omitted.
- **Impact on Pharos**: Simply appending follow stream events across reconnects can miss message turns or cause gaps in conversation history.
- **Workaround**: Maintain the highest processed durable `event.seq`. Upon reconnect, inspect the newly received `snapshot.cursor` and records. Deduplicate known `seq` items, and backfill any missing sequence range using paginated unary calls to `POST /api/session/page` with arguments `{"throughSeq": snapshot.cursor, "beforeSeq": lastProcessedSeq + 1, "maxMessages": 50}`.
- **Upstream status**: By design (RemoteJournalStream snapshot semantics).

---

### DeepSeek Harness: Duplicate `streamId` closes entire mux WebSocket (code 1008)
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: Sending an `open` frame on `/api/remote.mux` containing a `streamId` that is already active on the same WebSocket causes the Host to immediately close the entire underlying WebSocket with status code 1008 and reason `invalid Remote stream request`.
- **Repro**: Send `{"type": "open", "streamId": "s1", ...}` followed by a second `open` frame with `"streamId": "s1"`.
- **Impact on Pharos**: A bug in client stream ID generation drops all concurrent streams (including active chat sessions, approvals, and workspace monitors) across the entire application.
- **Workaround**: Generate cryptographically unique UUIDs for every logical stream; track active streams in a client registry, and ensure an explicit `cancel` or `end` frame is processed before retiring or reusing stream identifiers.
- **Upstream status**: Protocol requirement in `/api/remote.mux` framing engine.

---

### DeepSeek Harness: `printUrl: false` makes web Host unattachable with no CLI override
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: If the web profile's `cordis.patch.yml` sets `printUrl: false`, launching `dsh --profile web` will not print the `dsh web: http://127.0.0.1:<port>/?token=...` startup line to stdout. The CLI has no command-line override flag (`--print-url`), and the token is never persisted to disk.
- **Repro**: Add `printUrl: false` to profile configuration; launch `dsh --profile web --no-open`. Process starts but prints nothing to stdout.
- **Impact on Pharos**: Pharos cannot capture the authentication token or discover the bound port, rendering the web Host completely unattachable.
- **Workaround**: Pharos ensures its managed profile configuration maintains `printUrl: true` (or omits the override to retain default true). The supervisor process applies a 15-second timeout on initial launch; if no URL line appears, it kills the process with SIGKILL and reports a configuration fault.
- **Upstream status**: Configuration behavior by design.

---

### DeepSeek Harness: `--port 0` assigns OS port discoverable only in stdout URL line
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: Passing `--port 0` to `dsh --profile web` dynamically binds an ephemeral OS port. The allocated port is not written to any PID file, socket path, or environment variable.
- **Repro**: Launch `dsh --profile web --no-open --port 0 --host 127.0.0.1`; the actual bound port differs from 0.
- **Impact on Pharos**: Attempting to connect before parsing stdout or guessing the port causes connection errors.
- **Workaround**: For ephemeral instances, parse the dynamically allocated port directly from the stdout startup line regex `^dsh web: http://127.0.0.1:(\d+)/\?token=(\S+)$`. For long-running managed instances, use an explicitly allocated port discovered via port pre-check.
- **Upstream status**: Standard OS ephemeral port allocation.

---

### DeepSeek Harness: `SIGINT` exits with code 130 instead of graceful shutdown
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: Sending `SIGINT` (Ctrl-C) to a running web Host causes the Node.js runtime to terminate with exit code 130 without performing full cleanup. Sending `SIGTERM` cleanly terminates the process with exit code 0 within ~60–350 ms, closing listening sockets and releasing file locks.
- **Repro**: Execute `kill -INT <pid>` vs `kill -TERM <pid>`.
- **Impact on Pharos**: Supervisors inspecting exit codes will classify `SIGINT` as an abnormal crash and may trigger unwanted crash recovery loops.
- **Workaround**: Supervisors must always use `SIGTERM` for graceful shutdown, awaiting termination for up to 2 seconds before escalating to `SIGKILL`. Never send `C-c` keystrokes to the underlying tmux pane.
- **Upstream status**: Standard Node.js signal handling convention.

---

### DeepSeek Harness: `session/create` with existing `sessionId` silently spawns a new session
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: Invoking `POST /api/session/create` passing an already existing or non-blank `sessionId` does not return an error or resume the session; instead, it generates and returns a completely new session with a different `sessionId`.
- **Repro**: Create session `A`, send a prompt turn, then call `session/create` passing `{"sessionId": "A", ...}`. The returned session ID is `B` (where `B != A`).
- **Impact on Pharos**: Treating `session/create` as an idempotent "get-or-create" or session resume operation silently discards conversation history and creates zombie sessions.
- **Workaround**: Use `session/create` strictly when initiating brand-new sessions. To re-attach to an existing session, directly invoke `session/follow` or `session/prompt` (the Host automatically resumes existing sessions from disk).
- **Upstream status**: By design in session factory reuse policy.

---

### DeepSeek Harness: Secondary Host encounters `session/writer-held`; released only on process termination
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: Each active session is locked via an exclusive flock on `~/.dsh/storages/session_projcache/sessions/<id>.v4.session.lock`. If a second `dsh web` host attempts to send a prompt to an active session held by the first host, the request fails with error code `session/writer-held`. If the first host crashes or is killed via `SIGKILL`, the `.lock` file remains on disk, but the kernel immediately releases the advisory flock, allowing a new host to resume the session immediately.
- **Repro**: Launch Host A and prompt session `S`. Launch Host B under the same `DSH_HOME` and prompt session `S` -> fails with `session/writer-held`. Kill Host A (`kill -9`) -> Host B immediately succeeds on prompt.
- **Impact on Pharos**: Pharos cannot run multiple concurrent web hosts accessing the same session; however, crash recovery does not require manual lock file deletion.
- **Workaround**: Enforce a single Pharos-managed Host instance per machine. If the host terminates, a newly spawned host can take over sessions without deleting `.lock` files.
- **Upstream status**: Advisory kernel flock design.

---

### DeepSeek Harness: No `workspace/list` endpoint and `session/list` lacks cwd filter or pagination
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: Calling `POST /api/workspace/list` returns 404 Not Found. Calling `POST /api/session/list` with parameters like `cwd` or `workspaceId` ignores those arguments and returns the full global session array; passing `cursor` does not paginate and does not return `nextCursor`.
- **Repro**: Call `/api/workspace/list` or inspect argument descriptors in `lib/typert.host.js`.
- **Impact on Pharos**: Attempting to fetch workspace lists or paginate session queries via server-side filters fails.
- **Workaround**: To obtain registered workspaces, open the `workspace/follow` stream and consume its initial baseline frame before closing the stream. For sessions, fetch the full inventory via `POST /api/session/list` and perform client-side filtering by `cwd` and sorting by `updatedAt`.
- **Upstream status**: Protocol design (`workspace` is a live follow stream; `session/list` is a host-wide snapshot).

---

### DeepSeek Harness: Host/Origin DNS rebinding fence and authority-bound cookies
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: The web Host strictly validates the `Host` and `Origin` headers against allowed authorities (`127.0.0.1:<port>`). If requests originate with external origins or missing port numbers (`Host: 127.0.0.1` without port), the request returns HTTP 403 Forbidden. Furthermore, the authentication cookie is bound to the authority hash; accessing via `localhost:<port>` using a cookie issued for `127.0.0.1:<port>` returns HTTP 401 Unauthorized.
- **Repro**: Issue `GET /connect` against `127.0.0.1:<port>`, then make a request with `Host: localhost:<port>` carrying the issued cookie -> 401 Unauthorized.
- **Impact on Pharos**: Switching between `localhost` and `127.0.0.1`, or omitting the port in client HTTP headers, causes abrupt authentication failures.
- **Workaround**: The client URLSession must consistently address the host using the exact authority string (`127.0.0.1:<port>`) for all requests (`/connect`, unary RPC, and `/api/remote.mux`).
- **Upstream status**: Security protection against DNS rebinding and cross-origin hijacking.

---

### DeepSeek Harness: `$events` ordinary emit notifications do not replay (only pending waterfalls replay)
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: Ephemeral notifications on `$events` (such as `api-session/status`, `api-session/added`, `api-session/activity`) are fire-and-forget; if the client is disconnected when an event is emitted, it is permanently lost. However, unresolved approval requests (`approval/request` waterfalls) remain pending on the Host and ARE replayed to answering clients upon reconnection.
- **Repro**: Disconnect WebSocket, trigger session status change, reconnect `$events`; status emit is not received. Trigger approval while disconnected, reconnect; pending approval is immediately replayed.
- **Impact on Pharos**: Relying solely on emit notifications leads to stale session lists and status states after connection drops.
- **Workaround**: Upon reconnecting, always execute a full `POST /api/session/list` query to re-baseline session states. Handle approvals reactively as replayed waterfalls.
- **Upstream status**: By design (best-effort notification vs durable approval lifecycle).

---

### DeepSeek Harness: `assistant-stream` revision is attempt-scoped (not a global message sequence ID)
- **CLI + version**: `dsh 0.2.1-rc.5` (web Host)
- **Symptom**: In `session/follow` with `assistantStream: true`, the `revision` number on `start` and `chunk` frames starts at 1 and increments within a single turn attempt. If a turn involves multiple steps (e.g. after a steering message) or if the stream reconnects, `revision` resets back to 1.
- **Repro**: Observe `revision` field in `assistant-stream` frames across multi-step turns.
- **Impact on Pharos**: Using `revision` as a unique message identifier or global sorting key causes message collision and disordered transcripts.
- **Workaround**: Identify streaming chunks using `attemptId + index` for real-time bubble animation. Use durable journal events (`event.seq`) as canonical message identifiers, and treat `assistant/message` as the ground-truth final message content.
- **Upstream status**: By design in ephemeral presentation stream.
