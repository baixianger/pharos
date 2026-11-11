#!/usr/bin/env bash
# Real Codex 0.167 end-to-end: pharos-web (real durable services) + agent-runtime
# (pharos-meshd) + a REAL Codex turn, then final_answer -> replyOnce write-back ->
# HTTP read -> web restart persistence.
#
# GATED: without PHAROS_E2E_CODEX=1 this script only prints SKIP and exits 0.
# A real run burns ONE real Codex model turn (user quota) per invocation.
#
#   PHAROS_E2E_CODEX=1 scripts/e2e/codex_e2e.sh
#
# Optional env:
#   PHAROS_E2E_SANDBOX=<dir>       scratch root (default /workspace/pharos-rust/2026-11-11_dsh-wave2/e2e-sandbox)
#   PHAROS_E2E_REPLY_TIMEOUT=180   seconds to wait for the correlated Thread reply
#   PHAROS_E2E_PENDING_AFTER=60    seconds of replyState=pending before capturing the
#                                  daemon-proxy raw reproduction and stopping (no 10min wait)
#   PHAROS_E2E_BUILD=1             force `cargo build` even when binaries exist
#
# Exit codes: 0 PASS, 2 strict no-final-answer (honest real finding), 3 blocked /
# terminal-non-posted reply state, 1 setup failure. Every run keeps its logs,
# raw JSON and result.json under <sandbox>/codex-<UTC stamp>/.
set -uo pipefail

if [ "${PHAROS_E2E_CODEX:-}" != "1" ]; then
  echo "SKIP: real Codex E2E is gated (set PHAROS_E2E_CODEX=1 to run; it burns 1 real Codex turn)."
  exit 0
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
RUST_DIR="$REPO_ROOT/rust"
BIN_DIR="$RUST_DIR/target/debug"
SANDBOX_BASE="${PHAROS_E2E_SANDBOX:-/workspace/pharos-rust/2026-11-11_dsh-wave2/e2e-sandbox}"
REPLY_TIMEOUT="${PHAROS_E2E_REPLY_TIMEOUT:-180}"
PENDING_AFTER="${PHAROS_E2E_PENDING_AFTER:-60}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$SANDBOX_BASE/codex-$STAMP"
DATA_DIR="$RUN_DIR/data"
RUNTIME_DIR="$RUN_DIR/runtime"
SOCKET_DIR="$RUN_DIR/socket"
CODEX_WORK="$RUN_DIR/codex-work"
SOCKET="$SOCKET_DIR/agent-runtime.sock"
WEB_LOG="$RUN_DIR/pharos-web.log"
MESH_LOG="$RUN_DIR/pharos-meshd.log"
WEB_PID=""
MESH_PID=""

mkdir -p "$DATA_DIR" "$RUNTIME_DIR" "$SOCKET_DIR" "$CODEX_WORK"

say() { printf '%s\n' "$*"; }
fail() {
  say "FAIL: $*"
  exit "${2:-1}"
}

kill_tree() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  local i
  for i in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.15
  done
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  sleep 0.2
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  say ""
  say "== cleanup =="
  if [ -n "$WEB_PID" ]; then kill_tree "$WEB_PID"; WEB_PID=""; fi
  if [ -n "$MESH_PID" ]; then kill_tree "$MESH_PID"; MESH_PID=""; fi
  # Only our own sandbox processes: never a global codex/dsh/node process.
  local pids
  pids=$(pgrep -f -- "$RUN_DIR" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
    sleep 0.5
    for pid in $(pgrep -f -- "$RUN_DIR" 2>/dev/null || true); do kill -KILL "$pid" 2>/dev/null || true; done
  fi
  if pgrep -f -- "$RUN_DIR" >/dev/null 2>&1; then
    say "WARN: leftover process(es) for $RUN_DIR:"
    pgrep -af -- "$RUN_DIR" || true
  else
    say "no leftover sandbox processes (pgrep -f '$RUN_DIR')"
  fi
  say "run dir kept for evidence: $RUN_DIR"
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

say "== real Codex E2E =="
say "started (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "run dir: $RUN_DIR"
say "codex: $( { codex --version 2>/dev/null || echo '<not found>'; } | head -1)"
say "node: $(node --version 2>/dev/null || echo '<not found>')"

# ---------------------------------------------------------------- 1. binaries
need_build=0
for bin in pharos-web pharos-meshd pharos-codex-adapter; do
  [ -x "$BIN_DIR/$bin" ] || { need_build=1; say "missing binary: $BIN_DIR/$bin"; }
done
if [ "${PHAROS_E2E_BUILD:-}" = "1" ] || [ "$need_build" = "1" ]; then
  say "== building under /tmp/pharos-livee2e-cargo.lock (CARGO_BUILD_JOBS=3) =="
  if ! flock /tmp/pharos-livee2e-cargo.lock -c \
    "cd '$RUST_DIR' && CARGO_BUILD_JOBS=3 cargo build -p pharos-web -p pharos-agent-runtime -p pharos-codex-adapter" \
    >"$RUN_DIR/cargo-build.log" 2>&1; then
    tail -40 "$RUN_DIR/cargo-build.log" || true
    fail "cargo build failed (log: $RUN_DIR/cargo-build.log)"
  fi
  say "build ok"
else
  say "binaries present in $BIN_DIR (no build needed; PHAROS_E2E_BUILD=1 to force)"
fi

# ---------------------------------------------------------------- 2. free port
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
[ -n "$PORT" ] || fail "could not allocate a loopback port"
say "web port: 127.0.0.1:$PORT"

api() { echo "http://127.0.0.1:$PORT$1"; }
rpc() {
  # rpc <method> <params-json> -> prints result JSON on stdout
  node "$SCRIPT_DIR/codex_runtime_rpc.mjs" --socket "$SOCKET" --method "$1" --params "$2"
}

wait_health() {
  local deadline=$((SECONDS + 40))
  while [ $SECONDS -lt $deadline ]; do
    if curl -fsS --max-time 2 "$(api /health)" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  return 1
}

wait_socket() {
  local deadline=$((SECONDS + 40))
  while [ $SECONDS -lt $deadline ]; do
    [ -S "$SOCKET" ] && return 0
    sleep 0.1
  done
  return 1
}

start_web() {
  setsid "$BIN_DIR/pharos-web" \
    --addr "127.0.0.1:$PORT" \
    --data-dir "$DATA_DIR" \
    --session-adapter codex \
    >>"$WEB_LOG" 2>&1 &
  WEB_PID=$!
}

# ---------------------------------------------------------------- 3. start web
say "== starting pharos-web (real mode, --session-adapter codex) =="
start_web
if ! wait_health; then
  tail -30 "$WEB_LOG" 2>/dev/null || true
  fail "pharos-web did not become healthy on 127.0.0.1:$PORT"
fi
say "pharos-web pid=$WEB_PID healthy"

# ---------------------------------------------------------------- 4. start runtime
say "== starting pharos-meshd (thread-data-dir=$DATA_DIR/mesh) =="
setsid "$BIN_DIR/pharos-meshd" \
  --socket "$SOCKET" \
  --data-dir "$RUNTIME_DIR" \
  --thread-data-dir "$DATA_DIR/mesh" \
  >"$MESH_LOG" 2>&1 &
MESH_PID=$!
if ! wait_socket; then
  tail -30 "$MESH_LOG" 2>/dev/null || true
  fail "pharos-meshd did not create $SOCKET"
fi
say "pharos-meshd pid=$MESH_PID socket ready"

# ------------------------------------------------- 5. start a real Codex thread
say "== codex.thread.start (managed Codex worker) =="
START_JSON=$(rpc codex.thread.start "{\"cwd\":\"$CODEX_WORK\",\"approvalPolicy\":\"never\"}" 2>&1)
START_RC=$?
if [ $START_RC -ne 0 ]; then
  fail "codex.thread.start failed (rc=$START_RC): $START_JSON"
fi
CODEX_THREAD=$(echo "$START_JSON" | jq -r '.thread.id // empty' 2>/dev/null)
[ -n "$CODEX_THREAD" ] || fail "codex.thread.start returned no thread.id: $START_JSON"
say "codex thread: $CODEX_THREAD"

# ------------------------------------------------- 6. Thread replica + message
say "== POST /api/v1/threads + message =="
CREATE_JSON=$(curl -fsS -X POST "$(api /api/v1/threads)" \
  -H 'content-type: application/json' \
  -d "{\"threadId\":\"$CODEX_THREAD\",\"memberIds\":[\"$CODEX_THREAD\"]}" 2>&1)
if [ $? -ne 0 ]; then
  fail "POST /api/v1/threads failed: $CREATE_JSON"
fi
SEND_JSON=$(curl -fsS -X POST "$(api "/api/v1/threads/$CODEX_THREAD/messages")" \
  -H 'content-type: application/json' \
  -d "{\"text\":\"只回复 PONG\",\"targetMemberIds\":[\"$CODEX_THREAD\"]}" 2>&1)
if [ $? -ne 0 ]; then
  fail "POST thread message failed: $SEND_JSON"
fi
MESSAGE_ID=$(echo "$SEND_JSON" | jq -r '.id // empty')
[ -n "$MESSAGE_ID" ] || fail "thread message returned no id: $SEND_JSON"
say "original message: $MESSAGE_ID"

# ------------------------------------------------- 7. delivery.submit-member
IDEMPOTENCY_KEY="mesh:$MESSAGE_ID:$CODEX_THREAD"
PAYLOAD=$(jq -cn \
  --arg body "只回复 PONG" \
  --arg room "$CODEX_THREAD" \
  --arg messageID "$MESSAGE_ID" \
  --arg sender "human" \
  '{body: $body, room: $room, messageID: $messageID, sender: $sender}')
SUBMIT_PARAMS=$(jq -cn \
  --arg memberID "$CODEX_THREAD" \
  --arg idempotencyKey "$IDEMPOTENCY_KEY" \
  --arg payload "$PAYLOAD" \
  '{memberID: $memberID, idempotencyKey: $idempotencyKey, payload: $payload}')
say "== delivery.submit-member (this starts the real Codex turn) =="
SUBMIT_JSON=$(rpc delivery.submit-member "$SUBMIT_PARAMS" 2>&1)
SUBMIT_RC=$?
if [ $SUBMIT_RC -ne 0 ]; then
  fail "delivery.submit-member failed (rc=$SUBMIT_RC): $SUBMIT_JSON"
fi
DELIVERY_ID=$(echo "$SUBMIT_JSON" | jq -r '.deliveryID // .delivery.id // empty')
say "delivery: ${DELIVERY_ID:-<unknown>}"

# ------------------------------------------------- 8. wait for the correlated reply
say "== waiting for reply (<= ${REPLY_TIMEOUT}s; pending-capture at ${PENDING_AFTER}s) =="
REPLY_TIMEOUT_DEADLINE=$((SECONDS + REPLY_TIMEOUT))
PENDING_DEADLINE=$((SECONDS + PENDING_AFTER))
PENDING_CAPTURED=0
REPLY_FOUND=0
REPLY_COUNT=0
REPLY_ID=""
REPLY_TEXT=""
REPLY_STATE="none"
DELIVERY_STATE=""
PENDING_REPRO=""
ELAPSED=0

snapshot_delivery() {
  local snapshot delivery
  snapshot=$(rpc runtime.snapshot '{}' 2>/dev/null) || { echo '{}'; return; }
  delivery=$(echo "$snapshot" | jq -c --arg key "$IDEMPOTENCY_KEY" \
    '[.deliveries[] | select(.idempotencyKey == $key)] | last // {}' 2>/dev/null)
  echo "$delivery"
}

while [ $SECONDS -lt $REPLY_TIMEOUT_DEADLINE ]; do
  ELAPSED=$((SECONDS - (REPLY_TIMEOUT_DEADLINE - REPLY_TIMEOUT)))
  MSGS_JSON=$(curl -fsS --max-time 3 "$(api "/api/v1/threads/$CODEX_THREAD/messages")" 2>/dev/null || echo '[]')
  REPLY_COUNT=$(echo "$MSGS_JSON" | jq --arg t "$CODEX_THREAD" --arg m "$MESSAGE_ID" \
    '[.[] | select(.senderId == $t) | select(((.replyTo.messageId) // "") == $m)] | length' 2>/dev/null || echo 0)
  if [ "${REPLY_COUNT:-0}" -gt 0 ]; then
    REPLY_FOUND=1
    REPLY_ID=$(echo "$MSGS_JSON" | jq -r --arg t "$CODEX_THREAD" --arg m "$MESSAGE_ID" \
      '[.[] | select(.senderId == $t) | select(((.replyTo.messageId) // "") == $m)] | last | .id' 2>/dev/null)
    REPLY_TEXT=$(echo "$MSGS_JSON" | jq -r --arg t "$CODEX_THREAD" --arg m "$MESSAGE_ID" \
      '[.[] | select(.senderId == $t) | select(((.replyTo.messageId) // "") == $m)] | last | .text' 2>/dev/null)
    # The runtime writes reply_state after the store write; give it a beat.
    sleep 1
    DELIVERY_JSON=$(snapshot_delivery)
    REPLY_STATE=$(echo "$DELIVERY_JSON" | jq -r '.replyState // "none"' 2>/dev/null)
    DELIVERY_STATE=$(echo "$DELIVERY_JSON" | jq -r '.state // ""' 2>/dev/null)
    break
  fi
  DELIVERY_JSON=$(snapshot_delivery)
  REPLY_STATE=$(echo "$DELIVERY_JSON" | jq -r '.replyState // "none"' 2>/dev/null)
  DELIVERY_STATE=$(echo "$DELIVERY_JSON" | jq -r '.state // ""' 2>/dev/null)
  case "$REPLY_STATE" in
    no-final-answer|turn-failed|failed|missing-turn-id|missing-member-id|missing-correlation|answer-too-large|turn-timeout|posted)
      say "reply_state terminal: $REPLY_STATE (elapsed ${ELAPSED}s)"
      break
      ;;
  esac
  if [ "${PENDING_CAPTURED:-0}" -eq 0 ] && [ $SECONDS -ge $PENDING_DEADLINE ] && [ "$REPLY_STATE" = "pending" ]; then
    PENDING_CAPTURED=1
    say "replyState=pending after ${ELAPSED}s -> capturing daemon-proxy raw reproduction (no extra model turn)"
    PENDING_REPRO="$RUN_DIR/daemon-proxy-read.json"
    if node "$SCRIPT_DIR/codex_daemon_proxy_read.mjs" \
      --thread "$CODEX_THREAD" \
      --out "$PENDING_REPRO" >"$RUN_DIR/daemon-proxy-read.summary.json" 2>"$RUN_DIR/daemon-proxy-read.err"; then
      say "daemon-proxy repro captured: $PENDING_REPRO"
    else
      say "WARN: daemon-proxy repro failed (see $RUN_DIR/daemon-proxy-read.err)"
      PENDING_REPRO=""
    fi
    say "stopping the wait early (per task: do not wait ~10min for turn-timeout)"
    break
  fi
  sleep 2
done

say "reply found: $REPLY_FOUND  count: ${REPLY_COUNT:-0}  replyState: $REPLY_STATE  deliveryState: $DELIVERY_STATE  elapsed: ${ELAPSED}s"

# ------------------------------------------------- 9. verdict
RESULT="BLOCKED"
EXIT_CODE=3
DUPLICATE_AFTER_5S="not-checked"
RESTART_REPLY_PRESENT="not-checked"
RESTART_REPLY_ID=""
if [ "$REPLY_FOUND" = "1" ] && [ "${REPLY_COUNT:-0}" -eq 1 ] && [ -n "${REPLY_TEXT:-}" ] && [ "$REPLY_STATE" = "posted" ]; then
  RESULT="PASS"
  EXIT_CODE=0
  # No duplicate reply after a short settle window.
  sleep 5
  MSGS_AFTER=$(curl -fsS --max-time 3 "$(api "/api/v1/threads/$CODEX_THREAD/messages")" 2>/dev/null || echo '[]')
  COUNT_AFTER=$(echo "$MSGS_AFTER" | jq --arg t "$CODEX_THREAD" --arg m "$MESSAGE_ID" \
    '[.[] | select(.senderId == $t) | select(((.replyTo.messageId) // "") == $m)] | length' 2>/dev/null || echo 0)
  if [ "${COUNT_AFTER:-0}" -eq 1 ]; then DUPLICATE_AFTER_5S="no (still exactly 1)"; else
    DUPLICATE_AFTER_5S="YES (${COUNT_AFTER} replies)"
    RESULT="FAIL"
    EXIT_CODE=3
  fi
  # Restart pharos-web on the same data dir; the reply must still be there.
  say "== restarting pharos-web on the same data dir =="
  kill_tree "$WEB_PID"
  WEB_PID=""
  start_web
  if ! wait_health; then
    fail "pharos-web did not become healthy after restart"
  fi
  MSGS_RESTART=$(curl -fsS --max-time 5 "$(api "/api/v1/threads/$CODEX_THREAD/messages")" 2>/dev/null || echo '[]')
  RESTART_COUNT=$(echo "$MSGS_RESTART" | jq --arg t "$CODEX_THREAD" --arg m "$MESSAGE_ID" \
    '[.[] | select(.senderId == $t) | select(((.replyTo.messageId) // "") == $m)] | length' 2>/dev/null || echo 0)
  RESTART_REPLY_ID=$(echo "$MSGS_RESTART" | jq -r --arg t "$CODEX_THREAD" --arg m "$MESSAGE_ID" \
    '[.[] | select(.senderId == $t) | select(((.replyTo.messageId) // "") == $m)] | last | .id // empty' 2>/dev/null)
  if [ "${RESTART_COUNT:-0}" -eq 1 ] && [ "$RESTART_REPLY_ID" = "$REPLY_ID" ]; then
    RESTART_REPLY_PRESENT="yes (same reply id after restart)"
  else
    RESTART_REPLY_PRESENT="NO (count=${RESTART_COUNT:-0}, id=${RESTART_REPLY_ID:-<none>})"
    RESULT="FAIL"
    EXIT_CODE=3
  fi
elif [ "$REPLY_STATE" = "no-final-answer" ]; then
  RESULT="STRICT_NO_FINAL_ANSWER"
  EXIT_CODE=2
fi

# ------------------------------------------------- 10. record result
jq -n \
  --arg result "$RESULT" \
  --argjson exitCode "$EXIT_CODE" \
  --arg stamp "$STAMP" \
  --arg runDir "$RUN_DIR" \
  --arg codexThread "$CODEX_THREAD" \
  --arg messageId "$MESSAGE_ID" \
  --arg deliveryId "${DELIVERY_ID:-}" \
  --arg replyState "$REPLY_STATE" \
  --arg deliveryState "$DELIVERY_STATE" \
  --arg replyId "${REPLY_ID:-}" \
  --arg replyText "${REPLY_TEXT:-}" \
  --argjson replyCount "${REPLY_COUNT:-0}" \
  --argjson elapsedSeconds "${ELAPSED:-0}" \
  --arg duplicateAfter5s "$DUPLICATE_AFTER_5S" \
  --arg restartReply "$RESTART_REPLY_PRESENT" \
  --arg restartReplyId "${RESTART_REPLY_ID:-}" \
  --arg pendingRepro "$PENDING_REPRO" \
  --arg webLog "$WEB_LOG" \
  --arg meshLog "$MESH_LOG" \
  '{
    result: $result,
    exitCode: $exitCode,
    stamp: $stamp,
    runDir: $runDir,
    realCodexTurnsUsed: 1,
    threadId: $codexThread,
    originalMessageId: $messageId,
    deliveryId: $deliveryId,
    deliveryState: $deliveryState,
    replyState: $replyState,
    replyFound: ($replyCount > 0),
    replyCount: $replyCount,
    correlatedReplyId: $replyId,
    correlatedReplyText: $replyText,
    elapsedSecondsToReplyOrTerminal: $elapsedSeconds,
    duplicateAfter5s: $duplicateAfter5s,
    replyPersistedAfterWebRestart: $restartReply,
    restartedReplyId: $restartReplyId,
    daemonProxyRepro: $pendingRepro,
    webLog: $webLog,
    meshdLog: $meshLog
  }' >"$RUN_DIR/result.json"

say ""
say "RESULT: $RESULT (exit $EXIT_CODE)"
cat "$RUN_DIR/result.json"
say ""
say "evidence dir: $RUN_DIR"
exit "$EXIT_CODE"
