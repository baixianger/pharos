//! Replica SQLite + Peer RPC surface used by S1 delivery, S2 host.runtime.call
//! and cross-host session query/action.
//!
//! `ReplicaHandle` is the stable interface other streams should depend on.

mod handle;
mod host_session;
mod rpc;
mod runtime_client;
mod store;

pub use handle::{ReplicaHandle, ReplicaHandleConfig};
pub use host_session::{
    ActionReplayCache, HostSessionAudit, HostSessionFault, HostSessionHandler, ReplayCheck,
};
pub use pharos_iroh::{EndpointAddr, EndpointId, PeerDial};
pub use rpc::{
    HostRuntimeCallRequest, HostRuntimeCallResponse, HostRuntimeHello, ReplicaRpcError,
    ReplicaRpcHeader, ReplicaSyncPullRequest, ReplicaSyncPullResponse, ReplicaSyncPushRequest,
    ReplicaSyncPushResponse, SyncedMessage,
};
pub use runtime_client::{RuntimeClient, RuntimeClientError};
pub use store::{DeviceIdentityRow, ReplicaStore, ReplicaStoreError, TrustGroupRow};
