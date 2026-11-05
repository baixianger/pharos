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
