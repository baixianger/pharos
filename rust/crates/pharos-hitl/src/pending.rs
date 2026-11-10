//! HITL pending state machine (webhook → injected → resolve | 45m fail).

use std::time::{Duration, Instant};

use crate::webhook::NotifyResult;

/// Reply / resolve timeout after webhook inject (seconds). Matches grokbot/HITL product rule.
pub const HITL_TIMEOUT_SECS: u64 = 45 * 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HitlDecision {
    /// Human approved once (maps to API `allowedOnce` / Codex `accept`).
    AllowedOnce,
    /// Human denied (maps to API `rejected` / Codex `decline`). Gate wording: denied.
    Denied,
}

impl HitlDecision {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AllowedOnce => "allowedOnce",
            Self::Denied => "denied",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        let lower = raw.trim().to_ascii_lowercase();
        match lower.as_str() {
            "allowedonce" | "allowed_once" | "accept" => Some(Self::AllowedOnce),
            "denied" | "rejected" | "decline" => Some(Self::Denied),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HitlState {
    /// Waiting to publish / notify.
    PendingPublish,
    /// Webhook HTTP 2xx — waiting for human resolve (not yet decided).
    Injected,
    /// Human resolved allow.
    AllowedOnce,
    /// Human resolved deny.
    Denied,
    /// 45m elapsed without resolve, or webhook failure prevented inject.
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HitlPending {
    pub approval_id: String,
    pub session_id: String,
    pub request_file_name: String,
    pub host: String,
    pub injected_at: Instant,
    pub state: HitlState,
    pub detail: String,
}

/// Clock abstraction so unit tests can advance past 45m without sleeping.
pub trait InstantClock: Send {
    fn now(&self) -> Instant;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct SystemClock;

impl InstantClock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// HITL bridge: record webhook inject, apply resolve, expire at 45m.
pub struct HitlBridge<C: InstantClock = SystemClock> {
    clock: C,
    timeout: Duration,
    pending: Option<HitlPending>,
}

impl Default for HitlBridge<SystemClock> {
    fn default() -> Self {
        Self::new(SystemClock, Duration::from_secs(HITL_TIMEOUT_SECS))
    }
}

impl<C: InstantClock> HitlBridge<C> {
    pub fn new(clock: C, timeout: Duration) -> Self {
        Self {
            clock,
            timeout,
            pending: None,
        }
    }

    pub fn pending(&self) -> Option<&HitlPending> {
        self.pending.as_ref()
    }

    /// Apply webhook notify result. Only `Posted` becomes [`HitlState::Injected`].
    pub fn apply_webhook_notify(
        &mut self,
        approval_id: impl Into<String>,
        session_id: impl Into<String>,
        request_file_name: impl Into<String>,
        host: impl Into<String>,
        notify: NotifyResult,
    ) -> HitlState {
        let approval_id = approval_id.into();
        let session_id = session_id.into();
        let request_file_name = request_file_name.into();
        let host = host.into();
        match notify {
            NotifyResult::Posted { status_code } => {
                let state = HitlState::Injected;
                self.pending = Some(HitlPending {
                    approval_id,
                    session_id,
                    request_file_name,
                    host,
                    injected_at: self.clock.now(),
                    state,
                    detail: format!("human-proxy webhook posted status={status_code}"),
                });
                state
            }
            NotifyResult::SkippedMissingConfig => {
                let state = HitlState::Failed;
                self.pending = Some(HitlPending {
                    approval_id,
                    session_id,
                    request_file_name,
                    host,
                    injected_at: self.clock.now(),
                    state,
                    detail: "human-proxy webhook env missing".into(),
                });
                state
            }
            NotifyResult::Failed(detail) => {
                let state = HitlState::Failed;
                self.pending = Some(HitlPending {
                    approval_id,
                    session_id,
                    request_file_name,
                    host,
                    injected_at: self.clock.now(),
                    state,
                    detail: format!("human-proxy webhook failed: {detail}"),
                });
                state
            }
        }
    }

    /// Resolve an injected request. Returns the new state, or error detail.
    pub fn resolve(
        &mut self,
        approval_id: &str,
        decision: HitlDecision,
    ) -> Result<HitlState, String> {
        let Some(pending) = self.pending.as_mut() else {
            return Err("no pending HITL request".into());
        };
        if pending.approval_id != approval_id {
            return Err(format!(
                "approval mismatch: pending={} got={approval_id}",
                pending.approval_id
            ));
        }
        if pending.state != HitlState::Injected {
            return Err(format!(
                "cannot resolve from state {:?} (need Injected)",
                pending.state
            ));
        }
        let state = match decision {
            HitlDecision::AllowedOnce => HitlState::AllowedOnce,
            HitlDecision::Denied => HitlState::Denied,
        };
        pending.state = state;
        pending.detail = format!("resolved decision={}", decision.as_str());
        Ok(state)
    }

    /// If still injected and past timeout → Failed.
    pub fn poll_timeout(&mut self) -> Option<HitlState> {
        let pending = self.pending.as_mut()?;
        if pending.state != HitlState::Injected {
            return Some(pending.state);
        }
        if self.clock.now().duration_since(pending.injected_at) >= self.timeout {
            pending.state = HitlState::Failed;
            pending.detail = "HITL resolve timeout (45m)".into();
            return Some(HitlState::Failed);
        }
        Some(HitlState::Injected)
    }

    pub fn clear(&mut self) {
        self.pending = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::webhook::NotifyResult;

    #[test]
    fn webhook_success_is_injected() {
        let mut bridge = HitlBridge::new(SystemClock, Duration::from_secs(HITL_TIMEOUT_SECS));
        let state = bridge.apply_webhook_notify(
            "a1",
            "s1",
            "req.md",
            "air",
            NotifyResult::Posted { status_code: 200 },
        );
        assert_eq!(state, HitlState::Injected);
        assert_eq!(bridge.pending().unwrap().state, HitlState::Injected);
    }

    #[test]
    fn resolve_allowed_once_and_denied() {
        let mut bridge = HitlBridge::default();
        bridge.apply_webhook_notify(
            "a1",
            "s1",
            "req.md",
            "air",
            NotifyResult::Posted { status_code: 200 },
        );
        assert_eq!(
            bridge.resolve("a1", HitlDecision::AllowedOnce).unwrap(),
            HitlState::AllowedOnce
        );

        let mut bridge = HitlBridge::default();
        bridge.apply_webhook_notify(
            "a2",
            "s1",
            "req.md",
            "air",
            NotifyResult::Posted { status_code: 200 },
        );
        assert_eq!(
            bridge.resolve("a2", HitlDecision::Denied).unwrap(),
            HitlState::Denied
        );
    }

    #[test]
    fn forty_five_minutes_timeout_branch() {
        use std::sync::{Arc, Mutex};
        struct SharedClock(Arc<Mutex<Instant>>);
        impl InstantClock for SharedClock {
            fn now(&self) -> Instant {
                *self.0.lock().unwrap()
            }
        }
        let shared = Arc::new(Mutex::new(Instant::now()));
        let mut bridge = HitlBridge::new(
            SharedClock(Arc::clone(&shared)),
            Duration::from_secs(HITL_TIMEOUT_SECS),
        );
        bridge.apply_webhook_notify(
            "a1",
            "s1",
            "req.md",
            "air",
            NotifyResult::Posted { status_code: 200 },
        );
        assert_eq!(bridge.poll_timeout(), Some(HitlState::Injected));
        *shared.lock().unwrap() += Duration::from_secs(HITL_TIMEOUT_SECS + 1);
        assert_eq!(bridge.poll_timeout(), Some(HitlState::Failed));
        assert_eq!(bridge.pending().unwrap().state, HitlState::Failed);
    }

    #[test]
    fn webhook_missing_config_is_failed_not_injected() {
        let mut bridge = HitlBridge::default();
        let state = bridge.apply_webhook_notify(
            "a1",
            "s1",
            "req.md",
            "air",
            NotifyResult::SkippedMissingConfig,
        );
        assert_eq!(state, HitlState::Failed);
    }
}
