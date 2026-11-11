//! Iroh transport and PHM1 stream framing for Pharos mesh.
//!
//! Wire constants match Swift `DistributedMeshProtocol` / `MeshStreamFrameCodec`
//! so Rust peers can speak the same ALPN and frame layout. Application RPC
//! headers use `pharos-protocol` operation IDs (Phase 0 contracts).

mod frame;
mod transport;

pub use frame::{
    FrameError, MeshStreamFrame, MeshStreamFrameKind, decode_frame, encode_frame, read_frame,
    write_frame,
};
pub use transport::{
    MeshIrohEndpoint, MeshIrohError, MeshTransportExchange, PHAROS_MESH_ALPN, PeerDial,
};

pub use iroh::{EndpointAddr, EndpointId, SecretKey};

/// Protocol version carried in application headers (Swift `DistributedMeshProtocol.version`).
pub const PROTOCOL_VERSION: u32 = 1;
