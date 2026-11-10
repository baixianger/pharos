//! Mesh bridge hooks for `pharos-meshd` (RFC-007 S3).
//!
//! Merge captain: add `mod mesh_bridge;` in `main.rs` and call
//! `mesh_bridge::spawn_optional(...)` when mesh data-dir flags are present.
//! See `docs/wiring-mesh-iroh.md`.

#![allow(dead_code)]

use std::path::PathBuf;

/// Optional mesh bring-up configuration the captain can thread from CLI flags.
#[derive(Debug, Clone)]
pub struct MeshBridgeOptions {
    pub data_dir: PathBuf,
    pub runtime_socket: Option<PathBuf>,
    pub relay_disabled: bool,
}

/// Placeholder until captain wires `pharos-mesh` into the daemon binary graph.
/// Streams must not edit `main.rs`; this module documents the intended hook.
pub fn describe_wiring() -> &'static str {
    "mod mesh_bridge; // captain: spawn ReplicaHandle via pharos_mesh::open_handle"
}
