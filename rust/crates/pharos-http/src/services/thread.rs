//! Thread service trait — owned by S1 (`pharos-thread`); S4 only mounts it.

use async_trait::async_trait;
use pharos_api::{
    PharosApiError, ReplyThreadMessageRequest, ReplyThreadMessageResponse,
    SendThreadMessageRequest, ThreadMessage, ThreadSummary,
};

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
}
