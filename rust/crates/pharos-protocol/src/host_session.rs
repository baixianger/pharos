//! Cross-Host Session query/action wire contract.
//!
//! One Host (the *caller*) asks another Host (the *callee/target*) to list its
//! sessions, read a session history, or perform a session action. Transport is
//! the Peer RPC envelope from [`crate::ReplicaRpcOperation`]:
//!
//! - [`ReplicaRpcOperation::HostSessionQuery`] = `host.session.query.v1`
//! - [`ReplicaRpcOperation::HostSessionAction`] = `host.session.action.v1`
//!
//! The header (`ReplicaRpcHeader`) carries the trust group, membership epoch and
//! transport correlation ID. This module defines the JSON body schemas, their
//! payload versions, and the explicit error codes exchanged on failure.
//!
//! **Versioning:** this module is additive to the frozen Phase 0 contract
//! (`CONTRACTS_VERSION = "0.1.0"`); each body carries its own `payloadVersion`
//! (currently [`QUERY_VERSION`] / [`ACTION_VERSION`]) so later schema changes
//! can negotiate without re-tagging Phase 0. Receivers must reject unknown
//! payload versions with [`HostSessionErrorCode::InvalidRequest`].
//!
//! Nothing in this module carries secrets: bodies only describe sessions and
//! user-visible actions.

use serde::{Deserialize, Serialize};

/// Payload version for `host.session.query.v1` bodies.
pub const QUERY_VERSION: u32 = 1;
/// Payload version for `host.session.action.v1` bodies.
pub const ACTION_VERSION: u32 = 1;

/// Upper bound for any session / host / approval identifier on the wire.
pub const MAX_IDENTIFIER_BYTES: usize = 512;
/// Upper bound for `sendMessage` text (1 MiB).
pub const MAX_MESSAGE_TEXT_BYTES: usize = 1024 * 1024;
/// Upper bound for `steer` guidance text (64 KiB).
pub const MAX_STEER_TEXT_BYTES: usize = 64 * 1024;
/// Upper bound for an idempotency key.
pub const MAX_IDEMPOTENCY_KEY_BYTES: usize = 512;
/// Maximum sessions returned by one `listSessions` query.
pub const MAX_LISTED_SESSIONS: usize = 2_000;

/// Capability advertised by a Host in `host.runtime.hello.v1`.
pub const QUERY_CAPABILITY: &str = "host-session-query-v1";
/// Capability advertised by a Host in `host.runtime.hello.v1`.
pub const ACTION_CAPABILITY: &str = "host-session-action-v1";

/// `queryKind` wire strings (Swift `MeshHostSessionQueryRequest.queryKind` dialect).
pub mod query_kind {
    pub const LIST_SESSIONS: &str = "listSessions";
    pub const GET_SESSION: &str = "getSession";
    pub const SESSION_HISTORY: &str = "sessionHistory";
}

/// `actionKind` wire strings (Swift `MeshHostSessionActionRequest.actionKind` dialect).
pub mod action_kind {
    pub const SEND_MESSAGE: &str = "sendMessage";
    pub const STEER: &str = "steer";
    pub const RESOLVE_APPROVAL: &str = "resolveApproval";
    pub const STOP: &str = "stop";
}

// ---------------------------------------------------------------------------
// Query
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum HostSessionQueryKind {
    #[serde(rename = "listSessions")]
    ListSessions,
    #[serde(rename = "getSession")]
    GetSession,
    #[serde(rename = "sessionHistory")]
    SessionHistory,
}

impl HostSessionQueryKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::ListSessions => query_kind::LIST_SESSIONS,
            Self::GetSession => query_kind::GET_SESSION,
            Self::SessionHistory => query_kind::SESSION_HISTORY,
        }
    }

    /// Kinds that address one concrete session and therefore require `sessionId`.
    pub fn requires_session_id(self) -> bool {
        matches!(self, Self::GetSession | Self::SessionHistory)
    }
}

/// `host.session.query.v1` request body.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostSessionQueryRequest {
    pub payload_version: u32,
    pub host_device_id: String,
    pub query_kind: HostSessionQueryKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

impl HostSessionQueryRequest {
    pub fn list_sessions(host_device_id: impl Into<String>) -> Self {
        Self {
            payload_version: QUERY_VERSION,
            host_device_id: host_device_id.into(),
            query_kind: HostSessionQueryKind::ListSessions,
            session_id: None,
        }
    }

    pub fn get_session(host_device_id: impl Into<String>, session_id: impl Into<String>) -> Self {
        Self {
            payload_version: QUERY_VERSION,
            host_device_id: host_device_id.into(),
            query_kind: HostSessionQueryKind::GetSession,
            session_id: Some(session_id.into()),
        }
    }

    pub fn session_history(
        host_device_id: impl Into<String>,
        session_id: impl Into<String>,
    ) -> Self {
        Self {
            payload_version: QUERY_VERSION,
            host_device_id: host_device_id.into(),
            query_kind: HostSessionQueryKind::SessionHistory,
            session_id: Some(session_id.into()),
        }
    }

    pub fn validate(&self) -> Result<(), HostSessionErrorBody> {
        if self.payload_version != QUERY_VERSION {
            return Err(HostSessionErrorBody::invalid(format!(
                "unsupported host session query payloadVersion {} (expected {QUERY_VERSION})",
                self.payload_version
            )));
        }
        validate_identifier("hostDeviceId", &self.host_device_id)?;
        match (self.query_kind.requires_session_id(), &self.session_id) {
            (true, None) => Err(HostSessionErrorBody::invalid(
                "sessionId is required for this queryKind",
            )),
            (false, Some(session_id)) => validate_identifier("sessionId", session_id),
            (true, Some(session_id)) => validate_identifier("sessionId", session_id),
            (false, None) => Ok(()),
        }
    }
}

/// `host.session.query.v1` response body.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostSessionQueryResponse {
    pub payload_version: u32,
    pub host_device_id: String,
    pub query_kind: HostSessionQueryKind,
    pub data: HostSessionQueryData,
}

impl HostSessionQueryResponse {
    pub fn new(
        host_device_id: impl Into<String>,
        query_kind: HostSessionQueryKind,
        data: HostSessionQueryData,
    ) -> Self {
        Self {
            payload_version: QUERY_VERSION,
            host_device_id: host_device_id.into(),
            query_kind,
            data,
        }
    }

    pub fn validate(&self) -> Result<(), HostSessionErrorBody> {
        if self.payload_version != QUERY_VERSION {
            return Err(HostSessionErrorBody::invalid(format!(
                "unsupported host session query response payloadVersion {} (expected {QUERY_VERSION})",
                self.payload_version
            )));
        }
        validate_identifier("hostDeviceId", &self.host_device_id)?;
        let matches_kind = matches!(
            (&self.query_kind, &self.data),
            (
                HostSessionQueryKind::ListSessions,
                HostSessionQueryData::Sessions { .. }
            ) | (
                HostSessionQueryKind::GetSession,
                HostSessionQueryData::Session { .. }
            ) | (
                HostSessionQueryKind::SessionHistory,
                HostSessionQueryData::History { .. }
            )
        );
        if !matches_kind {
            return Err(HostSessionErrorBody::invalid(
                "response data does not match queryKind",
            ));
        }
        Ok(())
    }
}

/// Typed payload of a query response (internally tagged with `type`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum HostSessionQueryData {
    Sessions { sessions: Vec<HostSessionSummary> },
    Session { session: HostSessionSummary },
    History { turns: Vec<HostSessionTurn> },
}

/// Wire mirror of `pharos_api::SessionSummary`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostSessionSummary {
    pub session_id: String,
    pub machine_id: String,
    pub agent_type: String,
    pub workspace_path: String,
    pub title: String,
    pub status: HostSessionActivityStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_message_preview: Option<String>,
    pub updated_at: String,
    pub avatar_seed: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inventory_stale: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub connection_route: Option<String>,
}

/// Wire mirror of `pharos_api::SessionActivityStatus`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostSessionActivityStatus {
    Idle,
    Working,
    NeedsHuman,
    Stopped,
    Unknown,
}

/// Wire mirror of `pharos_api::CanonicalTurn`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostSessionTurn {
    pub turn_id: String,
    pub session_id: String,
    pub turn_number: u32,
    pub status: HostSessionTurnStatus,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub assistant_text: Vec<String>,
}

/// Wire mirror of `pharos_api::TurnStatus`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostSessionTurnStatus {
    InProgress,
    Completed,
    Failed,
    Cancelled,
    NeedsHuman,
}

// ---------------------------------------------------------------------------
// Action
// ---------------------------------------------------------------------------

/// One user-visible session action.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum HostSessionActionPayload {
    SendMessage {
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
    },
    Steer {
        text: String,
    },
    ResolveApproval {
        approval_id: String,
        decision: HostApprovalDecision,
    },
    /// Stop/kill the remote session. Hosts that cannot stop a session must
    /// answer [`HostSessionErrorCode::UnsupportedOperation`] — never "success".
    Stop {
        #[serde(default)]
        force: bool,
    },
}

impl HostSessionActionPayload {
    pub fn kind(&self) -> HostSessionActionKind {
        match self {
            Self::SendMessage { .. } => HostSessionActionKind::SendMessage,
            Self::Steer { .. } => HostSessionActionKind::Steer,
            Self::ResolveApproval { .. } => HostSessionActionKind::ResolveApproval,
            Self::Stop { .. } => HostSessionActionKind::Stop,
        }
    }

    pub fn validate(&self) -> Result<(), HostSessionErrorBody> {
        match self {
            Self::SendMessage { text, request_id } => {
                validate_text("text", text, MAX_MESSAGE_TEXT_BYTES)?;
                if let Some(request_id) = request_id {
                    validate_identifier("requestId", request_id)?;
                }
                Ok(())
            }
            Self::Steer { text } => validate_text("text", text, MAX_STEER_TEXT_BYTES),
            Self::ResolveApproval {
                approval_id,
                decision: _,
            } => validate_identifier("approvalId", approval_id),
            Self::Stop { .. } => Ok(()),
        }
    }
}

/// Kinds are carried by the tagged payload; this enum exists for logs/audit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HostSessionActionKind {
    SendMessage,
    Steer,
    ResolveApproval,
    Stop,
}

impl HostSessionActionKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::SendMessage => action_kind::SEND_MESSAGE,
            Self::Steer => action_kind::STEER,
            Self::ResolveApproval => action_kind::RESOLVE_APPROVAL,
            Self::Stop => action_kind::STOP,
        }
    }
}

/// Wire mirror of `pharos_api::ApprovalDecision`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HostApprovalDecision {
    AllowedOnce,
    AllowedAlways,
    Rejected,
}

/// `host.session.action.v1` request body.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostSessionActionRequest {
    pub payload_version: u32,
    /// Caller-generated UUID (string) used for correlation/replay protection.
    pub action_id: String,
    pub host_device_id: String,
    pub session_id: String,
    /// Caller-generated idempotency key. Replaying the same key with the same
    /// body must not perform the action twice.
    pub idempotency_key: String,
    pub action: HostSessionActionPayload,
}

impl HostSessionActionRequest {
    pub fn new(
        action_id: impl Into<String>,
        host_device_id: impl Into<String>,
        session_id: impl Into<String>,
        idempotency_key: impl Into<String>,
        action: HostSessionActionPayload,
    ) -> Self {
        Self {
            payload_version: ACTION_VERSION,
            action_id: action_id.into(),
            host_device_id: host_device_id.into(),
            session_id: session_id.into(),
            idempotency_key: idempotency_key.into(),
            action,
        }
    }

    pub fn kind(&self) -> HostSessionActionKind {
        self.action.kind()
    }

    pub fn validate(&self) -> Result<(), HostSessionErrorBody> {
        if self.payload_version != ACTION_VERSION {
            return Err(HostSessionErrorBody::invalid(format!(
                "unsupported host session action payloadVersion {} (expected {ACTION_VERSION})",
                self.payload_version
            )));
        }
        validate_identifier("actionId", &self.action_id)?;
        validate_identifier("hostDeviceId", &self.host_device_id)?;
        validate_identifier("sessionId", &self.session_id)?;
        if self.idempotency_key.is_empty() || self.idempotency_key.len() > MAX_IDEMPOTENCY_KEY_BYTES
        {
            return Err(HostSessionErrorBody::invalid(
                "idempotencyKey is required (<= 512 bytes)",
            ));
        }
        self.action.validate()
    }
}

/// `host.session.action.v1` response body. Failures never use this body: they
/// are returned as a `ReplicaRpcDisposition::Error` header with an
/// [`HostSessionErrorBody`] body.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostSessionActionResponse {
    pub payload_version: u32,
    pub action_id: String,
    pub host_device_id: String,
    pub session_id: String,
    /// The turn created by `sendMessage`, when the host has one to report.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<HostSessionTurn>,
}

impl HostSessionActionResponse {
    pub fn new(
        action_id: impl Into<String>,
        host_device_id: impl Into<String>,
        session_id: impl Into<String>,
    ) -> Self {
        Self {
            payload_version: ACTION_VERSION,
            action_id: action_id.into(),
            host_device_id: host_device_id.into(),
            session_id: session_id.into(),
            turn: None,
        }
    }

    pub fn with_turn(mut self, turn: HostSessionTurn) -> Self {
        self.turn = Some(turn);
        self
    }

    pub fn validate(&self) -> Result<(), HostSessionErrorBody> {
        if self.payload_version != ACTION_VERSION {
            return Err(HostSessionErrorBody::invalid(format!(
                "unsupported host session action response payloadVersion {} (expected {ACTION_VERSION})",
                self.payload_version
            )));
        }
        validate_identifier("actionId", &self.action_id)?;
        validate_identifier("hostDeviceId", &self.host_device_id)?;
        validate_identifier("sessionId", &self.session_id)?;
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Explicit cross-host session failure codes. These are the only codes a host
/// may put in `ReplicaRpcHeader.errorCode` for host session operations.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum HostSessionErrorCode {
    /// Peer is not paired / not in the host's allowlist, or trust group/epoch
    /// does not match.
    Unauthorized,
    /// The addressed session does not exist on the target host.
    UnknownSession,
    /// Caller-observed transport failure: host offline/timeout. A host never
    /// sends this code; callers synthesize it locally.
    HostUnreachable,
    /// Target host has no live vendor adapter able to perform the action.
    AdapterUnavailable,
    /// Malformed or unsupported request (bad payload version, missing fields).
    InvalidRequest,
    /// Operation is not implemented by this host (e.g. `stop`).
    UnsupportedOperation,
    /// Unexpected target-side failure.
    Internal,
}

impl HostSessionErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unauthorized => "unauthorized",
            Self::UnknownSession => "unknown-session",
            Self::HostUnreachable => "host-unreachable",
            Self::AdapterUnavailable => "adapter-unavailable",
            Self::InvalidRequest => "invalid-request",
            Self::UnsupportedOperation => "unsupported-operation",
            Self::Internal => "internal",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "unauthorized" => Some(Self::Unauthorized),
            "unknown-session" => Some(Self::UnknownSession),
            "host-unreachable" => Some(Self::HostUnreachable),
            "adapter-unavailable" => Some(Self::AdapterUnavailable),
            "invalid-request" => Some(Self::InvalidRequest),
            "unsupported-operation" => Some(Self::UnsupportedOperation),
            "internal" => Some(Self::Internal),
            _ => None,
        }
    }
}

/// Structured host session error body returned with an error disposition.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostSessionErrorBody {
    pub code: HostSessionErrorCode,
    pub message: String,
}

impl HostSessionErrorBody {
    pub fn new(code: HostSessionErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new(HostSessionErrorCode::InvalidRequest, message)
    }

    pub fn unauthorized(message: impl Into<String>) -> Self {
        Self::new(HostSessionErrorCode::Unauthorized, message)
    }

    pub fn unknown_session(session_id: &str) -> Self {
        Self::new(
            HostSessionErrorCode::UnknownSession,
            format!("unknown session: {session_id}"),
        )
    }

    pub fn adapter_unavailable(message: impl Into<String>) -> Self {
        Self::new(HostSessionErrorCode::AdapterUnavailable, message)
    }

    pub fn unsupported(message: impl Into<String>) -> Self {
        Self::new(HostSessionErrorCode::UnsupportedOperation, message)
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(HostSessionErrorCode::Internal, message)
    }
}

fn validate_identifier(field: &str, value: &str) -> Result<(), HostSessionErrorBody> {
    if value.is_empty() {
        return Err(HostSessionErrorBody::invalid(format!(
            "{field} is required"
        )));
    }
    if value.len() > MAX_IDENTIFIER_BYTES {
        return Err(HostSessionErrorBody::invalid(format!(
            "{field} exceeds {MAX_IDENTIFIER_BYTES} bytes"
        )));
    }
    Ok(())
}

fn validate_text(field: &str, value: &str, maximum: usize) -> Result<(), HostSessionErrorBody> {
    if value.trim().is_empty() {
        return Err(HostSessionErrorBody::invalid(format!(
            "{field} is required"
        )));
    }
    if value.len() > maximum {
        return Err(HostSessionErrorBody::invalid(format!(
            "{field} exceeds {maximum} bytes"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_sessions_request_roundtrip_is_camel_case() {
        let request = HostSessionQueryRequest::list_sessions("host-b");
        let value = serde_json::to_value(&request).unwrap();
        assert_eq!(value["payloadVersion"], 1);
        assert_eq!(value["hostDeviceId"], "host-b");
        assert_eq!(value["queryKind"], "listSessions");
        assert!(value.get("sessionId").is_none());
        let back: HostSessionQueryRequest = serde_json::from_value(value).unwrap();
        assert_eq!(back, request);
        request.validate().unwrap();
    }

    #[test]
    fn query_requires_session_id_for_session_kinds() {
        let mut request = HostSessionQueryRequest::list_sessions("host-b");
        request.query_kind = HostSessionQueryKind::SessionHistory;
        assert_eq!(
            request.validate().unwrap_err().code,
            HostSessionErrorCode::InvalidRequest
        );
        let request = HostSessionQueryRequest::session_history("host-b", "s1");
        request.validate().unwrap();
        // A stray sessionId on a list query is tolerated (forward compatible)
        // but still has to be a well-formed identifier.
        let mut stray = HostSessionQueryRequest::list_sessions("host-b");
        stray.session_id = Some("s1".into());
        stray.validate().unwrap();
        stray.session_id = Some(String::new());
        stray.validate().unwrap_err();
    }

    #[test]
    fn query_rejects_unknown_payload_version() {
        let mut request = HostSessionQueryRequest::list_sessions("host-b");
        request.payload_version = 99;
        let error = request.validate().unwrap_err();
        assert_eq!(error.code, HostSessionErrorCode::InvalidRequest);
        assert!(error.message.contains("payloadVersion"));
    }

    #[test]
    fn query_response_data_is_tagged_and_validated() {
        let response = HostSessionQueryResponse::new(
            "host-b",
            HostSessionQueryKind::SessionHistory,
            HostSessionQueryData::History {
                turns: vec![HostSessionTurn {
                    turn_id: "t1".into(),
                    session_id: "s1".into(),
                    turn_number: 1,
                    status: HostSessionTurnStatus::Completed,
                    created_at: "2026-11-11T00:00:00Z".into(),
                    completed_at: None,
                    assistant_text: vec!["hello".into()],
                }],
            },
        );
        response.validate().unwrap();
        let value = serde_json::to_value(&response).unwrap();
        assert_eq!(value["data"]["type"], "history");
        assert_eq!(value["data"]["turns"][0]["status"], "completed");
        let back: HostSessionQueryResponse = serde_json::from_value(value).unwrap();
        assert_eq!(back, response);

        // Mismatched data/kind is rejected.
        let mismatched = HostSessionQueryResponse::new(
            "host-b",
            HostSessionQueryKind::ListSessions,
            HostSessionQueryData::History { turns: vec![] },
        );
        assert_eq!(
            mismatched.validate().unwrap_err().code,
            HostSessionErrorCode::InvalidRequest
        );
    }

    #[test]
    fn session_summary_and_activity_status_serde_match_api_names() {
        let summary = HostSessionSummary {
            session_id: "s1".into(),
            machine_id: "host-b".into(),
            agent_type: "codex".into(),
            workspace_path: "/tmp/ws".into(),
            title: "Demo".into(),
            status: HostSessionActivityStatus::NeedsHuman,
            latest_message_preview: Some("hi".into()),
            updated_at: "2026-11-11T00:00:00Z".into(),
            avatar_seed: "seed".into(),
            inventory_stale: None,
            connection_route: Some("mesh".into()),
        };
        let value = serde_json::to_value(&summary).unwrap();
        assert_eq!(value["sessionId"], "s1");
        assert_eq!(value["machineId"], "host-b");
        assert_eq!(value["status"], "needs_human");
        assert!(value.get("inventoryStale").is_none());
    }

    #[test]
    fn action_request_roundtrip_covers_all_kinds() {
        let cases = [
            HostSessionActionPayload::SendMessage {
                text: "hello".into(),
                request_id: Some("req-1".into()),
            },
            HostSessionActionPayload::Steer {
                text: "focus".into(),
            },
            HostSessionActionPayload::ResolveApproval {
                approval_id: "a1".into(),
                decision: HostApprovalDecision::AllowedOnce,
            },
            HostSessionActionPayload::Stop { force: true },
        ];
        for (index, action) in cases.into_iter().enumerate() {
            let action_id = format!("action-{index}");
            let request = HostSessionActionRequest::new(
                action_id.clone(),
                "host-b",
                "s1",
                "idem-1",
                action.clone(),
            );
            request.validate().unwrap();
            let value = serde_json::to_value(&request).unwrap();
            assert_eq!(value["payloadVersion"], 1);
            assert_eq!(value["actionId"], action_id);
            assert_eq!(value["idempotencyKey"], "idem-1");
            let back: HostSessionActionRequest = serde_json::from_value(value).unwrap();
            assert_eq!(back, request);
        }
    }

    #[test]
    fn action_kind_strings_match_wip_dialect() {
        assert_eq!(
            HostSessionActionPayload::SendMessage {
                text: "hi".into(),
                request_id: None
            }
            .kind()
            .as_str(),
            "sendMessage"
        );
        assert_eq!(
            HostSessionActionPayload::Steer { text: "x".into() }
                .kind()
                .as_str(),
            "steer"
        );
        assert_eq!(
            HostSessionActionPayload::ResolveApproval {
                approval_id: "a".into(),
                decision: HostApprovalDecision::Rejected
            }
            .kind()
            .as_str(),
            "resolveApproval"
        );
        assert_eq!(
            HostSessionActionPayload::Stop { force: false }
                .kind()
                .as_str(),
            "stop"
        );
    }

    #[test]
    fn action_validation_rejects_empty_text_and_missing_fields() {
        let invalid = HostSessionActionPayload::SendMessage {
            text: "   ".into(),
            request_id: None,
        };
        assert_eq!(
            invalid.validate().unwrap_err().code,
            HostSessionErrorCode::InvalidRequest
        );

        let mut request = HostSessionActionRequest::new(
            "action-1",
            "host-b",
            "s1",
            "",
            HostSessionActionPayload::Steer {
                text: "focus".into(),
            },
        );
        assert_eq!(
            request.validate().unwrap_err().code,
            HostSessionErrorCode::InvalidRequest
        );
        request.idempotency_key = "idem".into();
        request.session_id.clear();
        request.validate().unwrap_err();
    }

    #[test]
    fn oversized_message_is_rejected() {
        let payload = HostSessionActionPayload::SendMessage {
            text: "x".repeat(MAX_MESSAGE_TEXT_BYTES + 1),
            request_id: None,
        };
        let error = payload.validate().unwrap_err();
        assert_eq!(error.code, HostSessionErrorCode::InvalidRequest);
    }

    #[test]
    fn action_response_reports_optional_turn() {
        let response = HostSessionActionResponse::new("action-1", "host-b", "s1");
        let value = serde_json::to_value(&response).unwrap();
        assert!(value.get("turn").is_none());
        response.validate().unwrap();

        let response = response.with_turn(HostSessionTurn {
            turn_id: "t1".into(),
            session_id: "s1".into(),
            turn_number: 2,
            status: HostSessionTurnStatus::InProgress,
            created_at: "2026-11-11T00:00:00Z".into(),
            completed_at: None,
            assistant_text: vec![],
        });
        let value = serde_json::to_value(&response).unwrap();
        assert_eq!(value["turn"]["turnId"], "t1");
        response.validate().unwrap();
    }

    #[test]
    fn error_codes_are_stable_kebab_case_and_roundtrip() {
        let cases = [
            (HostSessionErrorCode::Unauthorized, "unauthorized"),
            (HostSessionErrorCode::UnknownSession, "unknown-session"),
            (HostSessionErrorCode::HostUnreachable, "host-unreachable"),
            (
                HostSessionErrorCode::AdapterUnavailable,
                "adapter-unavailable",
            ),
            (HostSessionErrorCode::InvalidRequest, "invalid-request"),
            (
                HostSessionErrorCode::UnsupportedOperation,
                "unsupported-operation",
            ),
            (HostSessionErrorCode::Internal, "internal"),
        ];
        for (code, wire) in cases {
            assert_eq!(code.as_str(), wire);
            assert_eq!(HostSessionErrorCode::parse(wire), Some(code));
            let body = HostSessionErrorBody::new(code, "detail");
            let value = serde_json::to_value(&body).unwrap();
            assert_eq!(value["code"], wire);
            let back: HostSessionErrorBody = serde_json::from_value(value).unwrap();
            assert_eq!(back, body);
        }
        assert_eq!(HostSessionErrorCode::parse("nope"), None);
    }

    #[test]
    fn error_bodies_have_explicit_constructors() {
        assert_eq!(
            HostSessionErrorBody::unknown_session("s1").code,
            HostSessionErrorCode::UnknownSession
        );
        assert_eq!(
            HostSessionErrorBody::adapter_unavailable("no adapter").code,
            HostSessionErrorCode::AdapterUnavailable
        );
        assert_eq!(
            HostSessionErrorBody::unsupported("nope").code,
            HostSessionErrorCode::UnsupportedOperation
        );
        assert_eq!(
            HostSessionErrorBody::unauthorized("peer").code,
            HostSessionErrorCode::Unauthorized
        );
    }
}
