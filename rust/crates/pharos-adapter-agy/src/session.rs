//! `SessionAdapter` trait — **mirrored** from `pharos-codex-adapter` (S5a).
//!
//! Frozen contracts (`CONTRACTS_VERSION=0.1.0`) do not yet export this trait.
//! S5c mirrors the S5a shape so S2 can depend on either crate until a Phase 0.x
//! bump promotes the trait into `pharos-protocol` / `pharos-api`.

use crate::error::AdapterError;
use pharos_api::AdapterManifest;
use pharos_protocol::AdapterKind;
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PromptMode {
    Queue,
    Steer,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StartSessionRequest {
    pub workspace_path: String,
    pub model: Option<String>,
    /// `"yolo"` → `--dangerously-skip-permissions` on the ACP child.
    pub mode: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StartedSession {
    pub session_id: String,
    pub vendor_thread_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StartedTurn {
    pub session_id: String,
    pub turn_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnStatus {
    InProgress,
    Completed,
    Failed,
    Interrupted,
    Unknown,
}

impl TurnStatus {
    pub fn parse(raw: &str) -> Self {
        match raw {
            "inProgress" | "active" => Self::InProgress,
            "completed" | "end_turn" | "stop" => Self::Completed,
            "failed" | "error" => Self::Failed,
            "interrupted" | "cancelled" | "cancel" => Self::Interrupted,
            _ => Self::Unknown,
        }
    }

    pub fn from_stop_reason(stop_reason: &str) -> Self {
        match stop_reason {
            "end_turn" | "stop" | "completed" | "max_tokens" | "length" => Self::Completed,
            "cancelled" | "interrupted" | "cancel" => Self::Interrupted,
            "error" | "failed" | "refusal" => Self::Failed,
            "" => Self::Unknown,
            _ => Self::Unknown,
        }
    }

    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Interrupted)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TurnOutcome {
    pub turn_id: String,
    pub status: TurnStatus,
    /// Raw vendor status string (e.g. `"end_turn"`, `"cancelled"`).
    pub raw_status: String,
    pub assistant_text: String,
    /// Vendor turn error payload when present (message or JSON).
    pub vendor_error: Option<String>,
}

impl TurnOutcome {
    pub fn failure_detail(&self) -> String {
        format!(
            "turn_id={} status={:?} raw_status={} error={} assistant_preview={:?}",
            self.turn_id,
            self.status,
            self.raw_status,
            self.vendor_error.as_deref().unwrap_or("<none>"),
            self.assistant_text.chars().take(160).collect::<String>()
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InterruptOutcome {
    pub session_id: String,
    pub turn_id: Option<String>,
    /// Vendor turn status after interrupt (must not be [`TurnStatus::Completed`]).
    pub turn_status: Option<TurnStatus>,
}

/// Vendor session driver consumed by S2 (`dyn SessionAdapter`).
pub trait SessionAdapter: Send {
    fn kind(&self) -> AdapterKind;
    fn manifest(&self) -> AdapterManifest;

    fn start_session(
        &mut self,
        request: StartSessionRequest,
    ) -> Result<StartedSession, AdapterError>;

    fn send_prompt(
        &mut self,
        session_id: &str,
        prompt: &str,
        mode: PromptMode,
    ) -> Result<StartedTurn, AdapterError>;

    fn interrupt(&mut self, session_id: &str) -> Result<InterruptOutcome, AdapterError>;

    fn wait_turn(
        &mut self,
        session_id: &str,
        turn_id: &str,
        timeout: Duration,
    ) -> Result<TurnOutcome, AdapterError>;

    fn read_turns(&mut self, session_id: &str) -> Result<Vec<TurnOutcome>, AdapterError>;

    fn close(&mut self);
}
