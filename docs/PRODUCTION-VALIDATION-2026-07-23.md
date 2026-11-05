# Pharos 2.0 production validation — 2026-07-23

Status: **four-device production pass + build-235 Agent-control closeout**

This record covers the distributed P2P architecture on `feat/distributed-iroh`.
The physical iPhone pass uses a normally signed build installed over the
existing application, preserving its Keychain identity and replica data.

## Acceptance matrix

| Requirement | Current evidence | Result |
| --- | --- | --- |
| macOS ↔ macOS ↔ Linux P2P networking | installed 227 runtimes, live direct/relay RPC, shared replica markers | pass |
| iOS networking and retained identity | signed simulator 227 plus physical iPhone 229, retained trust profile, live send/poke/background catch-up | pass |
| Physical iPhone in the four-device topology | signed build 229, existing controller identity, epoch 15, real chat/poke/background recovery | pass |
| Mesh Admin revoke and ghost cleanup | real epoch-8→9 ghost removal and matching audit SHA on three replicas | pass |
| Stable device and agent identity | device UUID + Endpoint ID roster; stable member/resource IDs across hosts and UI | pass |
| Group chat, ordering, deduplication | bidirectional live markers and offline three-message sequence, exactly once | pass |
| Offline delivery and cold recovery | build-227 Linux restarts measured at 1.174 and 1.160 seconds | pass |
| Agent lifecycle and directed poke | structured busy/blocked/idle/gone transitions and sub-second stable-ID poke | pass |
| Data conflict convergence | isolated concurrent writes converged to one deterministic winner | pass |
| Membership conflict safety | conflicting epoch-14 one-vote proposals persist and fail closed | pass |
| Membership conflict recovery | physical iPhone supplied the second controller vote; all four replicas converged at epoch 15 | pass |
| Production report | automated, runtime, hashes, backups, physical-device evidence, and transport boundary recorded here | pass |

## Version matrix

| Device | Installed build | Runtime state |
| --- | ---: | --- |
| Mac mini | macOS 235 | Pharos GUI running |
| home-ts | macOS 235 | Pharos GUI running |
| Linux VPS | headless build 227 source | `pharos-mesh.service` active |
| iPhone 17 Pro simulator | iOS 227 | installed, UI/network verified, then terminated |
| Physical iPhone 16 | iOS 2.0.0 (235) | installed, retained identity, UI/network/SSH/Stop verified |

Linux binary SHA-256:
`ccb7f70e46fae79e45254ecd1d798cfc7527a73c6dd43bb1eecbef92af9ed046`

Linux `libiroh_ffi.so` SHA-256:
`2c8b1f88c25760b85f7a3b52697d7e4fe062fd3ebf742dd7750243a46e93d1dc`

macOS build 227 archive:
`/tmp/Pharos-build227.zip`

macOS archive SHA-256:
`16f551559da6bb758e45f97f02701e0f5a9c60897a60bab9e60ec5a491586d6d`

macOS app / embedded helper SHA-256:

```text
b2a0801c3e24b99db64fbe2b6ba1686f50d429eaa0bba1de36ffdd9827bbfaa3  Pharos
67ae8d817e1201535f802f1e53166e5bd42f1868e4a676c8b7faf0ff409290a5  pharos-mesh
```

## Automated evidence

- Swift package: 357 tests passed, 0 failures on the final build-235 run.
- The Stop crash-recovery regression passed 20/20 consecutive stress runs
  after recovery timestamps were made monotonic across wall-clock rollback.
- iOS: 28 tests passed, 0 failures.
- `git diff --check`: clean.
- Fresh physical-device builds through iOS 2.0.0 (231) completed successfully
  and the installed application reports `CFBundleVersion=231`.
- The final in-place physical-device install reports iOS 2.0.0 (235); it
  retained the same Keychain identity, trust group, controller role, epoch 15,
  trusted-device roster, and SSH Host association.
- iOS build settings and generated simulator app report `CFBundleVersion=227`;
  the stale project-only value `159` was corrected in both the generated
  project and its `project.yml` source.
- Both installed macOS apps report `CFBundleVersion=235`.
- Linux service is active.
- The installed headless CLI reports `pharos-mesh 2.0.0` and identifies itself
  as a local-first P2P replica; legacy Broker/Node commands are rollback-only.

## Agent presence synchronization

The Mac mini's verified local presence contained the stable member IDs:

```text
019f7c8f-41e2-74e3-94e7-238892224d52  busy  codex
019f8b41-a928-7a52-80ca-e3f964982c87  idle  codex
292f3f16-4b19-48d0-9481-033580ddf9f5  idle  claude
```

A network query from home-ts returned those same member IDs, states, kinds, and
observation timestamps with host `mac-mini`. No member fell back to `unknown`.
The end-to-end GUI handoff, query, and relaunch took approximately 5.7 seconds.

The normally signed iOS 227 simulator UI independently showed:

- `pharos-shots` as `working` / `Busy`, hosted by `mac-mini`, with session
  prefix `019f7c8f`;
- `beiou-visual` as `idle` / `Available`, hosted by `mac-mini`;
- `tmux-relay-research` as `idle` / `Available`, hosted by `mac-mini`;
- current `pharos-shots` chat messages with accessibility status `Busy`.

None of those live agents appeared as gray `Unknown`. Old messages authored by
ended lifecycle probes can still say `Unknown status` because historical
messages do not persist an ephemeral presence snapshot; those ended identities
are excluded from the Live Agents list.

Simulator UI evidence:

- `/tmp/pharos-build227-signed-initial-attachments/3F05C1C1-EE0B-409F-B978-487B1E6E9CCE.png`
- `/tmp/pharos-build227-signed-initial-attachments/E9A17544-4935-46DC-8187-A1EC31BFDF9F.txt`
- `/tmp/pharos-build227-signed-agents-immediate-attachments/32D47485-2394-4715-B23D-5A902A2B312B.png`
- `/tmp/pharos-build227-signed-agents-immediate-attachments/88A3D814-6303-41DD-9672-8EBFD8F66912.txt`
- `/tmp/pharos-build227-signed-after20-attachments/3F5739F2-3CED-4B9A-9A7D-B663BB67F92E.png`
- `/tmp/pharos-build227-signed-after20-attachments/0EC05A87-E566-48AF-9977-CA27D054DDD3.txt`

The build-227 install preserved the selected trust group byte-for-byte:

`403534e7a7a0127ac67e656cd3c9a9c86c58ec87ad3aa5419a1242dc339b61f1`

The CoreSimulator container UUID changed during the in-place update, but the
trust-group hash, replica database, and target member rows did not. A
`CODE_SIGNING_ALLOWED=NO` test artifact correctly failed to open the
Keychain-backed identity and temporarily showed setup/`Agents unavailable`;
that artifact is not representative of an installable app. Rebuilding with
Xcode's normal `Sign to Run Locally` application identifier removed the false
setup sheet. The signed build opened Projects directly and retained the three
live agent states for more than 20 seconds.

Build 224 reproduced the reported all-gray `Unknown` state, but both Mac Host
apps had crashed before that capture. The crash was caused by an extra
`localAddress()` call introduced at the Swift/Iroh FFI boundary while adding
cold-dial arbitration. Build 226 uses the already verified expected Endpoint ID
instead. Both Mac processes remained alive through the build-226 capture, and
the simulator retained the same Mesh database and exact member ID while the
state changed from `Unknown` to `Busy`.

The implementation treats presence as an authenticated Host lease rather than
durable CRDT data. Remote views are invalidated when a fresh lease arrives or
expires. Presence records are accepted only when the responding endpoint and
the active Host resource agree on ownership.

## Real group chat, ordering, and offline recovery

Room `production-acceptance-20260723` was exercised against the installed
Mac mini, home-ts, and Linux service replicas.

- Linux sent `LINUX-LIVE-20260723-0705-1` and `-2`. Both Macs observed them in
  that order on the first poll, less than one second after the measured poll
  began.
- home-ts sent `HOME-LIVE-20260723-0706-1` and `-2`. Linux observed them in
  that order on the first poll, also less than one second.
- After several additional synchronization rounds, each of those four markers
  occurred exactly once on all three replicas.
- The Linux service was then stopped. Its local replica accepted
  `LINUX-OFFLINE-20260723-0707-1`, `-2`, and `-3`; the Mac correctly did not
  see them while Linux was offline.
- After the Linux service restarted on build 226, the Mac received all three
  offline events in order after 15 seconds. Each marker occurred exactly once on Mac mini,
  home-ts, and Linux.
- The temporary `linux-acceptance-20260723-0705` member then left the room.
  Its Host resource is durably `retired`, its roster removal converged, and its
  historical messages remain readable.

Build 226 also added deterministic cold-dial preference by stable Endpoint ID.
One side briefly waits for the peer's bidirectional Iroh connection before
falling back to its own dial, preventing two one-second anti-entropy loops from
continuously closing each other's streams as `duplicate connection`. A new
simultaneous-dial regression test and the existing bidirectional reuse tests pass.

A first post-fix cold restart trial exposed a separate scheduler problem:
build 226 took 24.334 seconds to deliver
`LINUX-COLD226-20260723T054438Z-1`. The Linux `sync-serve` loop was waiting for
sequential membership catch-up before starting ordinary replica sync. One
offline controller could therefore spend a full request timeout in front of
chat and state replication.

Build 227 runs signed membership-chain recovery on an independent control-plane
task and starts the one-second replica data plane immediately. Two fresh,
service-stopped offline writes then reached both running Macs in:

```text
LINUX-COLD227-20260723T055034Z-1  1.174 seconds
LINUX-COLD227-20260723T055038Z-2  1.160 seconds
```

Each marker was absent before restart and occurred exactly once on both Macs.
Every temporary probe member used for the measurement was removed through the
normal replicated room-leave lifecycle. Warm online chat and cold restart
anti-entropy now both meet the interactive target in this three-host topology.

## Signed iOS simulator end-to-end flow

The existing epoch-14 simulator replica was exercised without reinstalling,
resetting, archiving, pairing, leaving, revoking, or changing roles. It retained:

```text
device ID      311E3D00-CB49-45CB-A229-ECA72A49CBE3
trust group    7C09AA68-580F-4304-85BF-89A2D32C8BD6
roles          replica
profile SHA256 403534e7a7a0127ac67e656cd3c9a9c86c58ec87ad3aa5419a1242dc339b61f1
```

Using the visible Chat UI and accessibility-derived controls, iOS sent:

`IOS-SIM-E2E-20260723T061322Z @pharos-shots`

The stored immutable message proves both stable authorship and exact mention
resolution:

```text
authorMemberID  human@311E3D00-CB49-45CB-A229-ECA72A49CBE3
targetMemberID  019f7c8f-41e2-74e3-94e7-238892224d52
message ID      58A7F021-0D0A-413E-A382-1C5044E09931
```

The message triggered the structured `pharos-shots` mesh hook and occurred
exactly once in the simulator, Mac mini, home-ts, and Linux histories.

Pharos was then sent to the Simulator Home screen. While it was backgrounded,
home-ts authored `HOME-WHILE-IOS-BG-20260723T061322Z`
(`5F3747AB-9213-48A8-88A4-74BFEAF4F992`). Mac mini, home-ts, and Linux each
held one copy while the suspended iOS replica correctly remained at zero. On
foreground, iOS automatically synchronized the marker and showed both E2E
messages exactly once, in order. This is the intended iOS boundary: suspension
pauses networking; foreground anti-entropy recovers durable history without
loss or duplication.

Before backgrounding and after foreground recovery, the Agents UI showed
`pharos-shots` as Busy/working and the other two Mac agents as Available/idle.
No live agent became Unknown, no setup guide appeared, and no visual or
functional error was observed.

Simulator E2E evidence:

- `/tmp/pharos-build227-e2e-initial-attachments/B6B82FEF-5ECF-4646-98DD-2D56344A48E9.png`
- `/tmp/pharos-build227-e2e-initial-attachments/E111A0EE-3D1D-47E7-9EC9-3BFADEFD41FB.txt`
- `/tmp/pharos-build227-e2e-ios-send-attachments/E4D78566-877F-4516-A032-F15A5EB0235A.png`
- `/tmp/pharos-build227-e2e-ios-send-attachments/178E87A2-426D-4187-B152-0A6847063163.txt`
- `/tmp/pharos-build227-e2e-agents-pre-bg-attachments/EF31C97E-E64A-4B51-9A79-AAB21A4F06DA.png`
- `/tmp/pharos-build227-e2e-background-attachments/60B5BE05-1453-4B9F-BADD-0375790073BD.png`
- `/tmp/pharos-build227-e2e-foreground-room-attachments/07D5E8AB-E1BC-4FD4-91DA-95063FDF7826.png`
- `/tmp/pharos-build227-e2e-foreground-room-attachments/31B1D469-54C3-4D62-81DD-19BB6DDA6FE2.txt`
- `/tmp/pharos-build227-e2e-final-agents-attachments/427A502A-6538-4AF2-A9B6-1328DA1DCBFB.png`
- `/tmp/pharos-build227-e2e-final-agents-attachments/045383CA-251F-4612-8226-C4F7D9E118CB.txt`

This simulator is a replica, not a current Mesh Admin. Its successful data-plane
run did not count as a controller vote for the conflicting epoch-14 membership
proposals; the later physical-iPhone pass supplied the required quorum vote.

## Physical iPhone end-to-end flow

The existing app was upgraded in place from build 156 to signed build 228 and
then build 229. The install retained the device's Keychain identity, replica
history, and controller role:

```text
device ID    5DCBC5C4-9CB3-4AF2-BAE1-CA040FCC48D8
trust group  7C09AA68-580F-4304-85BF-89A2D32C8BD6
roles        controller, replica
epoch        15
```

No setup guide or archive flow appeared. Settings showed the iPhone as a Mesh
Admin, three current admins, the signed audit chain, and only the three current
remote peers: Mac mini, home-ts, and Linux.

From the physical Chat UI, the iPhone sent exactly one copy of each:

```text
IPHONE228-LIVE-20260723-1005
@pharos-shots IPHONE228-POKE-20260723-1005
```

The messages became visible locally in 2.382 and 2.438 seconds. The directed
mention reached the real `pharos-shots` hook; its normal `recv` path consumed
the poke and replied `IPHONE228-POKE-ACK-20260723-1005`. The iPhone received
the acknowledgement, and Mac mini, home-ts, and Linux each stored all three
markers exactly once.

For suspension recovery, XCTest confirmed the app was in
`runningBackground`. home-ts then authored exactly one
`IPHONE229-BG-CATCHUP-20260723-1017` message
(`5CB08436-5371-43A8-BC0E-0445B0B23BF8`). On foreground, build 229 recovered
the durable marker exactly once. Its live Agent list had no duplicate identity;
after the short network/lease handshake it stabilized to:

```text
beiou-visual         idle     Available  mac-mini  #beiou-dev
pharos-shots         busy     working    mac-mini  #production-acceptance-20260723
tmux-relay-research  idle     Available  mac-mini  #pharos-dev
```

The states remained correct at both the +10 and +30 second samples. Build 229
adds a scene-phase foreground synchronization trigger, in addition to the
scene-bound one-second anti-entropy scheduler, so a suspended iPhone restarts
transport and actively refreshes durable data and ephemeral Host leases when it
becomes active.

Physical-device evidence:

- `/tmp/pharos-build228-device/22-send-done-live.png`
- `/tmp/pharos-build229-device/54-final-foreground.png`
- `/tmp/pharos-build229-device/`

All CoreSimulator devices were shut down and deleted after the simulator
validation at the user's request. No physical-device data was removed.

## Revoked-device ghost repair

The Linux replica contained two old iPhone bindings incorrectly promoted into
the live epoch-14 roster by an earlier trust-roster format:

```text
1A6AFA2B-7712-4287-815E-CA8B62574CB3  epoch 14
7E61FDBE-9D93-43E3-8B58-BDF840C40002  epoch 14
```

Build 226 carries the retained binding's original epoch and repairs an existing
promoted row only when the locally stored signed current transition also proves
that device is absent. This is authority-reducing and cannot demote a legitimate
current member. The regression test covers both the ghost repair and the
non-demotion invariant.

After installing Linux build 226, one normal `distributed sync` over
`iroh-direct` repaired the rows to epochs 2 and 3. Both disappeared from the
live `device-list`; the four current remote peers remained. No direct SQLite
mutation was used. The pre-install replica and binaries are recoverable from:

`/var/backups/pharos-mesh-pre226-20260723T054047Z`

The build-227 performance deployment has a second complete pre-install backup:

`/var/backups/pharos-mesh-pre227-20260723T055020Z`

## Mesh Admin remote revoke and audit

Both product clients expose the same guarded operation:

- macOS Settings → Machines lists trusted devices; `Remove trusted device`
  is enabled only for a local Mesh Admin and requires a destructive
  confirmation;
- iOS Settings → Trusted devices exposes a trailing `Remove` action only for a
  local Mesh Admin and requires the same confirmation;
- neither client deletes a database row directly. The action creates a
  quorum-certified next-epoch roster through `MeshTrustGroupLifecycle`;
- successful changes remain in old-epoch storage and are rendered as
  `previous epoch → next epoch`, author device ID, removed device, and the full
  transition SHA-256.

This is exercised by live data, not only unit tests. The deliberately created
device `E2E Ghost 20260723`
(`B481D4EF-DC1D-4940-9F05-6E276FF84BE2`) was remotely removed in epoch 8→9 by
home-ts. Mac mini, home-ts, and Linux independently report the same signed
audit identity:

```text
author  4FAC1E46-8EE1-4DD3-A907-A753C4A0629A
removed B481D4EF-DC1D-4940-9F05-6E276FF84BE2:E2E Ghost 20260723
sha256  fbc165ae840626e66a445937b7dfb762bcdc420bef936582281859f86b461a76
```

The ghost is absent from the current epoch-14 `device-list` on all live
replicas while its signed removal remains queryable with `pharos-mesh pair
audit`. Linux joined after the earliest transitions, so its retained audit
chain begins at epoch 4; epochs 4→14 match both Macs byte-for-byte. Conflicting
one-vote proposals are also durable and fail closed rather than silently
overwriting another administrator's intent.

The physical iPhone then supplied the second controller vote needed to resolve
the deliberate epoch-14 conflict. The certified epoch 14→15 transition removed
the old audit simulator:

```text
author  48FFD7B5-ED5F-4E99-9107-B0BC519AC0DD
removed 311E3D00-CB49-45CB-A229-ECA72A49CBE3:iPhone 17 Pro (audit)
sha256  b4454c81c1a46358bfcf9f61011410c8ccb4bc32bf3cf929c405a6477ca1af5d
```

Mac mini and Linux received epoch 15 immediately. home-ts initially rejected
ordinary data sync with `membership-epoch-mismatch`, as required by the
fail-closed design; signed membership-chain catch-up then advanced it to the
same epoch and transition SHA. The physical UI also showed epoch 15 and no
audit-simulator peer.

## Directed poke and agent lifecycle

home-ts sent `POKE-LIVE-20260723-0710` to the exact stable member ID
`019f7c8f-41e2-74e3-94e7-238892224d52`. The Mac agent's normal `recv` path
returned that directed message on the first poll, in less than one second.

A temporary `lifecycle-acceptance-20260723-0712` member then exercised the
structured hook transitions on Mac mini. home-ts independently observed each
state with the same stable ID and observation timestamp:

```text
UserPromptSubmit       busy
PermissionRequest      blocked
Notification/idle     idle
Stop                   idle
SessionEnd/logout      gone
```

`Stop` means the turn has completed and the long-lived agent is available at
its composer; it is intentionally `idle`, not process termination. `SessionEnd`
is the process/session boundary. After the test member left its final room, its
local observation was removed and its durable Host resource was retired, so the
test did not leave a live roster ghost.

## Data-plane partition and conflict convergence

Both Mac apps, the Linux service, and the simulator app were stopped to create
a real full partition. Mac mini and home-ts then wrote different values to the
same `acceptance-probe/conflict-20260723-0715.winner` field while isolated:

```text
Mac mini: "mac-mini"
home-ts:   "home-ts"
```

Before reconnect, each replica retained its own local value. After all runtimes
were restarted, Mac mini, home-ts, and Linux converged within one second to the
same deterministic winner, `"home-ts"`. The test entity was then marked
`deleted=true`, which also converged to Linux. The probe type is not projected
into Projects, Issues, or Chat.

## Remote terminal boundary

The current iOS terminal is **not** an Iroh PTY relay. `RemoteTerminalView`
still opens a Citadel SSH session using a device-local `SSHHostProfile` and key,
then runs `pharos mesh attach-local <stable-resource-id>` on the Host. Stable
Mesh identity safely selects the tmux resource, but transport reachability and
authentication still depend on SSH. For Pharos 2.0, the supported reachability
boundary is the same LAN or Tailscale; native Iroh PTY relay is explicitly
deferred and is not a release gate.

The iOS simulator confirms this product boundary. The stable
`@pharos-shots` detail showed `working`, host `mac-mini`, and session
`019f7c8f`, but no terminal button because that simulator has no SSH host
mapping or identity. The UI explicitly says:
`P2P identifies the trusted Host; SSH provides the interactive byte stream.`
No SSH or PTY connection was attempted.

Simulator evidence:

- `/tmp/pharos-build159-terminal-detail-attachments/CC1A7D57-79D1-441D-9CF0-E441BE7B1FEC.png`
- `/tmp/pharos-build159-terminal-detail-attachments/A02E703B-B5DA-48E7-AA86-0D887F8AE382.txt`
- `/tmp/pharos-build159-terminal-settings-attachments/904CBA86-8E99-4BC0-80D5-458E4CA0B7A5.png`
- `/tmp/pharos-build159-terminal-settings-attachments/63EBAD9E-38DA-42C5-9704-10A45B8015A8.txt`

The P2P PTY design is documented in
`notes/research-pty-relay-iroh-2026-07-22.md`. It requires a MeshKit multi-ALPN
raw-stream API, PTY-specific grants and audit receipts, bounded flow control,
and epoch-driven live-session revocation. It is research, not a shipped Pharos
2.0 capability, and must not be described as already solved by P2P Mesh.

The physical-device pass found and closed a separate association bug in this
supported SSH path. P2P correctly located an Agent's owning Host by immutable
Mesh Device ID, but older iOS SSH profiles were keyed only by a mutable display
name. The production Agent reported `mac-mini` while the saved profile was
labelled `Xiang’s Mac mini`, so the UI could not join the two records despite
both devices being reachable through Tailscale.

Build 231 stores the owning Mesh Device ID on `SSHHostProfile` and resolves it
before display-name and endpoint aliases. Settings chooses from trusted devices
with the Host role and persists that stable association; display names are now
labels and legacy migration fallbacks rather than routing keys. The existing
profile was mapped to:

```text
Mesh Host       mac-mini
Mesh Device ID  48FFD7B5-ED5F-4E99-9107-B0BC519AC0DD
SSH endpoint    baixianger@100.123.131.117:22
```

On the physical iPhone, `Remote Control (SSH → tmux attach)` then appeared for
the exact P2P-located Agent resource. To avoid disturbing the active
`pharos-shots` session, the test attached only to the idle
`tmux-relay-research` resource `292f3f16…`. The iPhone displayed the real
Codex/tmux session, including its session output and tmux status bar; no input,
poke, or stop action was sent. Installing the next signed build terminated the
test terminal session.

Physical SSH evidence:

- `/tmp/pharos-build230-device/ssh-mapping/76-live-terminal-before-close.png`
- `/tmp/pharos-build230-device/ssh-mapping/`
- `/tmp/pharos-build231-device/final-readonly.xcresult`
- `/tmp/pharos-build231-device/attachments/`

The final build-231 read-only XCTest passed 1/1 and confirmed epoch 15, the
retained iPhone Device ID, profile label `mac-mini`, a non-empty
`Host identity, mac-mini` picker, and an enabled Remote Control action. A
read-only export of the installed app preferences independently confirms the
profile persisted
`meshDeviceID=48FFD7B5-ED5F-4E99-9107-B0BC519AC0DD`, not merely the current
display name.

## Isolated iPhone controller lab

A fresh iPhone 16 simulator was enrolled as a genuinely new device in an
isolated trust group, rather than copying the physical iPhone identity or
touching the production Mesh. The simulator received independent keychain
identity, `controller,replica` roles, and became the second Mesh Admin at epoch
2.

The controller authority was exercised across the real Iroh path:

1. The Mac controller invited `Disposable Lab Device` as a replica.
2. With two controllers in the roster, admission required and received a 2/2
   controller quorum; membership advanced epoch 2→3.
3. The simulator iPhone then removed that disposable device through the iOS
   Settings UI.
4. The Mac and iPhone converged on epoch 3→4 with the iPhone as author and the
   same signed transition identity:

```text
author  95FBCBE6-0F53-43D2-BC6D-747EF7226437
removed 32070918-FB0D-41ED-9B93-3B5E4F411F50:Disposable Lab Device
sha256  44f41a3bfc8926bc4dc8b514a49d4aba684053ecadd91511f1f460967cfb9ba9
```

This proves that an iOS controller participates in quorum and can administer
membership; it is not a centralized server or a UI-only role.

The first pass also found and fixed an onboarding presentation collision:
the setup cover and app root both attempted to present the same pairing sheet.
Device invitations now close onboarding and use one app-level confirmation
presenter. The confirmation explicitly discloses
`Mesh Admin (controller) + signed data replica`, explains invite/remove
authority, and Settings badges the local iPhone as `Mesh Admin`.

A second fresh simulator and isolated Mesh verified the fix end to end:

- zero `only presenting a single sheet` warnings;
- one `Trust and connect` tap reached `Device connected` within five seconds;
- `Done` opened the main app;
- Settings showed the local Mesh Admin badge and two admins.

The rebuilt simulator target passed 28/28 iOS tests. Evidence:

- `/tmp/pharos-controller-lab-pair-device-confirmation.png`
- `/tmp/pharos-controller-lab-after-revoke-5s.png`
- `/tmp/pharos-controller-lab-invite-ui.png`
- `/tmp/pharos-pairing-ux-regression-confirmation-2.png`
- `/tmp/pharos-pairing-ux-regression-success.png`
- `/tmp/pharos-pairing-ux-regression-settings.png`

After both labs, the production simulator profile remained byte-identical at
SHA-256
`403534e7a7a0127ac67e656cd3c9a9c86c58ec87ad3aa5419a1242dc339b61f1`
in trust group `7C09AA68-580F-4304-85BF-89A2D32C8BD6`.

## Membership conflict safety

Mac mini and home-ts each already approved a different epoch-14 membership
proposal. The system refused to manufacture a winner from one vote and reported
that another current admin had to come online. With the physical iPhone online,
the matching proposal received the required second controller approval and
became the certified epoch 14→15 transition.

This demonstrates both halves of the decentralized conflict model: concurrent
administrators cannot overwrite one another with insufficient authority, and a
quorum of current controllers can resolve the conflict without a broker or
central controller. All four retained replicas now identify the same trust
group and epoch.

## Agent control and reconciliation closeout

Build 235 closes the gap between “this session is visible” and “this Host may
safely control this exact process.” Shared room membership remains durable P2P
data, but poke/attach/stop authority is reconstructed only on the owning Host.

The Mac mini automatically upgraded two pre-existing structured-hook sessions
to binding schema v2:

```text
beiou-visual         session $0  pane %0  generation 2  presence,poke,stop
tmux-relay-research  session $1  pane %1  generation 2  presence,poke,stop
```

Each binding records the private tmux socket, session ID, session creation
time, pane ID, and pane PID. `pharos-shots` correctly remained presence-only
because its current structured observation contains no tmux socket/pane proof;
Pharos did not guess from its nick, cwd, host name, or another pane.

A third legacy-style session proved the explicit adoption path. It first joined
the production room with only stable member ID
`019f8c00-0000-7000-8000-000000000234`, then ran:

```text
pharos mesh claim --member 019f8c00-0000-7000-8000-000000000234 --kind codex
```

from inside its own tmux pane. The command returned `claimed … on this Host`,
resolved one exact live seat, and published generation 2 with
`presence,poke,stop`. The same command fails outside tmux, for a session with no
room membership, or when another member claims the same socket+pane.

Two real home-ts → Mac mini Stop operations then exercised the signed Iroh RPC
path against sacrificial sessions `…0232` and `…0234`. In both cases home-ts
returned `stopped`, the exact tmux session disappeared, the Host-private binding
was deleted, the Host resource became `retired`, the local observation was
removed, and both Macs' room rosters no longer contained the member.

For `…0232`, the Mac mini's durable journal contains:

```text
command     015C8A77-99D8-4D75-8996-A5F4526CBD49
action      agent.stop.v1
generation  2
state       executed
result      stop-ok
```

The Host also scans accepted/executing Stop receipts on launch. Isolated tests
prove recovery repeats only the idempotent old-seat termination/finalization
sequence, completes roster/resource/binding cleanup after a simulated crash,
and treats a gone or replacement seat as “old resource already gone” without
killing the replacement.

The lifecycle UI now presents independent actions:

- **Stop managed agent** only when one trusted Host advertises a verified Stop
  capability;
- **Remove from Mesh** for roster removal without claiming process termination;
- **Repair** only for a local observation that can be re-proved;
- SSH→tmux Attach only for a managed Host resource with a device-local SSH
  profile.

If multiple Hosts claim one resource, control fails closed as an ownership
conflict. If any trusted Host lookup is incomplete, the controller reports the
Host as unavailable rather than falsely reporting “resource not found” or
assuming that a visible claim is unique.

That unavailable path was also exercised live. With only the Mac mini Pharos
Host process stopped (the target tmux seat remained alive), home-ts returned
`The trusted Host that controls this agent is currently unavailable.` after its
bounded lookup. The exact `$6` / `%6` / PID `76522` target was still running
after the failed command. Restarting the Mac mini app restored the Host without
changing the resource generation or binding.

The physical iPhone then performed the same successful control path against a
third sacrificial member, `019f8c00-0000-7000-8000-000000000233`
(`e2e-ios-stop-232`). Build 235 launched without onboarding or a crash and
retained:

```text
device ID  5DCBC5C4-9CB3-4AF2-BAE1-CA040FCC48D8
role       Mesh Admin
epoch      15
admins     3
```

The Agent detail simultaneously showed enabled **Stop managed agent**, a
separate **Remove from Mesh**, and **Remote Control (SSH → tmux attach)**. The
test selected only Stop and confirmed `Stop @e2e-ios-stop-232?` / `Stop agent`;
its explicit test flag records `removeTapped=false`, and it did not attach or
touch another Agent.

The iPhone returned to All Agents with the target absent. Independently, the
Mac mini showed the exact tmux seat gone, binding and observation absent, Host
resource retired at generation 3, and both Mac rosters without the member. The
signed Host receipt is:

```text
command     EA9FC95C-7274-4D9F-B6C7-84FF1357FE8B
action      agent.stop.v1
generation  2
state       executed
result      stop-ok
```

The physical XCTest passed 1/1 in 38.528 seconds. Evidence is under
`/tmp/pharos-build235-device/`, including `final-stop.log`, the `.xcresult`,
before/confirmation/after screenshot and hierarchy attachments, final
`97-final-agents-roster.png`, and `mesh-who-after.log`.

## Final release boundary

The four-device Mesh data plane, controller quorum, replicated chat, directed
agent delivery, lifecycle presence, offline catch-up, conflict convergence, and
ghost cleanup have production evidence in this record.

Interactive terminal transport remains deliberately narrower: stable Mesh
identity selects the intended Host resource, while the terminal byte stream
uses SSH and therefore requires same-LAN or Tailscale reachability plus a
device-local SSH profile and key. Native Iroh PTY relay is deferred and is not
represented as a Pharos 2.0 feature.
