# Evidence — real Codex 0.167 E2E (phase="final_answer" truth + Thread reply loop)

**Stream:** `rust/live-e2e` (task A: real Codex 0.167 E2E script + evidence)  
**Worktree:** `/workspace/pharos-rust/2026-11-11_dsh-wave2/wt/live-e2e` (branch `rust/live-e2e`, base `54c6ff6`)  
**Host:** Linux `grok-bot-vm-51054904` (`x86_64`, kernel `6.12.113+`), **not** a Mac  
**Date:** 2026-11-11 (UTC; exact timestamps inline)  
**Codex CLI:** `codex-cli 0.167.0` (`/home/box/.local/bin/codex`, ChatGPT-authenticated; auth material never read or printed)  
**Codex app-server daemon (product transport backend):** managed `0.166.0` (`/home/box/.codex/packages/app-server-daemon/current/bin/codex`, already running before this work and left running)  
**Node:** `v24.22.1`  
**Rust binaries:** `rust/target/debug/{pharos-web,pharos-meshd,pharos-codex-adapter}` (pre-built; the E2E script only builds when a binary is missing, under `flock /tmp/pharos-livee2e-cargo.lock`)  
**Scratch (outside repo):** `/workspace/pharos-rust/2026-11-11_dsh-wave2/e2e-sandbox/`

Real Codex model turns are user quota. **Total real turns used by this task: 3** (probe run 1 = 1,
probe run 2 = 1, full E2E = 1). Budget was ≤ 6; no other real network service was used.

## Goal

1. On **real** codex-cli 0.167.0, determine whether the completed turn's `agentMessage` item carries
   `phase="final_answer"` — the signal the strict Rust policy (`inspect_turn_reply`) requires.
2. Run the real end-to-end: `pharos-web` (real durable services, `--session-adapter codex`) +
   `pharos-meshd` sharing one data dir → HTTP create Thread + message → `delivery.submit-member` →
   real Codex turn → final answer written back by `ThreadStoreReplySink`/`replyOnce` → `GET` thread
   messages shows exactly one correlated Codex reply → restart web, reply still present.

**Honesty rule:** the real 0.167 shape was recorded as found. The Rust strict
`phase="final_answer"` policy was **not** weakened or edited anywhere in this task.

## Result summary

| # | Check | Result |
| --- | --- | --- |
| 1 | Real 0.167 agent message exposes `phase` | **YES — `phase:"final_answer"`, text `"PONG"`** |
| 2 | Strict Rust policy reaches `Ready` on the real turn | **YES** (`inspect_turn_reply` shape included items with final_answer) |
| 3 | Full E2E: real web + runtime + real Codex turn | **PASS** (`replyState:"posted"`, 48 s) |
| 4 | Exactly ONE Codex reply, correlated to the original message | **YES** (count 1, `replyTo.messageId` = original) |
| 5 | Reply id is the stable `replyOnce` id (idempotent) | **YES** (`reply-956137f3…`) |
| 6 | No duplicate reply after +5 s | **YES** (still exactly 1) |
| 7 | Reply persists across `pharos-web` restart (same data dir) | **YES** (same reply id after restart) |
| 8 | Leftover sandbox processes | **none** (`pgrep -f <run dir>` empty) |

## Artifacts

- Probe helper: `scripts/e2e/codex_thread_read_probe.mjs` (Node, no npm deps)
- Runtime socket JSON-RPC helper: `scripts/e2e/codex_runtime_rpc.mjs`
- Daemon-proxy raw read (same transport as the product adapter): `scripts/e2e/codex_daemon_proxy_read.mjs`
- Gated E2E driver: `scripts/e2e/codex_e2e.sh` — **default prints SKIP/exit 0**; a real run requires
  `PHAROS_E2E_CODEX=1` and burns one real Codex turn.
- Raw/sanitized JSON + logs are kept under `<scratch>/codex-runs/…` and `<scratch>/codex-<stamp>/`
  (not committed); the committed files are the scripts above and this evidence.

---

## Probe — real codex-cli 0.167.0 `thread/read` phase truth

Transport: isolated `codex app-server` on **stdio** (spawned by the probe; not the shared daemon).
Prompt: `只回复 PONG`. Two runs were needed because the first instrumentation was defective:

| Run | real turns | outcome |
| --- | --- | --- |
| `probe-20261111T185654Z` | 1 | **instrumented miss**: polled `thread/read {includeTurns:true}` 123×/180 s; the same-connection `thread.turns` kept coming back `[]` so the terminal turn was never located. The live `item/completed` notification still carried `agentMessage{phase:"final_answer", text:"PONG"}`, which is why it was re-run. |
| `probe2-20261111T190342Z` | 1 | **PASS**: terminal turn found via `thread/read {includeTurns:true}` at poll 6, `status:"completed"`, `items [userMessage, agentMessage{phase:"final_answer", text:"PONG"}]`, strict verdict `Ready(final_answer)`. |

Commands (exact):

```sh
cd /workspace/pharos-rust/2026-11-11_dsh-wave2/wt/live-e2e
unset GIT_CONFIG_COUNT GIT_CONFIG_VALUE_0
node scripts/e2e/codex_thread_read_probe.mjs --no-turn            # plumbing smoke, 0 model turns
node scripts/e2e/codex_thread_read_probe.mjs --text '只回复 PONG' \
  --out-dir /workspace/pharos-rust/2026-11-11_dsh-wave2/e2e-sandbox/codex-runs/probe2-20261111T190342Z
# exit 0 = phase="final_answer" present, 2 = absent (real finding), 1 = probe error
```

Timestamps: run 1 `2026-11-11T18:56:54Z` → `18:59:54Z` (timeout); run 2 `2026-11-11T19:03:42.859Z`
→ `19:03:46.619Z` (3.76 s total, terminal turn at poll #6).

### Finding A — the strict signal exists on real 0.167

The completed turn's `agentMessage` is:

```json
{"type":"agentMessage","id":"msg_0c84…","text":"PONG","phase":"final_answer",
 "memoryCitation":null,"delivery":null,"questions":null,
 "startedAtMs":1794423826377,"completedAtMs":1794423826496}
```

`phaseValues = ["final_answer"]`, `anyAgentMessageHasPhase = true`,
`strictPolicyVerdict = Ready(final_answer)`. **No policy relaxation is needed.**

### Finding B — `thread/read {includeTurns:true}` is state-dependent (vendor quirk worth knowing)

On codex-cli 0.167.0 the legacy `includeTurns` shape is not uniformly reliable:

- **empty thread** (no items yet): rejected — `{"code":-32601,"message":"list_turns is not supported yet"}`;
- **same long-lived connection that ran the turn**: in probe run 1 the `thread.turns` array stayed
  `[]` for 180 s after the turn had actually completed (the `item/completed` notifications were
  correct). This is nondeterministic, not a property of every connection: in probe run 2 the same
  request located the completed turn at poll 6, and the product E2E reply loop (Finding C) also
  located it (`replyPolls: 2`).
- **newly connected app-server / not-loaded product thread**: works and returns the completed turn
  with items, both via `thread/read {includeTurns:true}` and via the vendor's paginated
  `thread/turns/list {itemsView:"full"}`.

The Rust reply loop polls `thread/read {includeTurns:true}`; on this real shape it worked in the
product path, but the vendor's other supported surface is `thread/turns/list`, which returned the
same turn/items/phase on every connection tested (probe + daemon-proxy reproduction below).

### Wire shapes (sanitized; ids shortened, text previews only)

`thread/read` request — the exact shape the Rust reply loop sends:

```json
{"method":"thread/read","params":{"threadId":"<thread-id>","includeTurns":true}}
```

Empty-thread rejection (0.167): `error {"code":-32601,"message":"list_turns is not supported yet"}`.

`thread/read {includeTurns:true}` response for a completed turn (top-level keys `thread`,
`readState`; turns live at `thread.turns`):

```json
{
  "thread": {
    "id": "<thread-id>",
    "status": {"type": "idle"},
    "historyMode": "paginated",
    "turns": [
      {
        "id": "<turn-id>",
        "rootTurnId": "<turn-id>",
        "status": "completed",
        "itemsView": "full",
        "items": [
          {
            "type": "userMessage",
            "id": "<item-id>",
            "clientId": null,
            "content": [{"type": "text", "text": "只回复 PONG", "text_elements": []}],
            "startedAtMs": 1794423824500,
            "completedAtMs": 1794423824500
          },
          {
            "type": "agentMessage",
            "id": "msg_0c84…",
            "text": "PONG",
            "phase": "final_answer",
            "memoryCitation": null,
            "delivery": null,
            "questions": null,
            "startedAtMs": 1794423826377,
            "completedAtMs": 1794423826496
          }
        ],
        "error": null,
        "startedAt": 1794423823,
        "completedAt": 1794423826,
        "durationMs": 3316
      }
    ]
  },
  "readState": {"firstUnread": null, "revision": "initial:<thread-id>"}
}
```

Per-turn keys: `completedAt, durationMs, error, id, items, itemsView, rootTurnId, startedAt, status`.
Per-item keys — `userMessage`: `clientId, completedAtMs, content, id, startedAtMs, type`;
`agentMessage`: `completedAtMs, delivery, id, memoryCitation, phase, questions, startedAtMs, text, type`.

`thread/turns/list` — request params used: `{"threadId":"<thread-id>","itemsView":"full","limit":20}`
(`cursor`, `sortDirection` optional). Result top-level keys `data`, `nextCursor`,
`backwardsCursor`; each `data[]` entry is the **same turn object** (including `items[]` with the
`phase`-tagged `agentMessage`):

```json
{
  "data": [
    {"id":"<turn-id>","rootTurnId":"<turn-id>","status":"completed","itemsView":"full",
     "items":[…same items as above…],"error":null,
     "startedAt":1794423823,"completedAt":1794423826,"durationMs":3316}
  ],
  "nextCursor": null,
  "backwardsCursor": "{\"requestedThreadId\":\"<thread-id>\",\"rolloutOrdinal\":1,\"includeAnchor\":true,\"scope\":{\"kind\":\"turns\"}}"
}
```

`thread/items/list {threadId, turnId, limit}` returns
`{"data":[{"turnId":"<turn-id>","item":{…},"startedAtMs":…,"completedAtMs":…}],"nextCursor":null}`;
the same `agentMessage.phase` field is present there (verified on the probe-run-1 completed turn).

---

## Finding C — full real E2E: **PASS**

Single run, one real Codex turn. `2026-11-11T19:47:44Z` → `19:48:39Z` (≈55 s wall, reply at 48 s).

Command (exact):

```sh
cd /workspace/pharos-rust/2026-11-11_dsh-wave2/wt/live-e2e
unset GIT_CONFIG_COUNT GIT_CONFIG_VALUE_0
PHAROS_E2E_CODEX=1 scripts/e2e/codex_e2e.sh
# default (PHAROS_E2E_CODEX unset)  -> "SKIP: …" exit 0, no real turn
```

Run dir (kept as evidence, not committed):
`/workspace/pharos-rust/2026-11-11_dsh-wave2/e2e-sandbox/codex-20261111T194744Z/`

What the script did (all real binaries from `rust/target/debug`, no fake services):

1. Allocated a free loopback port `127.0.0.1:52189` (never 3080 / a fixed user port); created
   `{data,runtime,socket,codex-work}` under the run dir.
2. Started `pharos-web --addr 127.0.0.1:52189 --data-dir <run>/data --session-adapter codex`
   (log: `pharos-web using real durable S1/S2 services … session_adapter="codex"`,
   `fake=false auth=false`), waited `/health`.
3. Started `pharos-meshd --socket <run>/socket/agent-runtime.sock --data-dir <run>/runtime
   --thread-data-dir <run>/data/mesh`; waited for the Unix socket.
4. `codex.thread.start {"cwd":"<run>/codex-work","approvalPolicy":"never"}` over the runtime socket
   → real vendor thread `01a1cc26-ec11-77d2-820f-c29a3eed8a88` (the runtime registered a managed
   `codex:app-server` conversation and the managed Codex worker/daemon transport started).
5. HTTP `POST /api/v1/threads {"threadId":"<thread>","memberIds":["<thread>"]}` (Thread replica in
   `<run>/data/mesh/replica.sqlite3`), then
   `POST /api/v1/threads/<thread>/messages {"text":"只回复 PONG","targetMemberIds":["<thread>"]}`
   → original message `e71bbb23-f8c0-4405-9167-89f1e58c06c8`.
6. `delivery.submit-member {memberID:<thread>, idempotencyKey:"mesh:<message>:<thread>",
   payload:{body:"只回复 PONG",room:<thread>,messageID:<message>,sender:"human"}}`
   → delivery `7bdfa8ea-cdbd-420f-8bbe-51c195fce764`; the managed worker ran the real Codex turn
   `01a1cc26-ee4d-7740-ac6e-cf8b791a2c4a`.
7. Polled HTTP messages + `runtime.snapshot`; the reply appeared at ~48 s. `runtime.snapshot`
   delivery record (from the now-stopped runtime's persisted registry):

```json
{
  "id": "7bdfa8ea-cdbd-420f-8bbe-51c195fce764",
  "conversationID": "cddc3ef8-e0a0-4068-bafe-9a66ece61a6a",
  "idempotencyKey": "mesh:e71bbb23-f8c0-4405-9167-89f1e58c06c8:01a1cc26-ec11-77d2-820f-c29a3eed8a88",
  "payload": "{\"body\":\"只回复 PONG\",\"room\":\"01a1cc26-ec11-77d2-820f-c29a3eed8a88\",\"messageID\":\"e71bbb23-f8c0-4405-9167-89f1e58c06c8\",\"sender\":\"human\"}",
  "state": "consumed",
  "createdAt": "2026-11-11T19:47:45.535563252Z",
  "updatedAt": "2026-11-11T19:48:31.688324748Z",
  "detail": "replyOnce reply-956137f35aa849c09a2187619c1d9ea60655af93c6400f360368b06e0a368aae",
  "turnId": "01a1cc26-ee4d-7740-ac6e-cf8b791a2c4a",
  "replyState": "posted",
  "targetMemberID": "01a1cc26-ec11-77d2-820f-c29a3eed8a88",
  "replyAttempts": 0,
  "replyPolls": 2
}
```

`replyPolls: 2` means the reply loop found the completed turn through `thread/read
{includeTurns:true}` at its second poll and posted through the strict `phase="final_answer"` path —
i.e. the product path did **not** hit the empty-`turns` flake seen in probe run 1.

8. Replica DB content after the run (read back read-only with Python `sqlite3`; exactly two messages
   in the room, no duplicates):

```json
[
  {"id":"e71bbb23-f8c0-4405-9167-89f1e58c06c8","room":"01a1cc26-…","author_member_id":"human",
   "text":"只回复 PONG","reply_to_message_id":null,
   "target_member_ids_json":"[\"01a1cc26-ec11-77d2-820f-c29a3eed8a88\"]"},
  {"id":"reply-956137f35aa849c09a2187619c1d9ea60655af93c6400f360368b06e0a368aae",
   "room":"01a1cc26-…","author_member_id":"01a1cc26-ec11-77d2-820f-c29a3eed8a88",
   "author_nick":"01a1cc26-…","text":"PONG",
   "reply_to_message_id":"e71bbb23-f8c0-4405-9167-89f1e58c06c8","target_member_ids_json":"[]"}
]
```

Memberships in the room: `human` + the Codex thread member (the runtime sink joined the Codex
member implicitly on first reply, as designed).

9. Duplicate check: after +5 s the same HTTP query still returned exactly **1** correlated reply.
10. Persistence across restart: killed the web process group, started `pharos-web` again on the same
    `--data-dir` (log at `2026-11-11T19:48:39Z`), `GET` messages still returned exactly the same
    reply id `reply-956137f3…` → the reply is durable in `mesh/replica.sqlite3`, not in memory.
11. Cleanup: both process groups stopped; `pgrep -f '<run dir>'` empty. The shared codex app-server
    **daemon** (managed 0.166.0 backend, used through the product's `codex app-server proxy`
    transport) is a global user service and was deliberately **not** killed.

`result.json` (verbatim key fields):

```json
{"result":"PASS","exitCode":0,"realCodexTurnsUsed":1,
 "threadId":"01a1cc26-ec11-77d2-820f-c29a3eed8a88",
 "originalMessageId":"e71bbb23-f8c0-4405-9167-89f1e58c06c8",
 "deliveryId":"7bdfa8ea-cdbd-420f-8bbe-51c195fce764",
 "deliveryState":"consumed","replyState":"posted","replyFound":true,"replyCount":1,
 "correlatedReplyId":"reply-956137f35aa849c09a2187619c1d9ea60655af93c6400f360368b06e0a368aae",
 "correlatedReplyText":"PONG","elapsedSecondsToReplyOrTerminal":48,
 "duplicateAfter5s":"no (still exactly 1)",
 "replyPersistedAfterWebRestart":"yes (same reply id after restart)"}
```

### Finding C.1 — same shape through the product daemon-proxy transport

After the run, `scripts/e2e/codex_daemon_proxy_read.mjs` spoke raw JSON-RPC over `codex app-server
daemon start` + `codex app-server proxy` (the transport `pharos-codex-adapter` uses) against the E2E
thread. **0 extra model turns** (read-only). Both surfaces returned the completed turn with the
phase:

```
thread/read {includeTurns:true}  -> thread.status={"type":"notLoaded"},
  turns[0].status="completed", items=[userMessage, agentMessage{phase:"final_answer", text:"PONG"}]
thread/turns/list itemsView=full -> same completed turn/items/phase
```

So on the product transport the strict signal is observable and the reply loop could (and did) post.
The daemon's managed backend reports `appServerVersion: 0.166.0` while the CLI is `0.167.0`.

---

## Reproduce

```sh
cd /workspace/pharos-rust/2026-11-11_dsh-wave2/wt/live-e2e
unset GIT_CONFIG_COUNT GIT_CONFIG_VALUE_0

# 0) gated: no quota burned
scripts/e2e/codex_e2e.sh                       # SKIP, exit 0

# 1) phase probe (burns 1 real Codex turn); exit 0 = final_answer present, 2 = absent
node scripts/e2e/codex_thread_read_probe.mjs --no-turn   # plumbing only, 0 turns
node scripts/e2e/codex_thread_read_probe.mjs --text '只回复 PONG' \
  --out-dir /workspace/pharos-rust/2026-11-11_dsh-wave2/e2e-sandbox/codex-runs/manual

# 2) full real E2E (burns 1 real Codex turn); exit 0 PASS / 2 strict no-final-answer / 3 blocked
PHAROS_E2E_CODEX=1 scripts/e2e/codex_e2e.sh

# 3) raw read through the product daemon-proxy transport (0 real turns; needs a thread id)
node scripts/e2e/codex_daemon_proxy_read.mjs --thread <thread-id> --out /tmp/daemon-proxy-read.json
```

## Not verified / limitations

- **Single** real E2E PASS (one run). The vendor's `thread/read {includeTurns:true}` empty-`turns`
  flake observed in probe run 1 means reply posting could be slower/flaky across repeated runs; the
  product path passed (`replyPolls: 2`) but this is not a statistical guarantee. A defense could be
  to read `thread/turns/list {itemsView:"full"}` as a fallback in the adapter — reported to the Lead
  as an optional fix, **not** implemented here (Rust crate edits belong to the Lead/implementer).
- The web process's own `--session-adapter codex` live `CodexSessionAdapter` (stdio app-server) was
  started and initialized but no Session API turn was driven through it; the E2E turn went through
  the agent-runtime's managed worker (the Thread-reply product path under test).
- No DSH helper-reply path, no `~/personal/pharos-msg-test` real room, no macOS/Swift/WebKit, no
  3080-port dsh Host, no `~/.gemini` — all out of scope here (DSH is a sibling task).
- The shared codex app-server **daemon** (global user service, managed backend 0.166.0) was not
  stopped by this task; sandbox `pgrep -f <run dir>` was empty after cleanup.
