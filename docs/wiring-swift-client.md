# Wiring notes — Stream S6 swift-client

Merge captain owns `Package.swift`, packaging, and any Mesh/Protocol repairs.
This stream added a **wiring-local** `Package.swift` hunk so ClientKit-only tests
can build without the broken tip Mesh stack. Reconcile or keep as needed.

## Feature flag (product)

| Knob | Values | Default |
|---|---|---|
| Env `PHAROS_CLIENT_BACKEND` | `rust-api` \| `desktop-mesh` | `rust-api` |
| UserDefaults `pharos.clientBackend` | same | (unset → rust-api) |
| Env `PHAROS_API_BASE_URL` | URL | `http://127.0.0.1:8787` |
| UserDefaults `pharos.apiBaseURL` | URL string | same default |

Composition: `Sources/Pharos/ContentView.swift` (wiring-local touch) selects
`HttpPharosClientService` vs `DesktopPharosClientService` via
`PharosClientBackend.usesRustAPI`.

## `Package.swift` hunk already applied (wiring-local)

```swift
        // wiring-local (S6): ClientKit-only tests so ArchitectureBoundary + HTTP smoke
        // can run without building MeshCore/Runtime (tip Mesh stack incomplete).
        .testTarget(
            name: "PharosClientKitTests",
            dependencies: ["PharosClientKit"],
            path: "Tests/PharosClientKitTests"
        ),
```

Optional later (Phase E): drop `PharosMeshCore` / `PharosRuntime` from the
`Pharos` app target dependencies once `desktop-mesh` is deleted.

## Pre-existing tip break — captain must restore Mesh build

At `rust/integrate-b2` tip `9b5434f`, `swift build --target Pharos` fails before
any S6 UI code is compiled:

1. Missing `Sources/PharosMeshProtocol/HostSessionSchema.swift`
   (untracked copy exists on the main checkout WD at
   `~/personal/pharos/Sources/PharosMeshProtocol/HostSessionSchema.swift`,
   defining `MeshHostSessionQuery/Action/Events` request/response types).
2. After restoring that file, further errors remain in
   `Sources/PharosMeshCore/DistributedMeshLocalRuntimeCommands.swift`
   (`sessionRPC` / `DistributedMeshSessionRPCRequest` missing).

S6 **must not** edit `PharosMesh*` / `PharosRuntime`. Captain should land the
missing Protocol schema (and any Core follow-ups) on the integration branch so
`swift build --target Pharos` and `swift test --filter ArchitectureBoundary`
(PharosTests) become runnable again.

## Web UI asset sync

S6 updated `Sources/Pharos/Resources/WebCanvas/dsh-stream.js` (fetch for
approvals/history). S4 serves repo-root `webui/` by default — captain should
re-copy WebCanvas → `webui/` (or point `PHAROS_WEBUI_DIR` at Sources WebCanvas)
so daemon-served JS matches the fetch cutover.

## Suggested PharosTests filter (after Mesh tip fixed)

```sh
swift test --filter ArchitectureBoundary
```

Until then, use ClientKit-only:

```sh
swift build --target PharosClientKit
swift build --target PharosClientKitTests
xcrun xctest -XCTest ArchitectureBoundaryClientKitTests \
  .build/out/Products/Debug/PharosClientKitTests.xctest
```
