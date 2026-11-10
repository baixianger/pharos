use thiserror::Error;

#[derive(Debug, Error)]
pub enum HitlError {
    #[error("{0}")]
    Message(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
}

impl HitlError {
    pub fn new(msg: impl Into<String>) -> Self {
        Self::Message(msg.into())
    }
}
