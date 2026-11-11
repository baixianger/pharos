#!/usr/bin/env node
// Raw JSON-RPC reproduction over the SAME transport `pharos-meshd`'s Codex
// adapter uses: `codex app-server daemon start` + `codex app-server proxy`
// (WebSocket-over-stdio to the local app-server daemon).
//
// Used by scripts/e2e/codex_e2e.sh when the real reply loop stays
// `replyState:"pending"`, to capture exactly what that transport returns for
//   * thread/read {includeTurns:true}   (the Rust reply loop's request shape)
//   * thread/read {threadId}            (bare)
//   * thread/turns/list {itemsView:"full"}
// on a thread that already ran a real turn on the product path. It NEVER starts
// a model turn; it only reads (0 real Codex turns).
//
// Usage:
//   node scripts/e2e/codex_daemon_proxy_read.mjs --thread <thread-id> [--out <raw.json>]
//
// Exit codes: 0 reads captured, 1 setup/transport error.
// Output is sanitized on stdout; `--out` keeps the raw (ids intact) JSON under
// the sandbox for debugging. Never prints auth material.

import { spawn, spawnSync } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

function parseArgs(argv) {
  const options = { thread: null, out: null, timeoutMs: 60_000 };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--thread") options.thread = argv[++i];
    else if (arg === "--out") options.out = argv[++i];
    else if (arg === "--timeout-ms") options.timeoutMs = Number(argv[++i]);
    else if (arg === "--help" || arg === "-h") {
      console.log("usage: codex_daemon_proxy_read.mjs --thread <thread-id> [--out <raw.json>]");
      process.exit(0);
    } else {
      console.error(`unknown argument: ${arg}`);
      process.exit(1);
    }
  }
  if (!options.thread) {
    console.error("--thread is required");
    process.exit(1);
  }
  return options;
}

const options = parseArgs(process.argv.slice(2));
const codexBin = process.env.CODEX_BIN || "codex";

// --- 1. Ensure the local app-server daemon is running (idempotent) ----------
const daemonStart = spawnSync(codexBin, ["app-server", "daemon", "start"], {
  encoding: "utf8",
  timeout: 30_000,
});
if (daemonStart.status !== 0) {
  console.error(
    `codex app-server daemon start failed (exit ${daemonStart.status}): ${(daemonStart.stderr || "").slice(0, 500)}`,
  );
  process.exit(1);
}

// --- 2. Open the proxy stream and do the WebSocket handshake ----------------
const proxy = spawn(codexBin, ["app-server", "proxy"], {
  stdio: ["pipe", "pipe", "pipe"],
});
let stderrText = "";
proxy.stderr.setEncoding("utf8");
proxy.stderr.on("data", (chunk) => {
  stderrText += chunk;
  if (stderrText.length > 8000) stderrText = stderrText.slice(-8000);
});

const handshake = Buffer.from(
  "GET / HTTP/1.1\r\n" +
    "Host: localhost\r\n" +
    "Upgrade: websocket\r\n" +
    "Connection: Upgrade\r\n" +
    "Sec-WebSocket-Key: cGhhcm9zLWNvZGV4LTAx\r\n" +
    "Sec-WebSocket-Version: 13\r\n\r\n",
  "utf8",
);
proxy.stdin.write(handshake);

let rawBuffer = Buffer.alloc(0);
let handshakeDone = false;
let fragments = [];
const pendingRequests = new Map();
const notifications = [];
let nextId = 0;

function sendFrame(opcode, payload) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(payload, "utf8");
  const mask = Buffer.from([0x12, 0x34, 0x56, 0x78]);
  let header;
  if (data.length < 126) {
    header = Buffer.from([0x80 | opcode, 0x80 | data.length]);
  } else if (data.length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(data.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(data.length), 2);
  }
  const masked = Buffer.alloc(data.length);
  for (let i = 0; i < data.length; i += 1) masked[i] = data[i] ^ mask[i % 4];
  proxy.stdin.write(Buffer.concat([header, mask, masked]));
}

function sendJsonRpc(record) {
  sendFrame(0x1, JSON.stringify(record));
}

function request(method, params) {
  const id = `proxy-${++nextId}`;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pendingRequests.delete(id);
      reject(new Error(`${method} timed out`));
    }, 45_000);
    pendingRequests.set(id, {
      resolve: (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      reject: (error) => {
        clearTimeout(timer);
        reject(error);
      },
    });
    sendJsonRpc({ jsonrpc: "2.0", id, method, params });
  });
}

function handleMessage(message) {
  if (message.id !== undefined && pendingRequests.has(String(message.id))) {
    const { resolve, reject } = pendingRequests.get(String(message.id));
    pendingRequests.delete(String(message.id));
    if (message.error) reject(new Error(`${message.error.message} (code ${message.error.code})`));
    else resolve(message.result ?? null);
    return;
  }
  notifications.push(message);
}

function processFrames() {
  while (rawBuffer.length >= 2) {
    const first = rawBuffer[0];
    const second = rawBuffer[1];
    const fin = (first & 0x80) !== 0;
    const opcode = first & 0x0f;
    const masked = (second & 0x80) !== 0;
    let length = second & 0x7f;
    let offset = 2;
    if (length === 126) {
      if (rawBuffer.length < 4) return;
      length = rawBuffer.readUInt16BE(2);
      offset = 4;
    } else if (length === 127) {
      if (rawBuffer.length < 10) return;
      length = Number(rawBuffer.readBigUInt64BE(2));
      offset = 10;
    }
    let mask = null;
    if (masked) {
      if (rawBuffer.length < offset + 4) return;
      mask = rawBuffer.subarray(offset, offset + 4);
      offset += 4;
    }
    if (rawBuffer.length < offset + length) return;
    let payload = rawBuffer.subarray(offset, offset + length);
    rawBuffer = rawBuffer.subarray(offset + length);
    if (mask) {
      payload = Buffer.from(payload);
      for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
    }
    if (opcode === 0x8) {
      // close
      try {
        proxy.stdin.end();
      } catch {
        /* ignore */
      }
      return;
    }
    if (opcode === 0x9) {
      sendFrame(0xa, payload);
      continue;
    }
    if (opcode === 0xa) continue;
    if (opcode === 0x1 || opcode === 0x0) {
      fragments.push(payload);
      if (fin) {
        const text = Buffer.concat(fragments).toString("utf8");
        fragments = [];
        let message;
        try {
          message = JSON.parse(text);
        } catch {
          continue;
        }
        handleMessage(message);
      }
    }
  }
}

proxy.stdout.on("data", (chunk) => {
  rawBuffer = Buffer.concat([rawBuffer, chunk]);
  if (!handshakeDone) {
    const marker = rawBuffer.indexOf("\r\n\r\n");
    if (marker === -1) return;
    const header = rawBuffer.subarray(0, marker).toString("utf8");
    rawBuffer = rawBuffer.subarray(marker + 4);
    if (!/ 101 /.test(header.split("\r\n")[0] ?? "")) {
      console.error(`proxy WebSocket upgrade rejected: ${header.slice(0, 300)}`);
      proxy.kill("SIGKILL");
      process.exit(1);
    }
    handshakeDone = true;
  }
  processFrames();
});

proxy.on("error", (error) => {
  console.error(`codex app-server proxy error: ${error.message}`);
  process.exit(1);
});

const overallTimer = setTimeout(() => {
  console.error(`daemon-proxy read timed out after ${options.timeoutMs}ms`);
  try {
    proxy.kill("SIGKILL");
  } catch {
    /* ignore */
  }
  process.exit(1);
}, options.timeoutMs);

function sanitize(value, keyHint = "", depth = 0) {
  if (depth > 12) return "<depth-limit>";
  if (typeof value === "string") {
    if (/(token|secret|authorization|password|api[_-]?key|cookie)/i.test(keyHint)) return "<redacted>";
    return value.length > 300 ? `${value.slice(0, 300)}…` : value;
  }
  if (Array.isArray(value)) return value.map((item) => sanitize(item, keyHint, depth + 1));
  if (!value || typeof value !== "object") return value;
  const out = {};
  for (const [key, item] of Object.entries(value)) {
    if (/^(id|turnId|threadId|sessionId|rootTurnId)$/.test(key) && typeof item === "string") {
      out[key] = `<${key}-tail:${item.slice(-4)}>`;
      continue;
    }
    out[key] = sanitize(item, key, depth + 1);
  }
  return out;
}

function summarizeRead(label, result) {
  return {
    label,
    topKeys: Object.keys(result ?? {}),
    readState: result?.readState ?? null,
    thread: result?.thread
      ? {
          idTail: String(result.thread.id ?? "").slice(-8),
          status: result.thread.status ?? null,
          historyMode: result.thread.historyMode ?? null,
          threadKeys: Object.keys(result.thread),
          turns: (result.thread.turns ?? []).map(summarizeTurn),
        }
      : null,
  };
}

function summarizeTurn(turn) {
  const items = Array.isArray(turn?.items) ? turn.items : [];
  return {
    idTail: String(turn?.id ?? "").slice(-8),
    status: turn?.status ?? null,
    itemsView: turn?.itemsView ?? null,
    turnKeys: Object.keys(turn ?? {}),
    itemCount: items.length,
    items: items.map((item) => ({
      type: item?.type ?? null,
      itemKeys: Object.keys(item ?? {}),
      phase: item?.phase ?? null,
      hasPhase: Object.prototype.hasOwnProperty.call(item ?? {}, "phase"),
      textPreview:
        typeof item?.text === "string"
          ? item.text.length > 120
            ? `${item.text.slice(0, 120)}…`
            : item.text
          : null,
      contentTextPreview: (() => {
        const content = Array.isArray(item?.content) ? item.content : [];
        const text = content.find((entry) => entry?.type === "text")?.text;
        return typeof text === "string" && text.length > 120 ? `${text.slice(0, 120)}…` : text ?? null;
      })(),
    })),
  };
}

async function main() {
  const started = Date.now();
  const record = {
    tool: "codex_daemon_proxy_read",
    threadId: options.thread,
    startedAt: new Date().toISOString(),
    daemonStart: {
      status: daemonStart.status,
      stdout: (daemonStart.stdout || "").slice(0, 500),
      stderr: (daemonStart.stderr || "").slice(0, 500),
    },
    reads: {},
    errors: {},
    notifications: [],
  };

  // Wait for the handshake to complete before issuing requests.
  const deadline = Date.now() + 15_000;
  while (!handshakeDone && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  if (!handshakeDone) throw new Error("proxy WebSocket handshake did not complete");

  const initialize = await request("initialize", {
    clientInfo: { name: "pharos-e2e-proxy-repro", title: "Pharos E2E daemon proxy repro", version: "0.1.0" },
    capabilities: { experimentalApi: false },
  });
  record.initialize = { userAgent: initialize?.userAgent ?? null, keys: Object.keys(initialize ?? {}) };
  sendJsonRpc({ jsonrpc: "2.0", method: "initialized", params: {} });

  // The Rust reply loop's exact shape.
  try {
    record.reads.includeTurnsTrue = await request("thread/read", {
      threadId: options.thread,
      includeTurns: true,
    });
  } catch (error) {
    record.errors.includeTurnsTrue = error.message;
  }

  try {
    record.reads.bare = await request("thread/read", { threadId: options.thread });
  } catch (error) {
    record.errors.bare = error.message;
  }

  try {
    record.reads.turnsList = await request("thread/turns/list", {
      threadId: options.thread,
      itemsView: "full",
      limit: 20,
    });
  } catch (error) {
    record.errors.turnsList = error.message;
  }

  record.notifications = notifications.slice(0, 20);
  record.finishedAt = new Date().toISOString();
  record.elapsedMs = Date.now() - started;

  const sanitizedSummary = {
    tool: record.tool,
    threadId: `<thread-tail:${String(options.thread).slice(-8)}>`,
    startedAt: record.startedAt,
    finishedAt: record.finishedAt,
    elapsedMs: record.elapsedMs,
    daemonStart: record.daemonStart,
    initialize: record.initialize,
    reads: {
      includeTurnsTrue: record.reads.includeTurnsTrue ? summarizeRead("thread/read includeTurns:true", record.reads.includeTurnsTrue) : null,
      bare: record.reads.bare ? summarizeRead("thread/read (bare)", record.reads.bare) : null,
      turnsList: record.reads.turnsList
        ? {
            label: "thread/turns/list itemsView=full",
            topKeys: Object.keys(record.reads.turnsList ?? {}),
            turns: (record.reads.turnsList?.data ?? []).map(summarizeTurn),
            nextCursor: record.reads.turnsList?.nextCursor ?? null,
            backwardsCursor: record.reads.turnsList?.backwardsCursor ?? null,
          }
        : null,
    },
    errors: record.errors,
    notificationMethods: notifications.map((message) => message?.method ?? null).filter(Boolean),
    stderrTail: stderrText.split("\n").slice(-10),
  };

  if (options.out) {
    mkdirSync(dirname(options.out), { recursive: true });
    writeFileSync(options.out, `${JSON.stringify(record, null, 2)}\n`);
  }
  console.log(JSON.stringify(sanitize(sanitizedSummary), null, 2));
  console.log(`raw: ${options.out ?? "<not written>"}`);

  try {
    sendFrame(0x8, Buffer.from([0x03, 0xe8]));
  } catch {
    /* ignore */
  }
  clearTimeout(overallTimer);
  setTimeout(() => {
    try {
      proxy.kill("SIGKILL");
    } catch {
      /* ignore */
    }
    process.exit(0);
  }, 300);
}

main().catch((error) => {
  clearTimeout(overallTimer);
  console.error(`daemon-proxy read failed: ${error.message}`);
  try {
    proxy.kill("SIGKILL");
  } catch {
    /* ignore */
  }
  process.exit(1);
});
