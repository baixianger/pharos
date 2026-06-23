# Cross-project peer discussion — `peer` CLI + skill

**Status:** design (2026-06-22). Captured from the uni-browser × lelantos × ev3ry captcha-boundary round, where the manual `tmux send-keys` + `capture-pane` dance motivated a cleaner primitive.

**Fit with Pharos:** Pharos already launches/parallelizes/tracks coding agents across repos. This is the **inter-agent communication layer** — how agents in different repos *talk* to each other to align a contract/boundary. It **replaces session-bridge**.

---

## Goals

1. **Model each discussion message as a blocking ask/answer "tool call"** — issue a question, the call hangs until the peer replies, the reply *is* the result.
2. **Peer chatter must NOT pollute the human's message window.** The human sees the request and the converged result — never the dozens of intermediate round-trips.

## Decision: CLI + skill (chosen over MCP, and over session-bridge)

Two pieces:
- **`peer` CLI** = the transport (how a message is sent + the reply awaited).
- **`cross-project-peer` skill** = the discipline (when to use it, the coordinator pattern, the charter, conventions).

### Why CLI beats MCP here
- **Blocking-return works for free via Bash.** The forbidden thing is a foreground `sleep`, not a *command that takes time*. A `peer` process polling tmux until the reply lands is just "a command that runs 12s" — allowed. So `Bash("peer ask <session> '<q>'")` literally hangs and returns the reply as stdout = the exact ask/answer-as-tool-call semantics, **no MCP server needed**. (Only constraint: the agent's Bash timeout — default 120s, max 600s — so the CLI's internal timeout sits below it; longer peer work returns a temp-file handle instead.)
- **More composable.** A CLI is just a shell command, so *any* session can use it — the coordinator **and the peer repos themselves** — forming a true peer-to-peer mesh. MCP would need every session separately wired.
- **Cleaner separation of concerns.** CLI = tool, skill = discipline. MCP gives only the tool; you'd still need a skill/prompt for the discipline anyway.
- **Lighter / debuggable.** One no-dep script; no MCP protocol, registration, or restart. Testable straight from a terminal.

### Why it doesn't pollute the human window
Each `peer ask` (a Bash call) lands in **whatever context invoked it**. So:
- The **main/human session must NOT call `peer ask` directly** (that would dump every round-trip into the human window).
- Instead the main session spawns **one coordinator agent**; the coordinator runs all `peer ask` calls **in its own context** and returns only a compact converged summary. This is the agent/fork property: *a background agent keeps its tool output out of the parent's context.*

```
human ── one-line delegate ──► main session
                                 └─ spawn coordinator agent (background, context-isolated)
                                       ├─ peer ask uni-browser …  ┐
                                       ├─ peer ask ev3ry …         │ all round-trips stay
                                       └─ peer ask uni-browser …  ┘ in the coordinator's context
                                       └─ writes contract file + returns a short summary
                                 ◄── only the summary
human ◄── "aligned; contract at X; conclusion Y"
```

---

## `peer` CLI (sketch)

```
peer spawn <project> <repo_path>   # tmux: claude --dangerously-skip-permissions in <repo_path>,
                                   #   inject the convention "end every reply with a line: <<<DONE>>>"
                                   #   → prints the session name
peer ask <session> <msg | @file>   # 1. record current pane position
                                   # 2. send-keys the message (LARGE content → write /tmp/peer/ask-<id>.md,
                                   #    send only "Read /tmp/peer/ask-<id>.md and answer, end with <<<DONE>>>")
                                   # 3. poll capture-pane until <<<DONE>>> appears past the marker (or --timeout)
                                   # 4. extract the text between the message and <<<DONE>>> → stdout
                                   #    (huge reply → peer writes /tmp/peer/reply-<id>.md, returns "see <path>")
                                   # 5. append the full exchange to /tmp/peer/log/<session>.md (audit)
peer close <session>               # tmux kill-session
peer ls                            # list live peers
```

**Design invariants**
- **Completion via the `<<<DONE>>>` sentinel**, never a TUI-idle heuristic (idle detection is fragile; the sentinel is 100% reliable).
- **`--timeout` on every ask** — a wedged peer never hangs the tool forever.
- **Large content goes through `/tmp` paths in both directions** — keeps the tmux input safe *and* keeps the caller's context lean (it gets a path, not a wall of text).
- **Every exchange logged to disk** — full transcript auditable without ever filling a live window.

## `cross-project-peer` skill (sketch)

Triggers on cross-project alignment / boundary / contract work. Teaches:
1. Main session spawns **one coordinator agent**; the discussion lives entirely in it.
2. Coordinator uses `peer spawn/ask/close`.
3. Follow the cross-project charter: verify-before-asserting (cite real `file:line`), guard your boundary (offer a neutral primitive, not a consumer hook), ask source-anchored questions.
4. **Converge → write an in-repo contract doc** (chat is ephemeral; the doc is the source of truth). Return only a summary to the main session.
5. **Stop when converged** — don't chatter on.

The 9-clause charter + the sentinel/temp-file conventions live in the skill body.

---

## Build checklist
- [ ] `peer` CLI (no-dep single file → `~/.local/bin/peer`): `spawn` / `ask` / `close` / `ls`, sentinel, temp-file paths, `--timeout`, transcript log.
- [ ] `cross-project-peer` skill: discipline + coordinator pattern + charter.
- [ ] Regression: re-run the captcha-boundary round through it — the human window should see only one converged summary, zero round-trips.
- [ ] (Pharos) surface live peers + their transcripts in the UI; one-click `spawn`/`close`.
