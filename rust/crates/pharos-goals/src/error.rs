use thiserror::Error;

#[derive(Debug, Error)]
pub enum GoalsError {
    #[error("{0}")]
    Message(String),
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

impl GoalsError {
    pub fn new(msg: impl Into<String>) -> Self {
        Self::Message(msg.into())
    }
}
