# Pharos for iPhone and iPad

This directory is an independent XcodeGen application target for operating the
existing Pharos agent mesh from iPhone and iPad.

## Transport contract

| Concern | Owner | Transport | Security boundary |
|---|---|---|---|
| Rooms, roster, history, `say` | Configured Pharos Mesh Broker | newline-delimited JSON over TCP `47800` | the Broker must bind only to its Tailscale address; Tailscale ACLs are the current authentication boundary |
| Live refresh | iOS app while foregrounded | Broker event long-poll with a monotonic cursor | no arbitrary-LAN endpoint should be configured |
| Agent wake-up | per-Host `pharos-mesh node` | outbound Broker event stream, then guarded local `tmux capture-pane` + `send-keys` | the GUI has no tmux write path; the node runs as the tmux-owning user |
| Interactive control | iOS app to the member's Mac | Citadel PTY + SwiftTerm, resolving the reported pane to its exact tmux session | explicit target confirmation; same device-local key and host-key opt-in |
| Spawn member | selected member host | SSH command invoking that host's `pharos mesh spawn` | shared CLI owns hooks, tmux, launch flags, and join confirmation |
| Non-secret configuration | one iOS device | `UserDefaults` | Broker endpoint and Host profiles stay device-local |
| SSH private key | one iOS device | Keychain, `AfterFirstUnlockThisDeviceOnly` | never iCloud-synced |

The iOS wire structs intentionally mirror `PharosMeshCore`; all Pharos clients
and services are released as one protocol generation during rapid development.

## Deliberate boundaries

- iCloud is not used for live project or configuration synchronization.
- Broker and Host configuration are independent: the Broker coordinates; Hosts
  execute agents over SSH. A Host does not need to run the Broker.
- iOS suspends arbitrary sockets in the background. This version refreshes in
  the foreground; reliable background notifications require an APNs relay.
- The current desktop broker has no application token. Do not expose port
  `47800` to Wi-Fi or the public Internet.
- SSH host-key pinning is not yet wired. The app requires a per-host risk toggle
  before using Citadel's `acceptAnything()` validator, and should only connect
  through the private tailnet.
- The iOS app never pokes tmux over SSH. The Host node validates a numeric pane,
  the expected Claude/Codex process tree, and a visibly idle composer locally.
- Remote control shows the host, SSH user, member, and pane before attaching.
  Closing the full-screen terminal disconnects SSH.
- Mobile spawn delegates to the remote host's installed Pharos CLI; the iOS app
  deliberately does not duplicate desktop hook, keychain, or tmux bootstrap logic.

## References used

- Hetznerly (external sibling repo, read-only): XcodeGen configuration,
  Citadel Ed25519 authentication, and device-local Keychain identity design.
- Clawbox (external private GitHub repo, read-only): document-waterfall chat,
  `LazyVStack` transcript, multiline composer, and MarkdownUI rendering.
- Wick (external sibling repo, read-only): stable MarkdownUI wrapper and code
  block styling derived from Clawbox.

## UI dependency decision

- [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) 2.4.1 renders
  agent responses with the Clawbox document-waterfall treatment.
- [Exyte Chat](https://github.com/exyte/Chat) was evaluated, but Pharos does not
  need its media picker or generic message model. Native SwiftUI
  `ScrollView`/`LazyVStack`/`safeAreaInset` keeps agent state, Markdown, and poke
  feedback first-class and gives `NavigationSplitView` an uncomplicated iPad
  layout.
- [Citadel](https://github.com/orlandos-nl/Citadel) 0.12.1 provides SSH command
  execution using the same dependency and identity path as Hetznerly.
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.14.0 renders the
  interactive terminal; the Wellz26 NIOSSH fork matches Citadel's dependency.

## Build and test

```bash
cd ios
xcodegen generate
xcodebuild -project PharosMobile.xcodeproj \
  -scheme PharosMobile \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project PharosMobile.xcodeproj \
  -scheme PharosMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  CODE_SIGNING_ALLOWED=NO test
```

SSH keys are still required for interactive terminal attachment and remote
agent launch, but not for Mesh message delivery or Poke.

## Last verified

2026-07-14:

- ten Swift Testing cases passed on an iPhone 17 Pro Max simulator;
- the app built and launched on an iPad Air 13-inch simulator;
- interactive SSH/tmux and remote-spawn command paths compile under Swift 6
  strict concurrency; safety tests cover exact pane resolution and injection;
- a read-only TCP probe reached the live Tailscale-bound broker (`list`: three
  rooms), and both simulators rendered the live roster and transcript;
- the live probe exposed and regression-tested duplicate `who` rows for agents
  joined to multiple rooms.
