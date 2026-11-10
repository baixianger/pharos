//! Trait S4 (and the CLI) call for Thread operations.

use pharos_api::{
    ReplyThreadMessageRequest, ReplyThreadMessageResponse, SendThreadMessageRequest, ThreadMessage,
    ThreadSummary,
};

use crate::error::ThreadError;
use crate::{CliThreadMessage, ThreadReadPayload, ThreadReplyPayload};

/// Who is sending a non-reply Thread message (API / test harness).
#[derive(Debug, Clone)]
pub struct SenderIdentity {
    pub member_id: String,
    pub nick: String,
}

/// Service surface for Thread R/W. S4 mounts HTTP handlers on this trait;
/// S1 CLI talks to the same implementation.
pub trait ThreadService: Send + Sync {
    fn list_threads(&self) -> Result<Vec<ThreadSummary>, ThreadError>;

    fn get_thread(&self, thread: &str) -> Result<ThreadSummary, ThreadError>;

    fn list_messages(
        &self,
        thread: &str,
        limit: Option<u32>,
        since: Option<&str>,
    ) -> Result<Vec<ThreadMessage>, ThreadError>;

    fn send_message(
        &self,
        thread: &str,
        sender: &SenderIdentity,
        req: SendThreadMessageRequest,
    ) -> Result<ThreadMessage, ThreadError>;

    /// Product `replyOnce` (idempotent stable reply id).
    fn reply_message(
        &self,
        thread: &str,
        req: ReplyThreadMessageRequest,
    ) -> Result<ReplyThreadMessageResponse, ThreadError>;

    /// CLI `thread read` JSON shape (Swift parity).
    fn cli_read(
        &self,
        thread: &str,
        limit: Option<u32>,
        since: Option<&str>,
    ) -> Result<ThreadReadPayload, ThreadError>;

    /// CLI `thread reply` JSON shape (Swift parity).
    fn cli_reply(
        &self,
        thread: &str,
        as_member: &str,
        text: &str,
        message_id: Option<&str>,
    ) -> Result<ThreadReplyPayload, ThreadError>;

    /// History rows used by grokbot bridge (author member + reply linkage).
    fn history_for_bridge(
        &self,
        thread: &str,
        limit: u32,
    ) -> Result<Vec<CliThreadMessage>, ThreadError>;
}
