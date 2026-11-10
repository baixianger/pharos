//! Replica SQLite + Peer RPC surface used by S1 delivery and S2 host.runtime.call.
//!
//! `ReplicaHandle` is the stable interface other streams should depend on.

mod handle;
mod rpc;
mod runtime_client;
mod store;

pub use handle::{ReplicaHandle, ReplicaHandleConfig};
pub use rpc::{
    HostRuntimeCallRequest, HostRuntimeCallResponse, HostRuntimeHello, ReplicaRpcError,
    ReplicaRpcHeader, ReplicaSyncPullRequest, ReplicaSyncPullResponse, ReplicaSyncPushRequest,
    ReplicaSyncPushResponse, SyncedMessage,
};
pub use runtime_client::{RuntimeClient, RuntimeClientError};
pub use store::{DeviceIdentityRow, ReplicaStore, ReplicaStoreError, TrustGroupRow};
