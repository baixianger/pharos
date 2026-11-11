#!/usr/bin/env bash
# Real DSH end-to-end for the Pharos Thread loop (task C).
#
# Flow: pharos-web (real Thread replica over HTTP) + Rust agent runtime
# (pharos-meshd) + a REAL, isolated DSH SDK-profile app that loads the repo
# plugin integrations/dsh-plugin-pharos:
#
#   HTTP Thread message -> delivery.submit-member -> dsh plugin poll/followup
#   -> real DSH assistant turn (opencode-go) -> plugin calls thread.reply
#   -> exactly one correlated reply in the Thread replica -> restart survives.
#
# Isolation guarantees:
#   - own DSH_HOME under e2e-sandbox (never ~/.dsh profiles/state, never the
#     user's web/headless/pharos-team/pharos-superagent profiles, never 3080)
#   - own data dir / runtime dir / socket / free loopback port
#   - only the processes started here are stopped
#
# Real model turns cost the user quota: this script performs exactly ONE real
# assistant turn (the Thread message is handled by the DSH agent once).
#
# Usage:
#   PHAROS_E2E_DSH=1 scripts/e2e/dsh_e2e.sh            # full real E2E
#   PHAROS_E2E_DSH=1 PHAROS_E2E_DSH_PROBE_ONLY=1 ...   # boot/registration only, no model turn
# Without PHAROS_E2E_DSH=1 it prints SKIP and exits 0 (safe for CI/cargo test).
set -euo pipefail
unset GIT_CONFIG_COUNT GIT_CONFIG_VALUE_0

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SANDBOX_ROOT=/workspace/pharos-rust/2026-11-11_dsh-wave2/e2e-sandbox
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
SB="$SANDBOX_ROOT/dsh-$STAMP"
DSH_PROFILE_NAME=${PHAROS_DSH_PROFILE:-pharos-e2e}
DRIVER="$REPO_ROOT/scripts/e2e/dsh_sdk_driver.mjs"

if [[ "${PHAROS_E2E_DSH:-}" != "1" ]]; then
  echo "SKIP: real DSH E2E is opt-in; set PHAROS_E2E_DSH=1 to run it (uses one real opencode-go model turn)."
  exit 0
fi

mkdir -p "$SB"/{data,runtime,socket,dsh-home,work,logs}
export DSH_HOME="$SB/dsh-home"
export PHAROS_E2E_SANDBOX="$SB"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-3}"
RUNTIME_SOCKET="$SB/socket/agent-runtime.sock"
export PHAROS_RUNTIME_SOCKET="$RUNTIME_SOCKET"

WEB_PID=""
RT_PID=""
cleanup() {
  set +e
  if [[ -n "$RT_PID" ]]; then kill "$RT_PID" 2>/dev/null; wait "$RT_PID" 2>/dev/null; fi
  if [[ -n "$WEB_PID" ]]; then kill "$WEB_PID" 2>/dev/null; wait "$WEB_PID" 2>/dev/null; fi
  # Only processes belonging to THIS sandbox (the sandbox root path is unique
  # and appears in our web/runtime argv) and our own helper/dsh profile — never
  # the user's 3080 web profile or any other process.
  pkill -f "$SB" 2>/dev/null
  pkill -f "dsh_sdk_driver.mjs" 2>/dev/null
  pkill -f -- "--profile $DSH_PROFILE_NAME" 2>/dev/null
  sleep 0.2
  pkill -KILL -f "$SB" 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

echo "== sandbox: $SB"
echo "== versions: dsh=$(dsh --version 2>/dev/null | tail -1) node=$(node --version) cargo=$(cargo --version | awk '{print $2}')"

# --- build binaries (serialized with other streams via flock) ----------------
flock /tmp/pharos-livee2e-cargo.lock -c \
  "cd '$REPO_ROOT/rust' && CARGO_BUILD_JOBS='$CARGO_BUILD_JOBS' cargo build -p pharos-web -p pharos-agent-runtime" \
  >"$SB/logs/cargo-build.log" 2>&1
echo "== cargo build: OK"

# --- isolated DSH profile from the shipped sdk template + repo plugin --------
# 1) create the custom profile from the shipped template (dump only; no app boot)
dsh --profile "$DSH_PROFILE_NAME" --from-default-profile sdk --dump-config \
  >"$SB/logs/dsh-config-initial.txt" 2>"$SB/logs/dsh-config.init.err"
# 2) install the repo plugin bundle (adds it to the profile bundle list)
dsh plugin --profile "$DSH_PROFILE_NAME" add "file:$REPO_ROOT/integrations/dsh-plugin-pharos" \
  >>"$SB/logs/plugin-add.log" 2>&1
cat >"$DSH_HOME/profiles/$DSH_PROFILE_NAME/cordis.patch.yml" <<'YAML'
# Pharos live-e2e isolated profile patch (applied after the sdk bundle layer).
# Model route: opencode-go over OPENCODE_GO_API_KEY (env only; no credentials file).
- id: agent-default-model
  name: "@deepseek-ai/dsh-agent-default-model"
  config:
    provider: opencode-go
    model: deepseek-v4.1-flash
- id: llm-pi-ai
  name: "@deepseek-ai/dsh-llm-pi-ai"
  config:
    providers:
      opencode-go:
        apiKeyEnv: OPENCODE_GO_API_KEY
YAML
# 3) compose the final profile (must carry the plugin row and the model route)
dsh --profile "$DSH_PROFILE_NAME" --dump-config \
  >"$SB/logs/dsh-config.txt" 2>"$SB/logs/dsh-config.err"
if ! grep -q 'pharos-runtime' "$SB/logs/dsh-config.txt"; then
  echo "FAIL: composed DSH profile does not include the pharos-runtime plugin row" >&2
  exit 1
fi
if ! grep -q 'opencode-go' "$SB/logs/dsh-config.txt"; then
  echo "FAIL: composed DSH profile does not include the opencode-go model route" >&2
  exit 1
fi
echo "== dsh profile ready: $DSH_HOME/profiles/$DSH_PROFILE_NAME (repo plugin loaded)"

# --- secret env from the user's opencode env file (never printed) ------------
# shellcheck disable=SC1090
source "$HOME/.secrets/opencode-personal-default.env"
export OPENCODE_GO_API_KEY="${OPENCODE_API_KEY:?OPENCODE_API_KEY missing from ~/.secrets/opencode-personal-default.env}"

# --- free loopback port ------------------------------------------------------
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)
WEB_URL="http://127.0.0.1:$PORT"
export PHAROS_WEB_URL="$WEB_URL"
if [[ "$PORT" == "3080" ]]; then
  echo "FAIL: refusing to use port 3080" >&2
  exit 1
fi
echo "== pharos-web port: $PORT (loopback)"

# --- start real services -----------------------------------------------------
( cd "$REPO_ROOT" && exec "$REPO_ROOT/rust/target/debug/pharos-web" \
  --addr "127.0.0.1:$PORT" \
  --data-dir "$SB/data" \
  --session-adapter none \
  >"$SB/logs/pharos-web.log" 2>&1 ) &
WEB_PID=$!
"$REPO_ROOT/rust/target/debug/pharos-meshd" \
  --socket "$RUNTIME_SOCKET" \
  --data-dir "$SB/runtime" \
  --thread-data-dir "$SB/data" \
  >"$SB/logs/agent-runtime.log" 2>&1 &
RT_PID=$!

for _ in $(seq 1 240); do
  if curl -fsS "$WEB_URL/health" >/dev/null 2>&1 && [[ -S "$RUNTIME_SOCKET" ]]; then
    break
  fi
  sleep 0.25
done
curl -fsS "$WEB_URL/health" >/dev/null || { echo "FAIL: pharos-web health never came up" >&2; cat "$SB/logs/pharos-web.log" >&2; exit 1; }
[[ -S "$RUNTIME_SOCKET" ]] || { echo "FAIL: agent-runtime socket missing" >&2; cat "$SB/logs/agent-runtime.log" >&2; exit 1; }
echo "== pharos-web + agent-runtime up"

# --- run the driver (the single real assistant turn happens here) ------------
set +e
node "$DRIVER" >"$SB/logs/driver.stdout" 2>"$SB/logs/driver.stderr"
DRIVER_RC=$?
set -e
cat "$SB/logs/driver.stderr"
if [[ $DRIVER_RC -ne 0 ]]; then
  echo "== DSH E2E result: FAIL (driver exit $DRIVER_RC); evidence: $SB" >&2
  exit "$DRIVER_RC"
fi
echo "== DSH E2E result: PASS (driver assertions green)"

if [[ "${PHAROS_E2E_DSH_PROBE_ONLY:-}" == "1" ]]; then
  echo "== probe-only run complete (no model turn); evidence sandbox: $SB"
  exit 0
fi

# --- restart persistence: same data dir, Thread reply must still be there ----
kill "$WEB_PID" 2>/dev/null || true
wait "$WEB_PID" 2>/dev/null || true
WEB_PID=""
( cd "$REPO_ROOT" && exec "$REPO_ROOT/rust/target/debug/pharos-web" \
  --addr "127.0.0.1:$PORT" \
  --data-dir "$SB/data" \
  --session-adapter none \
  >>"$SB/logs/pharos-web-restart.log" 2>&1 ) &
WEB_PID=$!
for _ in $(seq 1 240); do
  curl -fsS "$WEB_URL/health" >/dev/null 2>&1 && break
  sleep 0.25
done
curl -fsS "$WEB_URL/health" >/dev/null || { echo "FAIL: restarted pharos-web health never came up" >&2; exit 1; }
node - "$SANDBOX_ROOT" "$SB" <<'NODE'
const fs = require('node:fs')
const path = require('node:path')
const [, , , sandbox] = process.argv
const result = JSON.parse(fs.readFileSync(path.join(sandbox, 'dsh-e2e-result.json'), 'utf8'))
const url = process.env.PHAROS_WEB_URL
;(async () => {
  const response = await fetch(`${url}/api/v1/threads/${encodeURIComponent(result.threadId)}/messages`)
  if (!response.ok) throw new Error(`restart GET messages -> ${response.status}`)
  const messages = await response.json()
  const replies = messages.filter((message) => message.senderId === result.sessionId)
  if (replies.length !== 1) throw new Error(`after restart expected exactly one reply, got ${replies.length}`)
  if (replies[0].id !== result.replyId) throw new Error(`after restart reply id changed: ${replies[0].id} != ${result.replyId}`)
  if (replies[0].replyTo?.messageId !== result.originalMessageId) throw new Error('after restart reply correlation lost')
  console.log(`== restart persistence: PASS (reply ${result.replyId} still correlated after web restart)`)
})().catch((error) => {
  console.error(`FAIL: restart persistence: ${error.message}`)
  process.exit(1)
})
NODE

echo "== DSH E2E: PASS (one real assistant turn, one correlated Thread reply, persisted across restart)"
echo "== evidence sandbox: $SB"
echo "== artifacts: dsh-e2e-result.json dsh-session-events.jsonl logs/{driver,pharos-web,agent-runtime,dsh-stderr}.log"
