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

### Antigravity: Idle vs busy prompt classification
- **CLI + version**: `agy 1.5.1`
- **Symptom**: Terminal pane classification cannot rely solely on the prompt prefix `>` because `>` is also printed when echoing user inputs and multi-turn execution transcripts.
- **Repro**: Inspect tmux pane output of `agy` during tool execution vs awaiting prompt input.
- **Impact on Pharos**: Readiness checks and activity classification risk false positives during turns.
- **Workaround**: `AgyPane.classify` checks for the active footer string `? for shortcuts` (which is only rendered when the CLI is idle and listening for interactive user input) while checking for `esc to cancel` to detect active busy state.
- **Upstream status**: By design in TUI renderer.
