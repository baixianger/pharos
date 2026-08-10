# Research: iOS → Host P2P PTY relay over Iroh 1.0 / MeshKit

Date: 2026-07-22 · Author: tmux-relay-research (agent) · Status: research only, no code changes
Requested by pharos-shots in pharos-dev. Branch context: `feat/distributed-iroh`.

## TL;DR

Build it, in phases, on the existing mesh identity/capability/audit stack — but the enabling
work is in **MeshKit, not Pharos**: MeshKit 0.2's public `IrohEndpoint` is single-ALPN and
request/response-only, while everything a PTY relay needs (long-lived bi-streams, chunked
async I/O, QUIC flow control, multi-ALPN routing, datagrams, 0-RTT) already exists one layer
down in `IrohLib` (iroh-ffi 1.1.x wrapping iroh 1.0). The design that fits iOS reality is
**"accept the disconnect, make reattach instant"**: tmux is the session keeper on the host,
the phone reattaches with a fresh QUIC connection (0-RTT-assisted) and tmux repaints — no
Eternal-Terminal-style replay buffer needed in v1. Tailscale SSH is a weak baseline for this
specific product (GUI macOS app cannot be a Tailscale SSH server at all; iOS pays the
packet-tunnel VPN tax) and would bolt a second identity/trust system onto a mesh that
already has one.

---

## 1. Current state (facts from the repo)

- One Iroh endpoint per device, ALPN `me.pai.pharos/mesh/1` (`DistributedMeshProtocol.swift:6`),
  MeshKit 0.2.0 (baixianger fork) over iroh-ffi 1.1.1 / iroh 1.0. Frame magic `PHM1`.
- Identity = one Curve25519/Ed25519 key: Iroh endpoint secret **and** Pharos signing key;
  endpoint ID = hex signing pubkey. Keychain (+ mirrored 0600 file) on macOS, file on Linux.
- Trust: trust group + controller-signed `MeshMembershipTransition` epochs (full-roster
  replacement ⇒ deterministic revocation). Pairing = signed 5-min single-use invitations
  (`pharos-device-v1:` tickets / `pharos://device` QR).
- Capability model already exists for host actions: `MeshHostResource{resourceID, generation,
  allowedActions}` (host-local authority), `MeshSignedHostCommand` (Ed25519, sender bound to
  QUIC-authenticated `remoteEndpointID`), `MeshSignedCommandReceipt` journal persisted before
  side effects, idempotency fingerprints. Implemented actions: `agent.poke.v1`, `agent.stop.v1`
  driving tmux via `DistributedHostCommandExecutor`; `agent.attach.v1` is declared but
  **not implemented** — the natural slot for this feature.
- resourceID → tmux session binding is host-private (0600, `host-resources-v1/`); controllers
  can never name a tmux socket/session directly. Keep this property.
- Interactive terminal today: **SSH only** (iOS `RemoteTerminalView` = SwiftTerm + Citadel,
  runs `pharos mesh attach-local <resourceID>`), with an `acceptAnything` host-key caveat.
  The Iroh path carries replication, chat, pairing, poke/stop — no streaming.

### The MeshKit constraint (decisive for design)

- Public `IrohEndpoint` hardcodes one ALPN, rejects others in its accept loop, exposes no raw
  streams/datagrams, and keeps `IrohLib.Endpoint` private. Its bi-stream use is one framed
  request → one `readToEnd` response — unusable for interactive byte streams.
- `IrohLib` (UniFFI, 10k lines) has it all: `EndpointOptions(alpns:[Data], protocols:[Data:
  ProtocolCreator])` multi-ALPN routing, `openBi/acceptBi`, chunked `read(sizeLimit:)` /
  `write(buf:)` (returns bytes written ⇒ backpressure), `finish/reset/stop`, `setPriority`,
  `setReceiveWindow`, datagrams, `paths()` / `watchPathEvents`, 0-RTT (`connectPending`).
- ⚠️ The "second `IrohEndpoint` bound with the same secret key" shortcut is **suspect**: two
  live QUIC endpoints publishing the same EndpointId would race home-relay registration and
  discovery (unverified but plausible conflict). If a pre-fork spike is wanted, use a
  **derived PTY subkey** cross-signed by the device identity key instead. The proper fix is
  MeshKit 0.3: multi-ALPN + a raw-stream API. MeshKit is our own fork, so this is tractable.

## 2. Threat model

Asset: a PTY into an agent tmux session = **arbitrary code execution as the Mac user** — the
highest-privilege capability the mesh will ever carry; strictly more dangerous than poke/stop.

| Adversary / failure | Mitigation |
|---|---|
| Stolen, unlocked iPhone | App-level Face ID/local-auth gate before terminal open; short-TTL single-use session grants; host-side kill switch + session indicator |
| Compromised/rogue relay | Already mitigated: QUIC TLS is end-to-end; relays see ciphertext. Applies to n0 and self-hosted relays equally |
| Stolen device key / lost device | Existing epoch revocation (`MeshMembershipTransition`); **new requirement: epoch bump must terminate live PTY sessions immediately** |
| Replay | Single-use grant nonces (reuse the invitation `MeshInvitationUseRecord` pattern); QUIC's own anti-replay; **never put input bytes in a 0-RTT flight** (0-RTT is replayable — resume-hello only) |
| Trusted-but-lesser device escalation | New role/action gate: PTY requires `agent.pty.v1` in `MeshHostResource.allowedActions` **and** a device role (e.g. `.terminal`) granted explicitly — not default for every replica |
| Stale/confused deputy | Grants bind `expectedResourceGeneration` (existing pattern) + target resourceID + client endpoint ID; generation bump invalidates outstanding grants |
| Silent access | Signed session receipts (below) + visible "live session" UI on the Mac |

### Authorization flow (proposed)

1. Phone (trusted device, current epoch, role includes terminal) sends a signed
   `pty.grant.request.v1` for a resourceID over existing mesh RPC.
2. Host policy decides: single-user personal mesh default = auto-issue, with a macOS
   notification "iPhone attached to <agent> — click to revoke"; optional strict mode =
   explicit click-to-approve (first use per resource, or always).
3. Host returns a signed **grant**: `{grantID, trustGroupID, epoch, resourceID,
   expectedResourceGeneration, clientEndpointID, hostEndpointID, issuedAt, expiresAt (≤5 min
   to *first use*), maxSessionSeconds, nonce, signature}` — same canonical-JSON Ed25519 recipe
   as invitations. Single-use (nonce consumed on session open); session may outlive the grant
   TTL up to `maxSessionSeconds`.
4. Phone dials ALPN `me.pai.pharos/pty/1`; QUIC handshake authenticates `remoteEndpointID ==
   grant.clientEndpointID`; host validates grant, epoch, generation, then spawns the PTY.

### Audit & revocation

- **Session receipts**, host-signed, persisted like `MeshSignedCommandReceipt` and replicated
  (tamper-evident via existing hash chain): opened/resized/superseded/closed, peer, path type
  (direct/relay), bytes in/out, duration, close reason.
- Revocation layers: close one session (UI/CLI) → retire resource (generation bump) → remove
  device (epoch bump). Host enforces all three against live connections, not just new ones.
- Optional later: host-local asciinema-style recording, size-capped, off by default
  (Tailscale-SSH-recording parity for a personal mesh is a nice-to-have, not v1).

## 3. Wire design: ALPN + streams

New ALPN **`me.pai.pharos/pty/1`** on the same device identity (via MeshKit 0.3 multi-ALPN;
one physical endpoint, one NAT/holepunch session shared with mesh RPC).

Per PTY session, one QUIC connection (client = phone), two bi-streams:

- **Stream A — control** (opened first; `setPriority` above data): length-prefixed CBOR/JSON
  frames: `ClientHello{grant, protocolVersion, cols, rows, lastSeq?}`,
  `HostHello{sessionID, tmuxSession alias, startSeq}`, `Resize{cols,rows}` (client debounces —
  the SwiftTerm SIGWINCH debounce already exists), `Ping/Pong`, `Detach` (clean background),
  `Superseded`, `Error{code}`.
- **Stream B — data**: upstream = raw input bytes; downstream = PTY output in tiny framed
  chunks `{seq: UInt64, len}`. Seq numbers ship in v1 for **metrics/diagnostics only** — see
  reconnect model below for why no replay buffer.
- Host side: `forkpty` + `tmux attach-session -d -t =<session>` (exact reuse of the
  `attachLocal` recipe and the host-private resource binding). Resize = `TIOCSWINSZ`.
- **Flow control**: rely on QUIC per-stream backpressure — bounded in-flight buffer between
  the PTY master read loop and the stream writer; when the phone stalls, stop reading the PTY
  master ⇒ the foreground process blocks on write ⇒ Ctrl-C always works. This is ttyd's
  PAUSE/RESUME effect achieved implicitly, and it structurally fixes the flood bug that is
  Eternal Terminal's canonical weakness (`cat /dev/zero` → unkillable). Never buffer
  unboundedly on either side.
- **Keep-alive**: iroh/quinn defaults are keep-alive **off**, idle timeout 30 s — set
  keep-alive (~10 s) on the PTY connection explicitly, foreground only.
- Datagrams: not needed in v1 (control frames are tiny and ordered-is-fine).

### Reconnect & single-client ownership

Two distinct layers:

1. **Path change, app foreground** (Wi-Fi↔cellular, relay→direct): iroh 1.0 QUIC multipath
   keeps the *same connection* alive across path swaps — nothing to do. (Watch item: a
   0.96-era regression where holepunching wasn't re-triggered on network change; fix PR
   merged Jan 2026 — verify on our pinned 1.0.x before relying on fast re-punch.)
2. **Connection death** (lock/suspend ≥ ~30 s, app kill, Mac sleep): *accept it.* tmux is the
   session keeper; scrollback lives in tmux. On foreground: 0-RTT-assisted redial (measured
   ~230 ms vs ~550 ms EU↔Asia; far less on direct paths) with a **resume-hello referencing
   the live sessionID** (grant already consumed ⇒ reattach doesn't need a new grant while
   within `maxSessionSeconds`; else re-grant). Host swaps the connection under the existing
   PTY, tmux repaints on reattach. Target: lock→unlock→usable prompt well under 1 s on LAN.
   This is exactly the mosh+tmux / La Terminal "El Preservador" pattern, minus their hacks.
   **No ET-style ring-buffer replay in v1** — tmux redraw makes it redundant; revisit only if
   repaint latency on huge scrollback windows proves annoying.

Ownership: **one live PTY session per resourceID** (mirrors `tmux attach -d` semantics). A
valid new attach supersedes the old one (`Superseded` close frame, audit receipt). Binding is
sessionID + clientEndpointID; same phone reattaching replaces silently, a *different* trusted
device replacing is allowed (single-user mesh) but distinctly audited + notified on the Mac.

## 4. iOS lock-screen reality (design inputs, verified)

- ~5 s default background runtime; ~30 s with `beginBackgroundTask`; suspension can invalidate
  sockets out from under the app (classic `EBADF`-on-resume; treat every foreground as
  "socket state unknown — redial"). NAT UDP mappings may expire (RFC 4787 floor: 2 min).
- Low Power Mode tightens everything; Network.framework offers no survival advantage, only
  recovery signals — and our transport is a Rust BSD socket anyway (bridge `NWPathMonitor`
  events to trigger redial if needed).
- Push-to-wake is not viable (silent push throttled; PushKit requires CallKit; NEAppPushProvider
  is LAN-only). The location-permission hack (Blink/Termius/Prompt) costs battery and App
  Review friction — **skip**; our reattach story removes the need.
- iOS 26 `BGContinuedProcessingTask` could later cover "let this long command finish" (Live
  Activity + progress), but not an idle terminal. Optional Phase-4 nicety.
- Shipping-app precedent for our exact model: La Terminal's server-side session keeper +
  reattach; Blink solves it with mosh (protocol survives), Termius/Prompt with hacks.

## 5. NAT / relay path

- iroh 1.0: ~90% of connections go direct (n0 claim; ~95% of data volume); relay is the
  bootstrap + fallback, WebSocket/TCP-carried (⇒ head-of-line blocking on relayed paths —
  irrelevant for keystrokes, matters for floods; our flow control caps exposure). Relay↔direct
  migration is mid-connection and lossless (multipath).
- n0 public relays: 4 (2×US, EU, Asia), free, rate-limited, "development and testing".
  For a 2-device personal mesh the volume is trivial, but PTY is latency-sensitive and the
  limits are unspecified ⇒ plan for **self-hosted `iroh-relay`** (dev-bm Hetzner box is the
  obvious host; `MeshIrohRelayPolicy.custom(urls:)` already exists in our stack) or n0 Pro
  ($19/mo) as the production posture. 1.0.2 relay security fix noted — track releases.
- No published iroh-vs-WireGuard latency benchmarks; direct-path QUIC is RTT-bound like
  WireGuard for keystroke echo. Known non-issue for us: single-stream bulk throughput caps
  (~40% link on LAN, iroh#4286) — keystroke traffic doesn't care.

## 6. Comparison vs Tailscale SSH

| Dimension | Iroh PTY relay (proposed) | Tailscale SSH |
|---|---|---|
| Mac host support | In-app, our stack | **GUI macOS apps cannot be the SSH server** — CLI tailscaled only (brew), plus a fresh 2026 `getent` regression (#18957) |
| iOS cost | In-app QUIC, foreground-only | Packet Tunnel VPN: one-VPN-at-a-time, 50 MiB extension cap (documented OOM history), acknowledged battery drain |
| Identity/trust | Reuses mesh: device keys, epochs, capability grants, signed receipts — one system | Second identity plane: tailnet account, IdP login, ACLs, node-key expiry (180 d), check-mode re-auth via browser |
| Revocation/audit | Epoch bump / generation bump / session kill; replicated signed receipts | Tailnet ACL edit; session recording exists but is plan-gated + needs a recorder node |
| Reconnect UX | 0-RTT redial + tmux repaint (sub-second target) | SSH reconnect (or mosh on top — yet another moving part) |
| Perf | ~90% direct, QUIC; relay = TCP-carried | ~90%+ direct, WireGuard; DERP relay = TCP-carried. Effectively parity |
| Build cost | MeshKit 0.3 + new protocol + grant/audit plumbing — real work, owned security surface | Near-zero protocol work, but external control-plane dependency and a worse fit for App Store distribution |
| Baseline note | — | Today's actual incumbent is our own SSH path (Citadel/SwiftTerm), which carries an `acceptAnything` host-key caveat and requires reachable SSH — the relay removes both |

**Verdict**: for this product (personal mesh, App Store iOS app, GUI Mac host, existing
capability/audit machinery) the Iroh relay is the right call; Tailscale SSH would import an
external trust system to work around its own Mac-GUI limitation. Keep the SSH terminal as the
fallback path until Phase 3 exits, then demote it to explicit-recovery-only (already the
stated posture in README).

## 7. Phased rollout

- **P0 — spike (1 target)**: standalone `pharos-mesh` subcommand pair speaking raw `IrohLib`
  (derived PTY subkey cross-signed by device identity — do *not* reuse the identity key on a
  second endpoint until the same-EndpointId-twice discovery conflict is disproven). One
  control + one data stream, tmux attach, resize, bounded-buffer flow control, keep-alive.
  Exit: Mac↔Mac and iPhone-TestFlight↔Mac sessions; measure reattach + echo RTT; verify
  multipath Wi-Fi↔cellular and relay→direct upgrade; flood test (`yes`, `cat /dev/zero`).
- **P1 — MeshKit 0.3**: multi-ALPN (`EndpointOptions.alpns`/`protocols` router) + public raw
  bi-stream API + keep-alive/priority knobs; Pharos moves PTY onto the single shared endpoint,
  admission = trust-roster check. Spike subkey path deleted.
- **P2 — capability + audit**: implement `agent.pty.v1` (the declared-but-unimplemented
  `attach` slot): grant request/issue flow, single-use nonces, generation binding, session
  receipts, epoch-kill of live sessions, macOS live-session indicator + one-click revoke,
  `pharos mesh sessions` CLI.
- **P3 — iOS terminal UX**: SwiftTerm wired to the Iroh transport alongside SSH; Detach on
  background, 0-RTT resume-hello on foreground, Face ID gate, path-type badge (direct/relay),
  supersede UX. Exit: SSH no longer needed for daily attach on both Macs + iPhone.
- **P4 — hardening**: self-hosted relay deployment + failover drill, optional recording,
  BGContinuedProcessingTask for long-running commands, metrics surfaced in Dashboard.

## 8. Production metrics that must be tested (gate P3→P4 on these)

1. **Reattach latency** lock→unlock→usable prompt: p50 < 800 ms, p95 < 2 s (direct path);
   record with/without 0-RTT ticket hit.
2. **Keystroke echo RTT** p50/p95, segmented by path type (direct LAN / direct WAN / relay).
3. **Path mix**: % session-time direct vs relay per network pair (home Wi-Fi, cellular,
   hostile Wi-Fi); holepunch success rate; relay→direct upgrade time after connect.
4. **Network-change survival** (foreground): Wi-Fi↔cellular swap — session survives, gap
   duration; verify re-holepunch actually fires on our pinned 1.0.x (known 0.96 regression).
5. **Flood/flow control**: `cat /dev/zero`-class output — Ctrl-C-to-quiet < 300 ms, host and
   client memory bounded (fixed caps), mesh RPC on the shared endpoint stays responsive.
6. **Security invariants as tests**: expired/reused/foreign-client grants rejected; generation
   bump invalidates grants; epoch bump kills a *live* session < 2 s; supersede closes the old
   session with receipt; no input bytes ever in a 0-RTT flight (assert in client).
7. **Receipt completeness**: every open/resize/supersede/close produces exactly one signed,
   replicated receipt, surviving crash-during-session (crash-recovery journal like command
   receipts).
8. **Idle behavior**: keep-alive holds a foreground-idle session ≥ 30 min on cellular; battery
   drain per idle foreground hour within budget; Mac host sleep behavior defined (session
   closes cleanly with receipt, reattach after wake works).
9. **Relay dependence**: forced-relay mode (`relayPolicy` custom) full functional pass;
   n0-public-relay rate-limit behavior observed; self-hosted relay failover.

## 9. Open questions / verify-before-P1

- Same-secret-key-on-two-endpoints discovery conflict: confirm or disprove against iroh 1.0.x
  (affects only the P0 shortcut; P1 makes it moot).
- Pinned iroh-ffi 1.1.1: does it expose `connectPending`/0-RTT and `watchPathEvents` on iOS
  builds? (Support matrix says yes for multipath; 0-RTT via FFI needs a hands-on check.)
- quinn stream-priority behavior through the FFI (`setPriority`) — verify control frames
  preempt a saturated data stream on a relayed (TCP-carried) path.
- Whether grant issuance should *require* Mac-side approval on first attach per resource even
  in the personal-mesh default (leaning yes: one click, once per agent, cheap insurance).
