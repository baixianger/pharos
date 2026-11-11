//! Callee-side host session contract for `host.session.query.v1` /
//! `host.session.action.v1`.
//!
//! `ReplicaHandle` owns the transport, trust-group/epoch checks and Peer
//! allowlist; the application layer (agent-runtime) plugs in a
//! [`HostSessionHandler`] that forwards to the local SessionService. Keeping the
//! trait here — not in `pharos-session` — avoids a dependency cycle and keeps
//! the daemon adapter thin: no Thread closed loop is implemented in this crate.

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;

use pharos_protocol::host_session::{
    HostSessionActionRequest, HostSessionActionResponse, HostSessionErrorBody,
    HostSessionErrorCode, HostSessionQueryRequest, HostSessionQueryResponse,
};

/// Failures a Host Session handler may report to a remote caller.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostSessionFault {
    /// Peer is not paired / not allowlisted (normally rejected before dispatch).
    Unauthorized(String),
    /// The addressed session does not exist on this host.
    UnknownSession(String),
    /// No live vendor adapter can serve the request.
    AdapterUnavailable(String),
    /// Malformed or unsupported request payload.
    InvalidRequest(String),
    /// The operation is not implemented on this host (e.g. `stop`).
    Unsupported(String),
    /// Unexpected local failure.
    Internal(String),
}

impl HostSessionFault {
    pub fn code(&self) -> HostSessionErrorCode {
        match self {
            Self::Unauthorized(_) => HostSessionErrorCode::Unauthorized,
            Self::UnknownSession(_) => HostSessionErrorCode::UnknownSession,
            Self::AdapterUnavailable(_) => HostSessionErrorCode::AdapterUnavailable,
            Self::InvalidRequest(_) => HostSessionErrorCode::InvalidRequest,
            Self::Unsupported(_) => HostSessionErrorCode::UnsupportedOperation,
            Self::Internal(_) => HostSessionErrorCode::Internal,
        }
    }

    pub fn message(&self) -> &str {
        match self {
            Self::Unauthorized(message)
            | Self::UnknownSession(message)
            | Self::AdapterUnavailable(message)
            | Self::InvalidRequest(message)
            | Self::Unsupported(message)
            | Self::Internal(message) => message,
        }
    }

    pub fn body(&self) -> HostSessionErrorBody {
        HostSessionErrorBody::new(self.code(), self.message())
    }
}

/// Application hook that serves cross-host session queries/actions from the
/// local SessionService.
///
/// Both methods are synchronous because the local `pharos_session::SessionService`
/// is synchronous; implementations must not perform network I/O.
pub trait HostSessionHandler: Send + Sync {
    fn query(
        &self,
        request: HostSessionQueryRequest,
    ) -> Result<HostSessionQueryResponse, HostSessionFault>;

    fn action(
        &self,
        request: HostSessionActionRequest,
    ) -> Result<HostSessionActionResponse, HostSessionFault>;
}

/// One capped audit line. Deliberately carries no message text, approval
/// identifiers or credentials: only routing and outcome metadata.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostSessionAudit<'a> {
    pub operation: &'a str,
    pub host_device_id: &'a str,
    pub remote_endpoint: &'a str,
    pub session_id: Option<&'a str>,
    pub outcome: &'a str,
}

impl HostSessionAudit<'_> {
    pub fn render(&self) -> String {
        format!(
            "operation={} host={} remote={} session={} outcome={}",
            self.operation,
            self.host_device_id,
            self.remote_endpoint,
            self.session_id.unwrap_or("-"),
            self.outcome,
        )
    }
}

/// Bounded replay cache for host session actions.
///
/// A retried action with the same idempotency key must not run twice. Same key
/// with a different body is a conflict (`invalid-request`), never a silent
/// second execution. Failures are not cached so callers may retry them.
pub struct ActionReplayCache {
    capacity: usize,
    order: VecDeque<String>,
    entries: HashMap<String, ReplayEntry>,
}

struct ReplayEntry {
    request: HostSessionActionRequest,
    response: HostSessionActionResponse,
}

/// Result of checking an action against the replay cache.
pub enum ReplayCheck {
    /// Not seen before: perform and then call [`ActionReplayCache::record`].
    Fresh,
    /// Exact same request already performed: return this response.
    Replayed(HostSessionActionResponse),
    /// Same idempotency key with a different body.
    Conflict(HostSessionFault),
}

impl ActionReplayCache {
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(1),
            order: VecDeque::new(),
            entries: HashMap::new(),
        }
    }

    pub fn check(&self, scope: &str, request: &HostSessionActionRequest) -> ReplayCheck {
        let Some(entry) = self
            .entries
            .get(&replay_key(scope, &request.idempotency_key))
        else {
            return ReplayCheck::Fresh;
        };
        if same_effect(&entry.request, request) {
            ReplayCheck::Replayed(entry.response.clone())
        } else {
            ReplayCheck::Conflict(HostSessionFault::InvalidRequest(
                "idempotencyKey reused with a different host session action".into(),
            ))
        }
    }

    pub fn record(
        &mut self,
        scope: &str,
        request: HostSessionActionRequest,
        response: HostSessionActionResponse,
    ) {
        let key = replay_key(scope, &request.idempotency_key);
        if self
            .entries
            .insert(key.clone(), ReplayEntry { request, response })
            .is_some()
        {
            return;
        }
        self.order.push_back(key);
        while self.order.len() > self.capacity {
            if let Some(evicted) = self.order.pop_front() {
                self.entries.remove(&evicted);
            }
        }
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// Scope is the requesting peer endpoint: idempotency keys are per peer, so one
/// peer cannot replay another peer's action. `\u{1f}` cannot appear in a
/// validated endpoint id / key.
/// Two actions have the same effect when they target the same host/session and
/// carry the same typed payload (`actionId` is deliberately ignored: retries
/// carry a fresh correlation id).
fn same_effect(a: &HostSessionActionRequest, b: &HostSessionActionRequest) -> bool {
    a.host_device_id == b.host_device_id && a.session_id == b.session_id && a.action == b.action
}

fn replay_key(scope: &str, idempotency_key: &str) -> String {
    format!("{scope}\u{1f}{idempotency_key}")
}

/// Process-wide replay cache guarded for the async dispatch loop.
pub(crate) type SharedActionReplayCache = Mutex<ActionReplayCache>;

#[cfg(test)]
mod tests {
    use super::*;
    use pharos_protocol::host_session::{HostSessionActionPayload, HostSessionErrorCode};

    fn request(key: &str, text: &str) -> HostSessionActionRequest {
        HostSessionActionRequest::new(
            "action-1",
            "host-b",
            "session-1",
            key,
            HostSessionActionPayload::SendMessage {
                text: text.into(),
                request_id: None,
            },
        )
    }

    #[test]
    fn replay_cache_replays_exact_retry_without_conflict() {
        let mut cache = ActionReplayCache::new(8);
        let request = request("idem-1", "hello");
        assert!(matches!(
            cache.check("peer-a", &request),
            ReplayCheck::Fresh
        ));
        let response = HostSessionActionResponse::new("action-1", "host-b", "session-1");
        cache.record("peer-a", request.clone(), response.clone());
        assert_eq!(cache.len(), 1);
        assert!(matches!(
            cache.check("peer-a", &request),
            ReplayCheck::Replayed(cached) if cached == response
        ));
    }

    #[test]
    fn replay_cache_replays_retry_with_new_action_correlation_id() {
        let mut cache = ActionReplayCache::new(8);
        let first = request("idem-1", "hello");
        let response = HostSessionActionResponse::new("action-1", "host-b", "session-1");
        cache.record("peer-a", first, response.clone());
        // A retry may use a fresh action id as long as the effect is identical.
        let mut retry = request("idem-1", "hello");
        retry.action_id = "action-2".into();
        assert!(matches!(
            cache.check("peer-a", &retry),
            ReplayCheck::Replayed(cached) if cached == response
        ));
    }

    #[test]
    fn replay_cache_does_not_replay_across_peers() {
        let mut cache = ActionReplayCache::new(8);
        cache.record(
            "peer-a",
            request("idem-1", "hello"),
            HostSessionActionResponse::new("action-1", "host-b", "session-1"),
        );
        assert!(matches!(
            cache.check("peer-b", &request("idem-1", "hello")),
            ReplayCheck::Fresh
        ));
    }

    #[test]
    fn replay_cache_rejects_key_reuse_with_different_body() {
        let mut cache = ActionReplayCache::new(8);
        cache.record(
            "peer-a",
            request("idem-1", "hello"),
            HostSessionActionResponse::new("action-1", "host-b", "session-1"),
        );
        let ReplayCheck::Conflict(fault) = cache.check("peer-a", &request("idem-1", "different"))
        else {
            panic!("expected conflict");
        };
        assert_eq!(fault.code(), HostSessionErrorCode::InvalidRequest);
    }

    #[test]
    fn replay_cache_is_bounded_and_evicts_oldest() {
        let mut cache = ActionReplayCache::new(2);
        for index in 0..3 {
            cache.record(
                "peer-a",
                request(&format!("idem-{index}"), "hi"),
                HostSessionActionResponse::new("action-1", "host-b", "session-1"),
            );
        }
        assert_eq!(cache.len(), 2);
        assert!(matches!(
            cache.check("peer-a", &request("idem-0", "hi")),
            ReplayCheck::Fresh
        ));
        assert!(matches!(
            cache.check("peer-a", &request("idem-2", "hi")),
            ReplayCheck::Replayed(_)
        ));
    }

    #[test]
    fn audit_line_carries_routing_only() {
        let audit = HostSessionAudit {
            operation: "host.session.action.v1",
            host_device_id: "host-b",
            remote_endpoint: "peer-endpoint",
            session_id: Some("session-1"),
            outcome: "ok",
        };
        let rendered = audit.render();
        assert!(rendered.contains("operation=host.session.action.v1"));
        assert!(rendered.contains("host=host-b"));
        assert!(rendered.contains("remote=peer-endpoint"));
        assert!(rendered.contains("session=session-1"));
        assert!(rendered.contains("outcome=ok"));
        // No user payload / credential material is part of the audit record.
        assert!(!rendered.contains("hello"));
        assert!(!rendered.contains("token"));
    }

    #[test]
    fn fault_codes_are_explicit() {
        assert_eq!(
            HostSessionFault::Unauthorized("nope".into()).code(),
            HostSessionErrorCode::Unauthorized
        );
        assert_eq!(
            HostSessionFault::UnknownSession("s".into()).code(),
            HostSessionErrorCode::UnknownSession
        );
        assert_eq!(
            HostSessionFault::AdapterUnavailable("none".into()).code(),
            HostSessionErrorCode::AdapterUnavailable
        );
        assert_eq!(
            HostSessionFault::Unsupported("stop".into()).code(),
            HostSessionErrorCode::UnsupportedOperation
        );
        assert_eq!(
            HostSessionFault::Internal("boom".into()).code(),
            HostSessionErrorCode::Internal
        );
    }
}
