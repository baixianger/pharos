//! Session / HITL / Goal service trait — owned by S2; S4 only mounts it.

use async_trait::async_trait;
use pharos_api::{
    CanonicalTurn, HostInventorySnapshot, PharosApiError, ProjectSummary, ResolveApprovalRequest,
    SendSessionMessageRequest, SessionProgress, SessionSummary, SteerSessionRequest,
};
use pharos_hitl::{QuestionnaireAnswer, StoredDecision};
use serde::{Deserialize, Serialize};

/// Validation bound for a session model id.
pub const MAX_SESSION_MODEL_LEN: usize = 120;
/// Accepted session mode values (safe = approvals on-request, yolo = never).
pub const SESSION_MODES: [&str; 2] = ["safe", "yolo"];
/// Prefix of `PharosApiError::OperationFailed` messages that the HTTP layer
/// maps to the extension `unsupportedField` error (502).
pub const UNSUPPORTED_FIELD_PREFIX: &str = "unsupported field `";
/// Prefix of `PharosApiError::OperationFailed` messages that the HTTP layer
/// maps to the extension `unsupportedOperation` error (502).
pub const UNSUPPORTED_OPERATION_PREFIX: &str = "unsupported operation `";

/// An honestly-unsupported session configuration field.
pub fn unsupported_field(field: &str, reason: impl std::fmt::Display) -> PharosApiError {
    PharosApiError::OperationFailed {
        message: format!("{UNSUPPORTED_FIELD_PREFIX}{field}`: {reason}"),
    }
}

/// An honestly-unsupported session operation.
pub fn unsupported_operation(operation: &str, reason: impl std::fmt::Display) -> PharosApiError {
    PharosApiError::OperationFailed {
        message: format!("{UNSUPPORTED_OPERATION_PREFIX}{operation}`: {reason}"),
    }
}

/// `GET/PATCH /api/v1/sessions/{id}/config` response.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionConfigView {
    pub session_id: String,
    /// Whether the configured adapter exposes any configuration at all.
    pub supported: bool,
    /// Field ids the adapter can read/write (`model`, `mode`, …).
    pub supported_fields: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
    pub models: Vec<String>,
    pub modes: Vec<ConfigModeOption>,
    pub capabilities: SessionCapabilities,
    /// True when writes are impossible (nothing to change, or view-only).
    pub readonly: bool,
}

impl SessionConfigView {
    /// Honest empty view for adapters that cannot report configuration.
    pub fn unsupported(session_id: &str) -> Self {
        Self {
            session_id: session_id.to_string(),
            supported: false,
            supported_fields: Vec::new(),
            model: None,
            mode: None,
            models: Vec::new(),
            modes: Vec::new(),
            capabilities: SessionCapabilities::default(),
            readonly: true,
        }
    }
}

/// One selectable session mode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigModeOption {
    pub value: String,
    pub name: String,
}

/// The two standard modes, for services that can report a mode control.
pub fn standard_modes() -> Vec<ConfigModeOption> {
    vec![
        ConfigModeOption {
            value: "safe".into(),
            name: "Safe".into(),
        },
        ConfigModeOption {
            value: "yolo".into(),
            name: "YOLO".into(),
        },
    ]
}

/// Honest capability flags surfaced to the UI (controls stay disabled when
/// false; the server answers explicit errors rather than pretending).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionCapabilities {
    pub attachments: bool,
    pub commands: bool,
    pub stop: bool,
    pub revive: bool,
}

/// `PATCH /api/v1/sessions/{id}/config` body.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionConfigPatch {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
}

impl SessionConfigPatch {
    pub fn is_empty(&self) -> bool {
        self.model.is_none() && self.mode.is_none()
    }

    /// Validate the patch without touching any adapter state.
    pub fn validate(&self) -> Result<(), String> {
        if self.is_empty() {
            return Err("configuration patch must set at least one field".into());
        }
        if let Some(model) = &self.model {
            let model = model.trim();
            if model.is_empty() {
                return Err("model must not be blank".into());
            }
            if model.chars().count() > MAX_SESSION_MODEL_LEN {
                return Err(format!(
                    "model must be at most {MAX_SESSION_MODEL_LEN} chars"
                ));
            }
        }
        if let Some(mode) = &self.mode
            && !SESSION_MODES.contains(&mode.trim())
        {
            return Err(format!(
                "mode must be one of {:?}, got {mode:?}",
                SESSION_MODES
            ));
        }
        Ok(())
    }
}

/// `POST /api/v1/sessions/{id}/stop|revive` response.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionLifecycleResponse {
    pub ok: bool,
    pub session_id: String,
    pub status: String,
}

/// `POST /api/v1/sessions` body — start a live vendor session.
///
/// Only usable when the server was started with a live session adapter
/// (`--session-adapter codex`); otherwise the service returns an explicit
/// unavailable error.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateSessionRequest {
    pub workspace_path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
}

/// S2 session + inventory + projects surface used by HTTP handlers.
#[async_trait]
pub trait SessionService: Send + Sync {
    async fn list_sessions(&self) -> Result<Vec<SessionSummary>, PharosApiError>;

    async fn get_session(&self, session_id: &str) -> Result<SessionSummary, PharosApiError>;

    async fn list_history(&self, session_id: &str) -> Result<Vec<CanonicalTurn>, PharosApiError>;

    async fn send_message(
        &self,
        session_id: &str,
        request: SendSessionMessageRequest,
    ) -> Result<CanonicalTurn, PharosApiError>;

    async fn steer(
        &self,
        session_id: &str,
        request: SteerSessionRequest,
    ) -> Result<(), PharosApiError>;

    async fn resolve_approval(
        &self,
        session_id: &str,
        request: ResolveApprovalRequest,
    ) -> Result<(), PharosApiError>;

    async fn progress(&self, session_id: &str) -> Result<SessionProgress, PharosApiError>;

    async fn list_projects(&self) -> Result<Vec<ProjectSummary>, PharosApiError>;

    async fn inventory(&self) -> Result<HostInventorySnapshot, PharosApiError>;

    /// Start a live session through the configured vendor adapter.
    ///
    /// Default: explicit unavailable error (never a fabricated session).
    async fn create_session(
        &self,
        _request: CreateSessionRequest,
    ) -> Result<SessionSummary, PharosApiError> {
        Err(PharosApiError::OperationFailed {
            message: "session creation is not supported by this service".into(),
        })
    }

    /// Read the session configuration (model/mode and supported capabilities).
    ///
    /// Default: explicit error — a service that cannot read configuration must
    /// not invent a model/mode.
    async fn session_config(&self, session_id: &str) -> Result<SessionConfigView, PharosApiError> {
        Err(unsupported_operation(
            "config",
            format!(
                "no session configuration is available for {session_id}: \
                 the configured session service does not expose one"
            ),
        ))
    }

    /// Apply a configuration patch.
    ///
    /// Default: explicit unsupported error per field; never a fake save.
    async fn update_session_config(
        &self,
        _session_id: &str,
        patch: SessionConfigPatch,
    ) -> Result<SessionConfigView, PharosApiError> {
        if let Some(field) = patch
            .model
            .as_ref()
            .map(|_| "model")
            .or_else(|| patch.mode.as_ref().map(|_| "mode"))
        {
            return Err(unsupported_field(
                field,
                "the configured session service cannot update session configuration",
            ));
        }
        Err(PharosApiError::InvalidRequest {
            message: "configuration patch must set at least one field".into(),
        })
    }

    /// Stop a live session.
    ///
    /// Default: explicit unsupported operation (no adapter advertises stop).
    async fn stop_session(
        &self,
        _session_id: &str,
    ) -> Result<SessionLifecycleResponse, PharosApiError> {
        Err(unsupported_operation(
            "stop",
            "the configured session adapter does not support stopping sessions",
        ))
    }

    /// Revive a stopped session.
    ///
    /// Default: explicit unsupported operation (no adapter advertises revive).
    async fn revive_session(
        &self,
        _session_id: &str,
    ) -> Result<SessionLifecycleResponse, PharosApiError> {
        Err(unsupported_operation(
            "revive",
            "the configured session adapter does not support reviving sessions",
        ))
    }

    /// Send a message that references previously uploaded attachment ids.
    ///
    /// Default: explicit unsupported field — the adapter cannot consume
    /// attachments, so the message must not be reported as sent.
    async fn send_message_with_attachments(
        &self,
        _session_id: &str,
        _request: SendSessionMessageRequest,
        _attachment_ids: Vec<String>,
    ) -> Result<CanonicalTurn, PharosApiError> {
        Err(unsupported_field(
            "attachments",
            "the configured session adapter does not accept attachments",
        ))
    }

    /// Resolve an approval with the extended decision model (`cancelled`,
    /// questionnaire answers).
    ///
    /// Default: legacy decisions map onto [`Self::resolve_approval`]; the
    /// `cancelled` decision has no frozen representation and is reported as
    /// unsupported instead of being silently turned into `rejected`.
    async fn resolve_approval_decision(
        &self,
        session_id: &str,
        approval_id: &str,
        decision: StoredDecision,
        _answers: Option<&[QuestionnaireAnswer]>,
    ) -> Result<(), PharosApiError> {
        match decision.to_api() {
            Some(decision) => {
                self.resolve_approval(
                    session_id,
                    ResolveApprovalRequest {
                        approval_id: approval_id.to_string(),
                        decision,
                    },
                )
                .await
            }
            None => Err(unsupported_operation(
                "cancel",
                "the configured session adapter cannot cancel in-flight turns",
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_patch_validation() {
        assert!(SessionConfigPatch::default().validate().is_err());
        assert!(
            SessionConfigPatch {
                model: Some("  ".into()),
                mode: None
            }
            .validate()
            .is_err()
        );
        assert!(
            SessionConfigPatch {
                model: None,
                mode: Some("turbo".into())
            }
            .validate()
            .is_err()
        );
        assert!(
            SessionConfigPatch {
                model: Some("gpt-5".into()),
                mode: Some("yolo".into())
            }
            .validate()
            .is_ok()
        );
    }

    #[test]
    fn unsupported_messages_carry_parseable_field_and_operation() {
        let error = unsupported_field("model", "no adapter support");
        let PharosApiError::OperationFailed { message } = error else {
            panic!("expected operationFailed");
        };
        let rest = message
            .strip_prefix(UNSUPPORTED_FIELD_PREFIX)
            .expect("field prefix");
        assert_eq!(
            rest.split_once("`: ").expect("split"),
            ("model", "no adapter support")
        );

        let error = unsupported_operation("stop", "nope");
        let PharosApiError::OperationFailed { message } = error else {
            panic!("expected operationFailed");
        };
        assert!(message.starts_with(UNSUPPORTED_OPERATION_PREFIX));
    }

    #[test]
    fn unsupported_config_view_invents_nothing() {
        let view = SessionConfigView::unsupported("s1");
        assert!(!view.supported);
        assert!(view.supported_fields.is_empty());
        assert!(view.model.is_none());
        assert!(view.mode.is_none());
        assert!(view.models.is_empty());
        assert!(view.readonly);
    }
}
