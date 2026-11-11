//! RFC-007 Phase 0 HTTP/WS client API contracts.
//!
//! DTOs and routes for streams S1–S6. No HTTP server lives here — S4 mounts
//! these shapes. Swift ClientKit (S6) mirrors the same JSON.

use pharos_protocol::{AdapterKind, DeliveryState, ThreadReceiptState};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Same freeze as `pharos-protocol::CONTRACTS_VERSION`.
pub const CONTRACTS_VERSION: &str = "0.1.0";

/// HTTP API major path prefix.
pub const API_V1_PREFIX: &str = "/api/v1";

// ---------------------------------------------------------------------------
// Routes (S4 mounts; S6 calls)
// ---------------------------------------------------------------------------

pub mod routes {
    use super::API_V1_PREFIX;

    pub const HEALTH: &str = "/health";
    pub const OPENAPI: &str = "/openapi.json";
    pub const EVENTS_WS: &str = "/api/v1/events";

    pub fn sessions() -> String {
        format!("{API_V1_PREFIX}/sessions")
    }
    pub fn session(id: &str) -> String {
        format!("{API_V1_PREFIX}/sessions/{id}")
    }
    pub fn session_history(id: &str) -> String {
        format!("{API_V1_PREFIX}/sessions/{id}/history")
    }
    pub fn session_messages(id: &str) -> String {
        format!("{API_V1_PREFIX}/sessions/{id}/messages")
    }
    pub fn session_steer(id: &str) -> String {
        format!("{API_V1_PREFIX}/sessions/{id}/steer")
    }
    pub fn session_approval(id: &str) -> String {
        format!("{API_V1_PREFIX}/sessions/{id}/approval")
    }
    pub fn session_progress(id: &str) -> String {
        format!("{API_V1_PREFIX}/sessions/{id}/progress")
    }
    pub fn threads() -> String {
        format!("{API_V1_PREFIX}/threads")
    }
    pub fn thread(id: &str) -> String {
        format!("{API_V1_PREFIX}/threads/{id}")
    }
    pub fn thread_messages(id: &str) -> String {
        format!("{API_V1_PREFIX}/threads/{id}/messages")
    }
    pub fn thread_reply(id: &str) -> String {
        format!("{API_V1_PREFIX}/threads/{id}/reply")
    }
    pub fn projects() -> String {
        format!("{API_V1_PREFIX}/projects")
    }
    pub fn inventory() -> String {
        format!("{API_V1_PREFIX}/inventory/sessions")
    }
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "code", rename_all = "camelCase")]
pub enum PharosApiError {
    #[serde(rename_all = "camelCase")]
    BackendUnreachable { backend: String, reason: String },
    #[serde(rename_all = "camelCase")]
    SessionNotFound { id: String },
    #[serde(rename_all = "camelCase")]
    ThreadNotFound { id: String },
    #[serde(rename_all = "camelCase")]
    ApprovalNotFound { id: String },
    #[serde(rename_all = "camelCase")]
    ConnectionFailed { message: String },
    #[serde(rename_all = "camelCase")]
    OperationFailed { message: String },
    #[serde(rename_all = "camelCase")]
    InvalidRequest { message: String },
    #[serde(rename_all = "camelCase")]
    Conflict { message: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorBody {
    pub error: PharosApiError,
    pub contracts_version: String,
}

impl ErrorBody {
    pub fn new(error: PharosApiError) -> Self {
        Self {
            error,
            contracts_version: CONTRACTS_VERSION.to_string(),
        }
    }
}

// ---------------------------------------------------------------------------
// Summaries & Thread/Session DTOs (CLIENT-API)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionActivityStatus {
    Idle,
    Working,
    NeedsHuman,
    Stopped,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    pub session_id: String,
    pub machine_id: String,
    pub agent_type: String,
    pub workspace_path: String,
    pub title: String,
    pub status: SessionActivityStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latest_message_preview: Option<String>,
    /// RFC3339 timestamp.
    pub updated_at: String,
    pub avatar_seed: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub inventory_stale: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connection_route: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadSummary {
    pub thread_id: String,
    pub title: String,
    pub member_ids: Vec<String>,
    pub unread_count: u32,
    pub last_activity_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectSummary {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    pub project_path: String,
    pub name: String,
    pub tracked_devices: Vec<String>,
    pub active_sessions_count: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub related_session_ids: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadReplyRef {
    pub message_id: String,
    pub sender_name: String,
    pub preview: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadMessage {
    pub id: String,
    pub thread_id: String,
    pub sender_id: String,
    pub sender_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sender_avatar_seed: Option<String>,
    pub text: String,
    pub timestamp: String,
    pub receipt: ThreadReceiptState,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub target_member_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<ThreadReplyRef>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendThreadMessageRequest {
    pub text: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub target_member_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply_to_message_id: Option<String>,
}

/// CLI / API reply as a Thread member (S1 grokbot uses `as_member = "grokbot"`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplyThreadMessageRequest {
    pub as_member: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplyThreadMessageResponse {
    pub ok: bool,
    pub thread: String,
    #[serde(rename = "as")]
    pub as_member: String,
    pub reply_id: String,
    pub reply_to: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendSessionMessageRequest {
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SteerSessionRequest {
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ApprovalDecision {
    AllowedOnce,
    AllowedAlways,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveApprovalRequest {
    pub approval_id: String,
    pub decision: ApprovalDecision,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ApprovalKind {
    #[serde(rename_all = "camelCase")]
    ToolPermission {
        tool_name: String,
        #[serde(default)]
        params: Value,
        #[serde(skip_serializing_if = "Option::is_none")]
        explanation: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    StructuredQuestionnaire {
        intent: String,
        questions: Vec<QuestionOption>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionOption {
    pub id: String,
    pub question: String,
    pub options: Vec<String>,
    pub is_multi_select: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApprovalRequest {
    pub approval_id: String,
    pub session_id: String,
    pub kind: ApprovalKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub available_choices: Option<Vec<String>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TodoStatus {
    Pending,
    InProgress,
    Completed,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionGoal {
    pub objective: String,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionTodo {
    pub text: String,
    pub status: TodoStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionProgress {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub goal: Option<SessionGoal>,
    pub todos: Vec<SessionTodo>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TurnStatus {
    InProgress,
    Completed,
    Failed,
    Cancelled,
    NeedsHuman,
}

/// Compact turn DTO for history lists (full block model may extend later).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CanonicalTurn {
    pub turn_id: String,
    pub session_id: String,
    pub turn_number: u32,
    pub status: TurnStatus,
    pub created_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub assistant_text: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostInventoryStatus {
    pub supported_agents: Vec<String>,
    pub unavailable_agents: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostInventorySnapshot {
    pub sessions: Vec<SessionSummary>,
    pub status: HostInventoryStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HealthResponse {
    pub ok: bool,
    pub contracts_version: String,
    pub service: String,
}

impl HealthResponse {
    pub fn ok_meshd() -> Self {
        Self {
            ok: true,
            contracts_version: CONTRACTS_VERSION.to_string(),
            service: "pharos-meshd".to_string(),
        }
    }
}

/// Runtime delivery view for CLI/debug (S1 honesty).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeliveryRecord {
    pub id: String,
    pub conversation_id: String,
    pub state: DeliveryState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// Adapter registration hint published by S5 for S2.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AdapterManifest {
    pub id: String,
    pub kind: AdapterKind,
    pub capabilities: Vec<String>,
}

// ---------------------------------------------------------------------------
// WebSocket client events (S4 / S6)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "eventType", rename_all = "camelCase")]
pub enum ClientEvent {
    #[serde(rename_all = "camelCase")]
    SessionUpdated { session: SessionSummary },
    #[serde(rename_all = "camelCase")]
    SessionConnectionRestored { session_id: String },
    #[serde(rename_all = "camelCase")]
    TurnStarted { turn: CanonicalTurn },
    #[serde(rename_all = "camelCase")]
    TurnCompleted { turn: CanonicalTurn },
    #[serde(rename_all = "camelCase")]
    SessionGoalUpdated {
        session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        goal: Option<SessionGoal>,
    },
    #[serde(rename_all = "camelCase")]
    SessionTodosUpdated {
        session_id: String,
        todos: Vec<SessionTodo>,
    },
    #[serde(rename_all = "camelCase")]
    ApprovalRequired { approval: ApprovalRequest },
    #[serde(rename_all = "camelCase")]
    ApprovalUpdated { approval: ApprovalRequest },
    #[serde(rename_all = "camelCase")]
    ApprovalResolved {
        approval_id: String,
        decision: ApprovalDecision,
    },
    #[serde(rename_all = "camelCase")]
    ApprovalWithdrawn { approval_id: String },
    #[serde(rename_all = "camelCase")]
    ThreadMessageReceived { thread_message: ThreadMessage },
    #[serde(rename_all = "camelCase")]
    ThreadReceiptUpdated {
        thread_id: String,
        message_id: String,
        receipt: ThreadReceiptState,
    },
    #[serde(rename_all = "camelCase")]
    MemberStatusChanged { member_name: String, status: String },
    #[serde(rename_all = "camelCase")]
    DeliveryStateChanged { delivery: DeliveryRecord },
    #[serde(rename_all = "camelCase")]
    BackendError { error: PharosApiError },
}

// Re-export wake kind for OpenAPI docs.
pub use pharos_protocol::{ThreadMentionWake, WebhookKind as ProtocolWebhookKind};

/// Minimal OpenAPI 3.0 stub — S4 may expand; paths are frozen for 0.1.0.
pub fn openapi_stub_json() -> Value {
    serde_json::json!({
        "openapi": "3.0.3",
        "info": {
            "title": "Pharos Backend API",
            "version": CONTRACTS_VERSION,
            "description": "RFC-007 Phase 0 contract stub. Implementations in S4."
        },
        "paths": {
            "/health": {
                "get": {
                    "operationId": "health",
                    "responses": { "200": { "description": "ok" } }
                }
            },
            "/api/v1/sessions": {
                "get": { "operationId": "listSessions", "responses": { "200": { "description": "SessionSummary[]" } } }
            },
            "/api/v1/threads": {
                "get": { "operationId": "listThreads", "responses": { "200": { "description": "ThreadSummary[]" } } }
            },
            "/api/v1/threads/{threadId}/messages": {
                "get": { "operationId": "listThreadMessages", "responses": { "200": { "description": "ThreadMessage[]" } } },
                "post": { "operationId": "sendThreadMessage", "responses": { "200": { "description": "ThreadMessage" } } }
            },
            "/api/v1/threads/{threadId}/reply": {
                "post": { "operationId": "replyThreadMessage", "responses": { "200": { "description": "ReplyThreadMessageResponse" } } }
            },
            "/api/v1/sessions/{sessionId}/messages": {
                "post": { "operationId": "sendSessionMessage", "responses": { "200": { "description": "CanonicalTurn" } } }
            },
            "/api/v1/sessions/{sessionId}/approval": {
                "post": { "operationId": "resolveApproval", "responses": { "200": { "description": "ok" } } }
            },
            "/api/v1/sessions/{sessionId}/progress": {
                "get": { "operationId": "sessionProgress", "responses": { "200": { "description": "SessionProgress" } } }
            },
            "/api/v1/projects": {
                "get": { "operationId": "listProjects", "responses": { "200": { "description": "ProjectSummary[]" } } }
            },
            "/api/v1/events": {
                "get": {
                    "operationId": "eventsWebSocket",
                    "description": "WebSocket upgrade; frames are ClientEvent JSON",
                    "responses": { "101": { "description": "Switching Protocols" } }
                }
            }
        },
        "x-pharos-webhook-kinds": ["thread-mention", "hitl-request"],
        "x-pharos-contracts-version": CONTRACTS_VERSION
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use pharos_protocol::grokbot;

    #[test]
    fn contracts_version() {
        assert_eq!(CONTRACTS_VERSION, "0.1.0");
        assert_eq!(HealthResponse::ok_meshd().contracts_version, "0.1.0");
    }

    #[test]
    fn reply_request_grokbot_member() {
        let req = ReplyThreadMessageRequest {
            as_member: grokbot::MEMBER_ID.to_string(),
            text: "hi".into(),
            message_id: Some("m1".into()),
        };
        let v = serde_json::to_value(&req).unwrap();
        assert_eq!(v["asMember"], "grokbot");
    }

    #[test]
    fn client_event_tag() {
        let ev = ClientEvent::ApprovalWithdrawn {
            approval_id: "a1".into(),
        };
        let v = serde_json::to_value(&ev).unwrap();
        assert_eq!(v["eventType"], "approvalWithdrawn");
        assert_eq!(v["approvalId"], "a1");
    }

    #[test]
    fn openapi_lists_thread_reply() {
        let doc = openapi_stub_json();
        assert!(
            doc["paths"]
                .get("/api/v1/threads/{threadId}/reply")
                .is_some()
        );
        assert_eq!(doc["info"]["version"], "0.1.0");
    }

    #[test]
    fn api_error_roundtrip() {
        let body = ErrorBody::new(PharosApiError::ThreadNotFound { id: "t1".into() });
        let raw = serde_json::to_string(&body).unwrap();
        let back: ErrorBody = serde_json::from_str(&raw).unwrap();
        assert_eq!(back, body);
    }
}
