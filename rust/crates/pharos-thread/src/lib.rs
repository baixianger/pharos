//! Thread R/W for RFC-007 stream S1.
//!
//! Owns the `ThreadService` trait that S4 (web/API) mounts, plus a local
//! SQLite store on `pharos-store-schema` PHASE0 tables. Does not own HTTP or
//! iroh — those are S4 / S3.

mod error;
mod reply;
mod service;
mod store;

pub use error::ThreadError;
pub use reply::{REPLY_ONCE_SCOPE_LOCAL, reply_once_id};
pub use service::{SenderIdentity, ThreadService};
pub use store::{SqliteThreadStore, StoredMessage, open_thread_db, resolve_db_path};

/// CLI-facing thread read payload (parity with Swift `pharos-mesh thread read`).
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadReadPayload {
    pub thread: String,
    pub member: String,
    pub nick: String,
    pub messages: Vec<CliThreadMessage>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CliThreadMessage {
    pub id: String,
    pub thread: String,
    pub from: String,
    #[serde(rename = "memberID")]
    pub member_id: String,
    pub text: String,
    pub ts: f64,
    pub to: Vec<String>,
    #[serde(rename = "targetMemberIDs")]
    pub target_member_ids: Vec<String>,
    #[serde(rename = "replyTo", skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<CliReplyTo>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CliReplyTo {
    #[serde(rename = "messageID")]
    pub message_id: String,
    pub from: String,
    pub preview: String,
}

/// CLI-facing reply payload (parity with Swift `pharos-mesh thread reply`).
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ThreadReplyPayload {
    pub ok: bool,
    pub thread: String,
    #[serde(rename = "as")]
    pub as_member: String,
    #[serde(rename = "replyID")]
    pub reply_id: String,
    #[serde(rename = "replyTo")]
    pub reply_to: String,
}
