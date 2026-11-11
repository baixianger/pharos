#!/usr/bin/env node
// Newline-delimited JSON-RPC client for the pharos-agent-runtime Unix socket.
//
// The runtime speaks one JSON object per line over a Unix stream socket and
// answers with one JSON object per line (`AdapterRequest`/`AdapterResponse`).
//
// Usage:
//   node scripts/e2e/codex_runtime_rpc.mjs --socket <path> --method <method> [--params '<json>']
//   node scripts/e2e/codex_runtime_rpc.mjs --socket <path> --method <m> --params-file <path>
//
// On success prints the JSON-RPC `result` object to stdout and exits 0.
// On a JSON-RPC error prints {"error":{code,message}} to stdout and exits 2.
// On a transport/setup error prints a message to stderr and exits 1.
// No dependencies; never used outside the local sandbox socket.

import net from "node:net";
import { readFileSync } from "node:fs";

function parseArgs(argv) {
  const options = { socket: null, method: null, params: "{}", timeoutMs: 60_000 };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--socket") options.socket = argv[++i];
    else if (arg === "--method") options.method = argv[++i];
    else if (arg === "--params") options.params = argv[++i];
    else if (arg === "--params-file") options.params = readFileSync(argv[++i], "utf8");
    else if (arg === "--timeout-ms") options.timeoutMs = Number(argv[++i]);
    else if (arg === "--help" || arg === "-h") {
      console.log("usage: codex_runtime_rpc.mjs --socket <path> --method <method> [--params '<json>']");
      process.exit(0);
    } else {
      console.error(`unknown argument: ${arg}`);
      process.exit(1);
    }
  }
  if (!options.socket || !options.method) {
    console.error("--socket and --method are required");
    process.exit(1);
  }
  return options;
}

const options = parseArgs(process.argv.slice(2));

let params;
try {
  params = JSON.parse(options.params);
} catch (error) {
  console.error(`invalid --params JSON: ${error.message}`);
  process.exit(1);
}

const request = {
  jsonrpc: "2.0",
  id: `e2e-${Date.now()}-${process.pid}`,
  method: options.method,
  params,
};

const socket = net.createConnection({ path: options.socket });
let buffer = "";
let settled = false;

function finish(code, payload, stream = "stdout") {
  if (settled) return;
  settled = true;
  clearTimeout(timer);
  if (payload !== null) {
    const text = `${JSON.stringify(payload)}\n`;
    if (stream === "stdout") process.stdout.write(text);
    else process.stderr.write(text);
  }
  try {
    socket.end();
  } catch {
    /* ignore */
  }
  process.exit(code);
}

const timer = setTimeout(() => {
  finish(1, `runtime RPC ${options.method} timed out after ${options.timeoutMs}ms`, "stderr");
}, options.timeoutMs);

socket.on("error", (error) => {
  finish(1, `runtime socket error: ${error.message}`, "stderr");
});

socket.on("connect", () => {
  socket.write(`${JSON.stringify(request)}\n`);
});

socket.setEncoding("utf8");
socket.on("data", (chunk) => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (!line) continue;
    let response;
    try {
      response = JSON.parse(line);
    } catch (error) {
      finish(1, `invalid runtime response: ${error.message}`, "stderr");
      return;
    }
    if (String(response.id) !== String(request.id)) {
      // Not our response; the runtime is one-request-per-connection for us.
      continue;
    }
    if (response.error) {
      finish(2, { error: response.error });
      return;
    }
    finish(0, response.result ?? null);
    return;
  }
});
