---
summary: Swift FileHandle.read(upToCount:) returns nil at EOF; treat it as completion, and use a short Unix socket path in the CLI integration test.
---

# Host reply stdin and test socket

- Phenomenon: an isolated real Codex turn completed but its host reply was never committed; a subsequent CLI integration probe initially could not connect to its test Broker.
- Environment: macOS host, SwiftPM project in Swift language mode 5, `pharos-mesh` debug build; Codex CLI 0.166.0, Rust Runtime in this worktree.
- Attempts: compared the previously successful live run to the new bounded stdin reader; reproduced with a real `pharos-mesh host-reply` child and Broker.
- Evidence: `internal/evidence/2026-11-07_codex-host-relay-final.log` failed before reply; `internal/evidence/2026-11-07_codex-host-relay-final-verified.log` passed after the fix. The dedicated `MeshRuntimeRoutingTests/testHostReplyCLIReadsRequestToEOF` now exercises the child process and verifies the reply in Broker history.
- Root cause: `FileHandle.read(upToCount:)` produced nil at EOF, which the new loop treated as an error. The first CLI test also used a temporary socket path longer than `sockaddr_un` permits; using a short task-owned scratch path resolved the instrument failure.
- Boundary: the successful local test does not verify remote routing, distributed Mesh, crash recovery, or every Foundation implementation. The earlier live run alone did not establish the cause; the process-level test and corrected rerun provide the useful evidence.
