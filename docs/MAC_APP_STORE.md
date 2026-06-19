# Pharos — Mac App Store Build Variant

Pharos ships two builds from one source tree:

| Build | How | Distribution | Sandbox |
|-------|-----|--------------|---------|
| **Full** (default) | `swift build` | Developer ID direct + Sparkle | No |
| **Mac App Store (MAS)** | `swift build -Xswiftc -DAPP_STORE` | Mac App Store | Yes |

The MAS build is a sandboxed subset of the full app. Every capability that Apple's
App Review forbids in a sandboxed app is gated behind `#if !APP_STORE`, with a
compiling stub under `#if APP_STORE`. The default build is byte-for-byte unchanged —
all gating is additive and only takes effect when `-DAPP_STORE` is passed.

---

## Building

```sh
# Full build (default — unchanged behavior)
swift build
swift test

# Mac App Store variant
swift build -Xswiftc -DAPP_STORE

# Packaged .app (sandboxed, signed with the sandbox entitlements)
APP_STORE=1 ./Scripts/package_app.sh
```

`APP_STORE=1` makes `Scripts/package_app.sh`:
1. pass `-Xswiftc -DAPP_STORE` to every `swift build` invocation, and
2. sign the bundle with `Pharos-AppStore.entitlements` (App Sandbox) instead of the
   empty default entitlements.

Without `APP_STORE=1` the script behaves exactly as before.

---

## What is disabled in the MAS build, and why

A sandboxed App Store app may not use private system APIs, may not spawn
subprocesses, and may only read files the user explicitly selects. That removes
most of what makes the full Pharos useful, so those features are simply absent
from the MAS build (not stubbed-but-visible — the UI hides them).

| Capability | File(s) | Why it's forbidden | MAS behavior |
|------------|---------|--------------------|--------------|
| **Space switching** | `SpacesService.swift`, `ProjectDetailView` desktop picker | Private SkyLight/CGS `@_silgen_name` symbols (`CGSMainConnectionID`, `CGSManagedDisplaySetCurrentSpace`, …) | `spaceCount() → 1`, `switchToDesktop` is a no-op; desktop picker hidden |
| **Process / shell spawning** | `Services.swift` (`Shell.run`, `LaunchService`, `GitService`, `PeerService`, `GitHubService`) | Sandbox forbids `Process` / `posix_spawn` | `Shell.run` returns an "unavailable" failure; all git/ssh/gh/agent/terminal/tmux features degrade to empty / no-op and are hidden in the UI |
| **Launch agents (Claude/Codex), open terminal, tmux** | `ProjectDetailView`, `MenuBarView`, `CommandPalette` | Spawns `claude`/`codex`/`open`/`osascript`/`tmux` | Buttons / quick-actions hidden |
| **Git tab** (status, heatmap, worktrees) | `ProjectDetailView` | Runs `git` subprocesses | Whole Git tab omitted |
| **Sessions tab** (Claude/Codex history) | `SessionsService.swift`, `ProjectDetailView` | Reads `~/.claude` & `~/.codex` (outside the sandbox container) | `claudeSessions`/`codexSessions → []`; Sessions tab omitted |
| **Peer machine (SSH)** | `Services.swift` (`PeerService`), Integrations settings | Spawns `ssh` | Peer card + settings omitted |
| **GitHub import / status** | `GitHubImportSheet.swift`, `Services.swift` (`GitHubService`) | Shells out to the `gh` CLI | Import menu item, import sheet, and GitHub status card omitted |
| **Playbooks (run)** | `ProjectDetailView` | Runs arbitrary commands in a terminal | Playbooks card omitted |
| **MCP server** | `MCPServer.swift`, `PharosApp.swift` `--mcp` dispatch | A MAS app can't launch agents on behalf of another tool | `MCPServer` compiled out; `PharosMain.main()` always runs the GUI; Integrations/MCP settings omitted |
| **Sparkle auto-update** | `Updater.swift`, `PharosApp.swift` | The App Store delivers updates; bundling Sparkle (which downloads + launches its own updater) is forbidden | `UpdaterController` stubbed (no Sparkle types); "Check for Updates…" command omitted |
| **Running-agent / external-edit polling** | `ProjectStore.swift` | Polls `tmux` (subprocess); reacts to MCP writes | Poller not started |

### What still works in the MAS build

The detail view still shows the project, its tags/path, the **Notes** editor, and the
clone-prompt card for GitHub-only projects. Two sandbox-legal actions remain in every
build because they go through `NSWorkspace`, not a subprocess:

- **Reveal in Finder** — `NSWorkspace.activateFileViewerSelecting`
- **Open in Editor** — `NSWorkspace.open(…withApplicationAt:)` (resolved by bundle id;
  see `EditorApp.bundleID`). The full build keeps using `open -a` as before.

Adding projects (local folder via the open panel) and managing groups also work.

---

## Remaining MANUAL steps for an actual App Store submission

The gating above makes the MAS variant **compile and run sandboxed**. It does **not**
make it submittable on its own. Before uploading to App Store Connect you still must:

1. **Remove the Sparkle SPM dependency from `Package.swift`.** Gating its *usage* is
   enough to compile the MAS binary, but the dependency is still resolved and the
   `Sparkle.framework` is still embeddable. A real MAS binary must not contain Sparkle
   at all. Drop the `.package(url: …/Sparkle…)` line and the `.product(name: "Sparkle", …)`
   target dependency for the App Store target (e.g. a separate `Package.swift` /
   `Package@swift` variant, or an Xcode project — see next point).
2. **Create an Xcode project / archive for upload.** SwiftPM cannot produce a
   `.pkg`/App-Store `.ipa`-equivalent or run the App Store distribution flow. Wrap the
   package in an Xcode project (or `xcodebuild -create-xcframework` + an app target),
   set the `APP_STORE` compilation condition (Swift Active Compilation Conditions →
   `APP_STORE`), archive, and use **Xcode → Organizer → Distribute App → App Store
   Connect** (or `xcodebuild -exportArchive`).
3. **App Sandbox provisioning profile.** Create a Mac App Store provisioning profile
   and a distribution certificate in your Apple Developer account, and sign with
   `Pharos-AppStore.entitlements` (App Sandbox enabled). The bundle id must match the
   App Store Connect record.
4. **Accept that core features are intentionally absent.** Agent launching, git, SSH
   peer status, GitHub import, sessions, Spaces switching, and the MCP server are gone
   from the MAS build by design. Make the App Store listing describe the MAS app for
   what it is (a project catalog with Finder/editor shortcuts and notes), and keep the
   full-power app on Developer ID direct download.
