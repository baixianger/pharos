mod daemon_proxy;
mod stdio;

pub use daemon_proxy::DaemonProxyAppServer;
pub use stdio::StdioAppServer;

use crate::error::AdapterError;
use serde_json::Value;
use std::collections::VecDeque;

/// Low-level Codex App Server JSON-RPC transport.
pub trait AppServerTransport: Send {
    fn request(&mut self, id: Value, method: &str, params: Value) -> Result<Value, AdapterError>;

    fn take_notifications(&mut self) -> Vec<Value>;

    fn close(&mut self);
}

/// Concrete transport handle (avoids `dyn` + generic-method issues).
pub enum CodexTransport {
    Stdio(StdioAppServer),
    DaemonProxy(DaemonProxyAppServer),
}

impl AppServerTransport for CodexTransport {
    fn request(&mut self, id: Value, method: &str, params: Value) -> Result<Value, AdapterError> {
        match self {
            Self::Stdio(inner) => inner.request(id, method, params),
            Self::DaemonProxy(inner) => inner.request(id, method, params),
        }
    }

    fn take_notifications(&mut self) -> Vec<Value> {
        match self {
            Self::Stdio(inner) => inner.take_notifications(),
            Self::DaemonProxy(inner) => inner.take_notifications(),
        }
    }

    fn close(&mut self) {
        match self {
            Self::Stdio(inner) => inner.close(),
            Self::DaemonProxy(inner) => inner.close(),
        }
    }
}

pub(crate) const MAX_PENDING_NOTIFICATIONS: usize = 1_024;

pub(crate) fn capture_notification_into(
    queue: &mut VecDeque<Value>,
    message: &Value,
    limit: usize,
) {
    if message.get("method").and_then(Value::as_str).is_none() || message.get("id").is_some() {
        return;
    }
    if queue.len() == limit {
        let _ = queue.pop_front();
    }
    queue.push_back(message.clone());
}

pub(crate) fn response_result(
    message: &Value,
    expected_id: &Value,
) -> Result<Option<Value>, AdapterError> {
    if message.get("id") != Some(expected_id) {
        return Ok(None);
    }
    if let Some(error) = message.get("error") {
        let detail = error
            .get("message")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .unwrap_or_else(|| error.to_string());
        return Err(AdapterError::new(detail));
    }
    Ok(Some(message.get("result").cloned().unwrap_or(Value::Null)))
}
