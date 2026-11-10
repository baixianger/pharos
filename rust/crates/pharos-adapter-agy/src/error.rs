use std::fmt;

/// Adapter-local error. Proposed for promotion beside `PharosApiError` in a
/// Phase 0.x contract bump (`SessionAdapter` surface).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdapterError {
    pub message: String,
}

impl AdapterError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for AdapterError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for AdapterError {}

impl From<String> for AdapterError {
    fn from(message: String) -> Self {
        Self { message }
    }
}

impl From<&str> for AdapterError {
    fn from(message: &str) -> Self {
        Self {
            message: message.to_owned(),
        }
    }
}
