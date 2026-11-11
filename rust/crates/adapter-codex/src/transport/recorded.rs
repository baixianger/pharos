use super::AppServerTransport;
use crate::error::AdapterError;
use serde_json::Value;
use std::collections::{HashMap, VecDeque};

/// One request captured by [`RecordedAppServer`].
#[derive(Debug, Clone, PartialEq)]
pub struct RecordedRequest {
    pub id: Value,
    pub method: String,
    pub params: Value,
}

/// Scripted in-memory App Server transport for recorded / synthetic tests.
///
/// Each RPC method maps to one canned JSON result (or a canned error). Requests
/// are captured so tests can assert on `turn/start` / `thread/read` shapes.
/// Never spawns or talks to a live Codex process, and no network access.
#[derive(Debug, Default)]
pub struct RecordedAppServer {
    responses: HashMap<String, Value>,
    errors: HashMap<String, String>,
    notifications: VecDeque<Value>,
    requests: Vec<RecordedRequest>,
    closed: bool,
}

impl RecordedAppServer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Script the successful result for `method`.
    pub fn respond(mut self, method: impl Into<String>, response: Value) -> Self {
        self.responses.insert(method.into(), response);
        self
    }

    /// Script an App Server error (JSON-RPC `error.message`) for `method`.
    pub fn respond_error(mut self, method: impl Into<String>, message: impl Into<String>) -> Self {
        self.errors.insert(method.into(), message.into());
        self
    }

    /// Queue one app-server notification returned by `take_notifications`.
    pub fn with_notification(mut self, notification: Value) -> Self {
        self.notifications.push_back(notification);
        self
    }

    /// Every request the adapter issued, in order.
    pub fn requests(&self) -> &[RecordedRequest] {
        &self.requests
    }

    /// Last captured request for `method`, if any.
    pub fn request_for(&self, method: &str) -> Option<&RecordedRequest> {
        self.requests
            .iter()
            .rev()
            .find(|request| request.method == method)
    }

    pub fn methods(&self) -> Vec<&str> {
        self.requests
            .iter()
            .map(|request| request.method.as_str())
            .collect()
    }

    pub fn is_closed(&self) -> bool {
        self.closed
    }
}

impl AppServerTransport for RecordedAppServer {
    fn request(&mut self, id: Value, method: &str, params: Value) -> Result<Value, AdapterError> {
        self.requests.push(RecordedRequest {
            id,
            method: method.to_owned(),
            params,
        });
        if let Some(message) = self.errors.get(method) {
            return Err(AdapterError::new(message.clone()));
        }
        self.responses.get(method).cloned().ok_or_else(|| {
            AdapterError::new(format!(
                "recorded transport has no scripted response for `{method}`"
            ))
        })
    }

    fn take_notifications(&mut self) -> Vec<Value> {
        self.notifications.drain(..).collect()
    }

    fn close(&mut self) {
        self.closed = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn serves_scripted_responses_and_records_requests() {
        let mut server = RecordedAppServer::new()
            .respond("thread/read", json!({"thread": {"id": "t1"}}))
            .respond_error("turn/start", "no rollout found")
            .with_notification(json!({"method": "turn/completed", "params": {}}));
        assert_eq!(
            server
                .request(json!("r1"), "thread/read", json!({"threadId": "t1"}))
                .expect("scripted response"),
            json!({"thread": {"id": "t1"}})
        );
        let error = server
            .request(json!("r2"), "turn/start", json!({}))
            .expect_err("scripted error");
        assert_eq!(error.message, "no rollout found");
        let missing = server
            .request(json!("r3"), "thread/list", json!({}))
            .expect_err("unscripted method");
        assert!(missing.message.contains("thread/list"));
        assert_eq!(
            server.methods(),
            ["thread/read", "turn/start", "thread/list"]
        );
        assert_eq!(server.requests().len(), 3);
        assert_eq!(
            server.request_for("thread/read").map(|r| &r.params),
            Some(&json!({"threadId": "t1"}))
        );
        assert_eq!(server.take_notifications().len(), 1);
        assert!(server.take_notifications().is_empty());
        assert!(!server.is_closed());
        server.close();
        assert!(server.is_closed());
    }
}
