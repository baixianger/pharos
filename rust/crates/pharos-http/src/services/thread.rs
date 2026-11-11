//! Thread service trait — owned by S1 (`pharos-thread`); S4 only mounts it.

use async_trait::async_trait;
use pharos_api::{
    PharosApiError, ReplyThreadMessageRequest, ReplyThreadMessageResponse,
    SendThreadMessageRequest, ThreadMessage, ThreadSummary,
};
use serde::{Deserialize, Serialize};

/// `POST /api/v1/threads` body — create (or return) a durable Thread.
///
/// `thread_id` doubles as the Thread display title (PHASE0 `rooms.name`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateThreadRequest {
    pub thread_id: String,
    /// Members to join immediately (e.g. `["human", "grokbot"]`). When empty,
    /// the server joins its default sender identity only.
    #[serde(default)]
    pub member_ids: Vec<String>,
}

/// S1 thread read/reply surface used by HTTP handlers.
#[async_trait]
pub trait ThreadService: Send + Sync {
    async fn list_threads(&self) -> Result<Vec<ThreadSummary>, PharosApiError>;

    async fn get_thread(&self, thread_id: &str) -> Result<ThreadSummary, PharosApiError>;

    async fn list_messages(&self, thread_id: &str) -> Result<Vec<ThreadMessage>, PharosApiError>;

    async fn send_message(
        &self,
        thread_id: &str,
        request: SendThreadMessageRequest,
    ) -> Result<ThreadMessage, PharosApiError>;

    async fn reply(
        &self,
        thread_id: &str,
        request: ReplyThreadMessageRequest,
    ) -> Result<ReplyThreadMessageResponse, PharosApiError>;

    /// Create a durable Thread. Idempotent: an existing Thread id is reused and
    /// requested members are joined if they are not already present.
    ///
    /// Default: services that cannot create threads must report an explicit
    /// error rather than pretend success.
    async fn create_thread(
        &self,
        _request: CreateThreadRequest,
    ) -> Result<ThreadSummary, PharosApiError> {
        Err(PharosApiError::OperationFailed {
            message: "thread creation is not supported by this service".into(),
        })
    }
}
