use thiserror::Error;

#[derive(Debug, Error)]
pub enum ThreadError {
    #[error("thread not found: {0}")]
    NotFound(String),
    #[error("member not found: {0}")]
    MemberNotFound(String),
    #[error("reply target mismatch")]
    ReplyTargetMismatch,
    #[error("empty reply")]
    EmptyReply,
    #[error("reply conflict for {0}")]
    ReplyConflict(String),
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error("store: {0}")]
    Store(String),
}

impl From<rusqlite::Error> for ThreadError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Store(value.to_string())
    }
}

impl From<serde_json::Error> for ThreadError {
    fn from(value: serde_json::Error) -> Self {
        Self::Store(value.to_string())
    }
}
