use thiserror::Error;

#[derive(Debug, Error)]
pub enum SessionError {
    #[error("{0}")]
    Message(String),
    #[error("adapter: {0}")]
    Adapter(String),
    #[error("goals: {0}")]
    Goals(#[from] pharos_goals::GoalsError),
    #[error("hitl: {0}")]
    Hitl(#[from] pharos_hitl::HitlError),
}

impl SessionError {
    pub fn new(msg: impl Into<String>) -> Self {
        Self::Message(msg.into())
    }
}
