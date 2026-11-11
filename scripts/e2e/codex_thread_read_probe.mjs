#!/usr/bin/env node
// Codex 0.167 `thread/read includeTurns=true` phase probe (no npm deps).
//
// Question this answers on a REAL, authenticated codex-cli:
//   When a real Codex turn completes, does the thread-read surface expose
//   `phase: "final_answer"` on the agent message, so the Rust strict policy
//   (`inspect_turn_reply` -> only `phase == "final_answer"` counts) can work?
//
// It spawns `codex app-server` on stdio (JSON-RPC, newline-delimited), starts a
// throwaway thread, runs ONE ultra-short real model turn ("只回复 PONG"), then
// polls for the terminal turn. Because codex-cli 0.167 exposes the same turn
// history through more than one RPC shape, the probe reads BOTH:
//   * `thread/read {includeTurns:true}` — the exact shape the Rust runtime sends
//   * `thread/turns/list {itemsView:"full"}` — the vendor's paginated canonical
//     turn/items surface
// and records which one actually carried the turn/items (plus a vendor-bug note
// when the legacy `includeTurns` shape returns an empty `turns` array).
//
// Both the raw JSON-RPC transcript and a sanitized shape (ids redacted, text
// previews only, no auth material) are written next to the sandbox run.
//
// Usage:
//   node scripts/e2e/codex_thread_read_probe.mjs [options]
//     --no-turn          Setup only: initialize + thread/start + reads.
//                        Consumes NO model turn (plumbing smoke test).
//     --text <prompt>    Prompt for the real turn (default "只回复 PONG").
//     --out-dir <dir>    Where raw/sanitized JSON land
//                        (default $PHAROS_E2E_SANDBOX or
//                        /workspace/pharos-rust/2026-11-11_dsh-wave2/e2e-sandbox).
//     --evidence <file>  Append a sanitized section to this markdown evidence file.
//     --timeout-ms <n>   Turn poll timeout (default 180000).
//
// Exit codes:
//   0  probe completed AND the terminal turn carries phase="final_answer" text
//   1  probe/setup/protocol error (no conclusion)
//   2  probe completed but the strict `phase="final_answer"` signal is ABSENT
//      (real finding: the Rust strict policy would end at "no-final-answer")
//
// The script never prints auth material; the sanitizer strips token-looking
// keys and truncates text. Only a local codex app-server (stdio) is used.

import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, appendFileSync } from "node:fs";
import { resolve, join } from "node:path";
import { createInterface } from "node:readline";

const DEFAULT_TEXT = "只回复 PONG";
const DEFAULT_TIMEOUT_MS = 180_000;
const SANDBOX = "/workspace/pharos-rust/2026-11-11_dsh-wave2/e2e-sandbox";

function parseArgs(argv) {
  const options = {
    noTurn: false,
    text: DEFAULT_TEXT,
    outDir: process.env.PHAROS_E2E_SANDBOX || SANDBOX,
    evidence: null,
    timeoutMs: DEFAULT_TIMEOUT_MS,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--no-turn") options.noTurn = true;
    else if (arg === "--text") options.text = argv[++i];
    else if (arg === "--out-dir") options.outDir = argv[++i];
    else if (arg === "--evidence") options.evidence = argv[++i];
    else if (arg === "--timeout-ms") options.timeoutMs = Number(argv[++i]);
    else if (arg === "--help" || arg === "-h") {
      console.log("see header comment for usage");
      process.exit(0);
    } else {
      console.error(`unknown argument: ${arg}`);
      process.exit(1);
    }
  }
  return options;
}

function utcStamp() {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

const SECRET_KEY = /(token|secret|authorization|password|api[_-]?key|cookie)/i;
const MAX_TEXT = 200;
const MAX_STRING = 400;

// Recursively redact ids and secret-looking keys; keep structure/status/phase.
function sanitize(value, keyHint = "", idMap = new Map(), depth = 0) {
  if (depth > 12) return "<depth-limit>";
  if (typeof value === "string") {
    if (SECRET_KEY.test(keyHint)) return "<redacted>";
    return value.length > MAX_STRING ? `${value.slice(0, MAX_STRING)}…` : value;
  }
  if (Array.isArray(value)) {
    return value.map((item) => sanitize(item, keyHint, idMap, depth + 1));
  }
  if (!value || typeof value !== "object") return value;
  const out = {};
  for (const [key, item] of Object.entries(value)) {
    if (SECRET_KEY.test(key)) {
      out[key] = "<redacted>";
      continue;
    }
    if (key === "id" || key.endsWith("Id") || key.endsWith("ID")) {
      if (typeof item === "string") {
        if (!idMap.has(item)) idMap.set(item, `<id-${idMap.size + 1}>`);
        out[key] = idMap.get(item);
      } else {
        out[key] = item;
      }
      continue;
    }
    if ((key === "text" || key === "preview") && typeof item === "string") {
      out[key] = item.length > MAX_TEXT ? `${item.slice(0, MAX_TEXT)}…` : item;
      continue;
    }
    out[key] = sanitize(item, key, idMap, depth + 1);
  }
  return out;
}

const TERMINAL = ["completed", "failed", "interrupted", "cancelled", "canceled"];
const terminalStatus = (status) => TERMINAL.includes(status);

function findTurn(threadReadResult, turnId) {
  const turns = threadReadResult?.thread?.turns ?? threadReadResult?.turns ?? [];
  return turns.find((turn) => turn?.id === turnId) ?? null;
}

function analyzeTurn(turn) {
  const items = Array.isArray(turn?.items) ? turn.items : [];
  const itemTypes = {};
  for (const item of items) {
    const type = item?.type ?? "<no-type>";
    itemTypes[type] = (itemTypes[type] ?? 0) + 1;
  }
  const agentMessages = items
    .map((item, index) => ({ item, index }))
    .filter(({ item }) => item?.type === "agentMessage")
    .map(({ item, index }) => ({
      itemIndex: index,
      id: item.id ?? null,
      hasPhase: Object.prototype.hasOwnProperty.call(item, "phase"),
      phase: item.phase ?? null,
      textLength: typeof item.text === "string" ? item.text.length : null,
      textPreview:
        typeof item.text === "string"
          ? item.text.length > MAX_TEXT
            ? `${item.text.slice(0, MAX_TEXT)}…`
            : item.text
          : null,
    }));
  const userMessages = items
    .filter((item) => item?.type === "userMessage")
    .map((item) => {
      const content = Array.isArray(item?.content) ? item.content : [];
      const first = content.find((entry) => entry?.type === "text")?.text ?? "";
      return {
        textPreview: first.length > MAX_TEXT ? `${first.slice(0, MAX_TEXT)}…` : first,
      };
    });
  const phaseValues = [
    ...new Set(
      items
        .filter((item) => item?.type === "agentMessage")
        .map((item) => (item.phase === undefined ? "<absent>" : item.phase)),
    ),
  ];
  const finalAnswer =
    items
      .filter(
        (item) =>
          item?.type === "agentMessage" &&
          item.phase === "final_answer" &&
          typeof item.text === "string" &&
          item.text.trim().length > 0,
      )
      .map((item) => item.text.trim())
      .pop() ?? null;
  return {
    status: turn?.status ?? null,
    itemsView: turn?.itemsView ?? null,
    turnKeys: Object.keys(turn ?? {}),
    itemCount: items.length,
    itemTypes,
    agentMessages,
    userMessages,
    phaseValues,
    anyAgentMessageHasPhase: agentMessages.some((message) => message.hasPhase),
    finalAnswerPresent: finalAnswer !== null,
    finalAnswerTextPreview:
      finalAnswer === null
        ? null
        : finalAnswer.length > MAX_TEXT
          ? `${finalAnswer.slice(0, MAX_TEXT)}…`
          : finalAnswer,
  };
}

// Same final-answer rule as the Rust strict policy (`inspect_turn_reply`):
// completed turn + last non-empty agentMessage tagged phase="final_answer".
function strictPolicyVerdict(turn) {
  if (!turn) return { waiting: true };
  if (["failed", "interrupted", "cancelled", "canceled"].includes(turn.status)) {
    return { failed: true };
  }
  if (turn.status !== "completed") return { waiting: true };
  const analysis = analyzeTurn(turn);
  return analysis.finalAnswerPresent
    ? { ready: true, textPreview: analysis.finalAnswerTextPreview }
    : { noFinalAnswer: true };
}

class AppServerClient {
  constructor({ cwd }) {
    this.cwd = cwd;
    this.child = null;
    this.pending = new Map();
    this.notifications = [];
    this.nextId = 0;
    this.stderrTail = [];
    this.closed = false;
  }

  start() {
    const executable = process.env.CODEX_BIN || "codex";
    // `codex app-server` defaults to --listen stdio://.
    this.child = spawn(executable, ["app-server"], {
      cwd: this.cwd,
      stdio: ["pipe", "pipe", "pipe"],
      env: process.env,
    });
    this.child.on("error", (error) =>
      this.failAll(new Error(`spawn codex app-server: ${error.message}`)),
    );
    this.child.on("exit", (code, signal) => {
      this.closed = true;
      this.failAll(new Error(`codex app-server exited (code=${code} signal=${signal})`));
    });
    this.child.stderr.setEncoding("utf8");
    createInterface({ input: this.child.stderr }).on("line", (line) => {
      this.stderrTail.push(line);
      if (this.stderrTail.length > 60) this.stderrTail.shift();
    });
    this.child.stdout.setEncoding("utf8");
    createInterface({ input: this.child.stdout }).on("line", (line) => {
      if (!line.trim()) return;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        this.stderrTail.push(`<non-json stdout> ${line.slice(0, 200)}`);
        return;
      }
      if (message.id !== undefined && message.id !== null && this.pending.has(String(message.id))) {
        const { resolvePromise, rejectPromise } = this.pending.get(String(message.id));
        this.pending.delete(String(message.id));
        if (message.error) {
          rejectPromise(new Error(`${message.error.message ?? "rpc error"} (code ${message.error.code})`));
        } else {
          resolvePromise(message.result ?? null);
        }
        return;
      }
      this.notifications.push(message);
      if (this.notifications.length > 1000) this.notifications.shift();
    });
    return this;
  }

  failAll(error) {
    for (const { rejectPromise } of this.pending.values()) rejectPromise(error);
    this.pending.clear();
  }

  request(method, params = {}, timeoutMs = 120_000) {
    if (this.closed) return Promise.reject(new Error("app-server is closed"));
    const id = `probe-${++this.nextId}`;
    const payload = JSON.stringify({ jsonrpc: "2.0", id, method, params });
    return new Promise((resolvePromise, rejectPromise) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rejectPromise(new Error(`${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(id, {
        resolvePromise: (value) => {
          clearTimeout(timer);
          resolvePromise(value);
        },
        rejectPromise: (error) => {
          clearTimeout(timer);
          rejectPromise(error);
        },
      });
      this.child.stdin.write(`${payload}\n`, (error) => {
        if (error) {
          this.pending.delete(id);
          clearTimeout(timer);
          rejectPromise(new Error(`write ${method}: ${error.message}`));
        }
      });
    });
  }

  notify(method, params = {}) {
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
  }

  async close() {
    if (!this.child || this.closed) return;
    try {
      this.child.stdin.end();
    } catch {
      /* ignore */
    }
    const child = this.child;
    await new Promise((resolvePromise) => {
      const timer = setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch {
          /* ignore */
        }
        resolvePromise();
      }, 3000);
      child.once("exit", () => {
        clearTimeout(timer);
        resolvePromise();
      });
    });
  }
}

const sleep = (ms) => new Promise((resolvePromise) => setTimeout(resolvePromise, ms));

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const startedAt = new Date();
  const stamp = utcStamp();
  const outDir = resolve(options.outDir);
  const workDir = join(outDir, "codex-work");
  mkdirSync(workDir, { recursive: true });
  mkdirSync(outDir, { recursive: true });

  const client = new AppServerClient({ cwd: workDir }).start();
  const raw = {
    probe: "codex_thread_read_phase",
    codexExecutable: process.env.CODEX_BIN || "codex",
    noTurn: options.noTurn,
    prompt: options.noTurn ? null : options.text,
    startedAt: startedAt.toISOString(),
    initialize: null,
    threadStart: null,
    turnStart: null,
    // `thread/read {includeTurns:true}` support can differ by thread state on
    // 0.167: record the fresh/empty-thread attempt separately from the
    // active/completed-thread attempts the Rust reply loop performs.
    includeTurnsSupport: {
      emptyThread: null,
      duringPolls: { accepted: 0, rejected: 0, errors: [] },
    },
    reads: [],
    turnsListReads: [],
    finalSource: null,
    finalThreadRead: null,
    finalTurnsList: null,
    notifications: [],
    stderrTail: [],
  };
  let exitCode = 1;

  async function readThread(threadId, includeTurns, timeoutMs = 20_000) {
    const params = includeTurns === null ? { threadId } : { threadId, includeTurns };
    try {
      return { ok: true, params, result: await client.request("thread/read", params, timeoutMs) };
    } catch (error) {
      return { ok: false, params, error: error.message };
    }
  }

  async function readTurnsList(threadId, timeoutMs = 20_000) {
    const params = { threadId, itemsView: "full", limit: 20 };
    try {
      return { ok: true, params, result: await client.request("thread/turns/list", params, timeoutMs) };
    } catch (error) {
      return { ok: false, params, error: error.message };
    }
  }

  try {
    raw.initialize = await client.request(
      "initialize",
      {
        clientInfo: { name: "pharos-e2e-probe", title: "Pharos E2E probe", version: "0.1.0" },
        capabilities: { experimentalApi: false },
      },
      30_000,
    );
    client.notify("initialized", {});

    raw.threadStart = await client.request(
      "thread/start",
      { cwd: workDir, approvalPolicy: "never" },
      60_000,
    );
    const threadId = raw.threadStart?.thread?.id;
    if (!threadId) throw new Error("thread/start returned no thread.id");

    // (a) The exact request shape the Rust runtime's reply loop sends, before
    // any turn exists. 0.167 may reject it on an empty thread.
    const emptyRead = await readThread(threadId, true);
    raw.includeTurnsSupport.emptyThread = {
      supported: emptyRead.ok,
      error: emptyRead.ok ? null : emptyRead.error,
      params: emptyRead.params,
      turns: emptyRead.ok
        ? (emptyRead.result?.thread?.turns ?? []).length
        : null,
    };

    if (options.noTurn) {
      const bare = await readThread(threadId, null);
      if (bare.ok) {
        raw.reads.push({ at: new Date().toISOString(), poll: 0, variant: "bare", result: bare.result });
        raw.finalThreadRead = bare.result;
        raw.finalSource = "read-bare";
      }
      const turnsList = await readTurnsList(threadId);
      if (turnsList.ok) {
        raw.turnsListReads.push({ at: new Date().toISOString(), poll: 0, result: turnsList.result });
      }
      exitCode = 0;
    } else {
      raw.turnStart = await client.request(
        "turn/start",
        { threadId, input: [{ type: "text", text: options.text }] },
        60_000,
      );
      const turnId = raw.turnStart?.turn?.id;
      if (!turnId) throw new Error("turn/start returned no turn.id");

      const deadline = Date.now() + options.timeoutMs;
      let polls = 0;
      let found = null;
      let foundSource = null;
      let lastStatus = null;
      let lastRead = null;
      let lastTurnsList = null;

      while (Date.now() < deadline) {
        polls += 1;
        // 1) Exact Rust-runtime shape.
        const read = await readThread(threadId, true);
        if (read.ok) {
          raw.includeTurnsSupport.duringPolls.accepted += 1;
          lastRead = read.result;
          const turn = findTurn(read.result, turnId);
          if (turn) {
            lastStatus = turn.status;
            if (polls <= 3 || terminalStatus(turn.status)) {
              raw.reads.push({ at: new Date().toISOString(), poll: polls, variant: "includeTurns", result: read.result });
            }
            if (terminalStatus(turn.status)) {
              found = turn;
              foundSource = "thread/read includeTurns:true";
              break;
            }
          } else if (polls <= 3) {
            raw.reads.push({ at: new Date().toISOString(), poll: polls, variant: "includeTurns", result: read.result });
          }
        } else {
          raw.includeTurnsSupport.duringPolls.rejected += 1;
          if (raw.includeTurnsSupport.duringPolls.errors.length < 5) {
            raw.includeTurnsSupport.duringPolls.errors.push(read.error);
          }
        }

        // 2) Vendor's paginated canonical turn/items surface.
        const turnsList = await readTurnsList(threadId);
        if (turnsList.ok) {
          lastTurnsList = turnsList.result;
          const turn = (turnsList.result?.data ?? []).find((item) => item?.id === turnId) ?? null;
          if (turn) {
            lastStatus = turn.status;
            if (polls <= 3 || terminalStatus(turn.status)) {
              raw.turnsListReads.push({ at: new Date().toISOString(), poll: polls, result: turnsList.result });
            }
            if (terminalStatus(turn.status)) {
              found = turn;
              foundSource = "thread/turns/list itemsView=full";
              break;
            }
          } else if (polls <= 3) {
            raw.turnsListReads.push({ at: new Date().toISOString(), poll: polls, result: turnsList.result });
          }
        }

        await sleep(polls < 5 ? 500 : 1500);
      }

      raw.polls = polls;
      raw.terminalStatus = lastStatus;
      raw.finalSource = foundSource;
      raw.finalThreadRead = lastRead;
      raw.finalTurnsList = lastTurnsList;
      if (!found) {
        throw new Error(
          `turn ${turnId} did not reach a terminal status within ${options.timeoutMs}ms (last=${lastStatus})`,
        );
      }
      raw.terminalTurn = found;
      // Explicit follow-up: can `thread/read {includeTurns:true}` (the runtime's
      // requested shape) still locate the now-terminal turn?
      const afterTerminal = await readThread(threadId, true);
      const afterTurn = afterTerminal.ok ? findTurn(afterTerminal.result, turnId) : null;
      raw.afterTerminal = {
        read: {
          ok: afterTerminal.ok,
          error: afterTerminal.ok ? null : afterTerminal.error,
          turnsInThread: afterTerminal.ok
            ? (afterTerminal.result?.thread?.turns ?? []).length
            : null,
          turnFound: afterTurn !== null,
          turnStatus: afterTurn?.status ?? null,
        },
      };
      exitCode = strictPolicyVerdict(found).ready ? 0 : 2;
    }
  } catch (error) {
    raw.error = error.message;
    exitCode = 1;
  } finally {
    raw.notifications = client.notifications;
    raw.stderrTail = client.stderrTail;
    raw.finishedAt = new Date().toISOString();
    raw.elapsedMs = Date.now() - startedAt.getTime();
    await client.close();
  }

  // Corroborating evidence from live item/completed notifications (no polling
  // guesswork): what phase did each streamed agentMessage carry?
  const notificationAgentMessages = raw.notifications
    .filter((message) => message.method === "item/completed")
    .map((message) => message.params?.item)
    .filter((item) => item?.type === "agentMessage")
    .map((item) => ({
      turnId: null,
      hasPhase: Object.prototype.hasOwnProperty.call(item, "phase"),
      phase: item.phase ?? null,
      textPreview: typeof item.text === "string" ? item.text.slice(0, MAX_TEXT) : null,
    }));

  const targetTurn = raw.terminalTurn ?? (raw.turnStart?.turn?.id
    ? findTurn(raw.finalThreadRead, raw.turnStart.turn.id) ??
      (raw.finalTurnsList?.data ?? []).find((item) => item?.id === raw.turnStart.turn.id) ??
      null
    : null);
  const analysis = raw.noTurn
    ? {
        noTurn: true,
        targetTurnId: null,
        phaseValues: [],
        anyAgentMessageHasPhase: false,
        finalAnswerPresent: false,
        finalAnswerTextPreview: null,
      }
    : analyzeTurn(targetTurn);

  const sanitized = sanitize(
    {
      probe: raw.probe,
      codexVersion: process.env.CODEX_VERSION || "codex-cli 0.167.0",
      startedAt: raw.startedAt,
      finishedAt: raw.finishedAt,
      elapsedMs: raw.elapsedMs,
      exitCode,
      noTurn: raw.noTurn,
      prompt: raw.prompt,
      initialize: {
        userAgent: raw.initialize?.userAgent ?? null,
        keys: Object.keys(raw.initialize ?? {}),
      },
      threadStart: {
        threadId: raw.threadStart?.thread?.id ?? null,
        threadStatus: raw.threadStart?.thread?.status ?? null,
        historyMode: raw.threadStart?.thread?.historyMode ?? null,
        cwd: raw.threadStart?.cwd ?? null,
        approvalPolicy: raw.threadStart?.approvalPolicy ?? null,
        responseKeys: Object.keys(raw.threadStart ?? {}),
      },
      turnStart: {
        turnId: raw.turnStart?.turn?.id ?? null,
        turnStatus: raw.turnStart?.turn?.status ?? null,
        responseKeys: Object.keys(raw.turnStart ?? {}),
      },
      // Does 0.167 accept the exact `includeTurns:true` shape the Rust runtime
      // sends? A rejection is a product-path incompatibility finding.
      includeTurnsSupport: raw.includeTurnsSupport,
      terminalStatus: raw.terminalStatus ?? null,
      terminalTurnFoundVia: raw.finalSource ?? null,
      polls: raw.polls ?? 0,
      targetTurnId: raw.turnStart?.turn?.id ?? null,
      targetTurn: targetTurn ? { id: targetTurn.id ?? null, ...analysis } : null,
      phaseFinding: {
        anyAgentMessageHasPhase: analysis.anyAgentMessageHasPhase ?? false,
        phaseValues: analysis.phaseValues ?? [],
        finalAnswerPresent: analysis.finalAnswerPresent ?? false,
        finalAnswerTextPreview: analysis.finalAnswerTextPreview ?? null,
      },
      strictPolicyVerdict: raw.noTurn
        ? "not-run (--no-turn)"
        : strictPolicyVerdict(targetTurn).ready
          ? "Ready(final_answer)"
          : strictPolicyVerdict(targetTurn).noFinalAnswer
            ? "NoFinalAnswer"
            : strictPolicyVerdict(targetTurn).failed
              ? "Failed"
              : "Waiting",
      // Does the Rust runtime's exact reply-read shape locate the terminal turn
      // AFTER completion? This is what decides whether the reply loop can post.
      afterTerminalIncludeTurnsRead: raw.afterTerminal?.read ?? null,
      notificationAgentMessages,
      threadReadShape: {
        keys: Object.keys(raw.finalThreadRead ?? {}),
        threadKeys: Object.keys(raw.finalThreadRead?.thread ?? {}),
      },
      notifications: raw.notifications.slice(-25),
      stderrTail: raw.stderrTail,
      error: raw.error ?? null,
    },
    "",
    new Map(),
  );

  const rawPath = join(outDir, `codex-thread-read-${stamp}.json`);
  const sanitizedPath = join(outDir, `codex-thread-read-${stamp}.sanitized.json`);
  writeFileSync(rawPath, `${JSON.stringify(raw, null, 2)}\n`);
  writeFileSync(sanitizedPath, `${JSON.stringify(sanitized, null, 2)}\n`);

  console.log(
    `PROBE ${exitCode === 0 ? "PASS (final_answer phase present)" : exitCode === 2 ? "PHASE-ABSENT" : "ERROR"}`,
  );
  console.log(`phaseFinding: ${JSON.stringify(sanitized.phaseFinding)}`);
  console.log(`strictPolicyVerdict: ${sanitized.strictPolicyVerdict}`);
  console.log(`includeTurnsSupport: ${JSON.stringify(sanitized.includeTurnsSupport)}`);
  console.log(`afterTerminalIncludeTurnsRead: ${JSON.stringify(sanitized.afterTerminalIncludeTurnsRead)}`);
  console.log(`terminalTurnFoundVia: ${sanitized.terminalTurnFoundVia}  status: ${sanitized.terminalStatus}  polls: ${sanitized.polls}`);
  console.log(`raw: ${rawPath}`);
  console.log(`sanitized: ${sanitizedPath}`);
  if (raw.error) console.log(`error: ${raw.error}`);

  if (options.evidence) {
    const lines = [
      "",
      `### Raw probe — real codex-cli ${startedAt.toISOString()}`,
      "",
      `- command: \`node scripts/e2e/codex_thread_read_probe.mjs${options.noTurn ? " --no-turn" : ""} --text ${JSON.stringify(options.text)} --out-dir <sandbox> --evidence internal/evidence/2026-11-11_live-e2e-codex.md\``,
      `- real model turns used by this run: **${options.noTurn ? 0 : 1}**`,
      `- exit code: **${exitCode}** (0 = \`phase="final_answer"\` present, 2 = absent, 1 = error)`,
      `- terminal turn status: \`${sanitized.terminalStatus}\` found via \`${sanitized.terminalTurnFoundVia}\` after ${sanitized.polls} poll(s)`,
      `- **phase finding: \`${JSON.stringify(sanitized.phaseFinding)}\`**`,
      `- strict Rust policy verdict over the real turn: \`${sanitized.strictPolicyVerdict}\``,
      `- \`thread/read {includeTurns:true}\` on empty thread: \`${JSON.stringify(sanitized.includeTurnsSupport?.emptyThread)}\``,
      `- \`thread/read {includeTurns:true}\` during polls: \`${JSON.stringify(sanitized.includeTurnsSupport?.duringPolls)}\``,
      `- \`thread/read {includeTurns:true}\` after terminal: \`${JSON.stringify(sanitized.afterTerminalIncludeTurnsRead)}\``,
      `- raw JSON: \`${rawPath}\``,
      "",
      "```json",
      JSON.stringify(sanitized, null, 2),
      "```",
      "",
    ];
    appendFileSync(options.evidence, `${lines.join("\n")}\n`);
  }

  process.exit(exitCode);
}

main().catch((error) => {
  console.error(`probe crashed: ${error.stack ?? error}`);
  process.exit(1);
});
