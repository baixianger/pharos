//! HTML-layer handlers for the rust/web-endpoints additions.
//!
//! Route registration lives in one block in [`crate::router::api_router`];
//! this module only contains the handlers. Every handler validates against the
//! real S1/S2 services before writing, and unsupported adapter capabilities
//! surface explicit errors (see [`crate::error::ApiError`]).
//!
//! Stores (bindings / member settings / attachments) are persisted by
//! [`crate::services`] under the Host data dir.

use crate::error::{ApiError, ApiResult};
use crate::services::{MemberSettingsPatch, MemberSettingsView, StoreError, ThreadBinding};
use crate::state::AppState;
use axum::Json;
use axum::extract::{Path, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use pharos_api::{PharosApiError, SendSessionMessageRequest, ThreadSummary};
use serde::Deserialize;
use serde_json::{Value, json};

/// Hard cap for the JSON-encoded (base64) attachment payload: 10 MiB decoded.
pub const MAX_ATTACHMENT_BYTES: usize = 10 * 1024 * 1024;
/// Hard cap for a decoded avatar (512 KiB).
pub const MAX_AVATAR_BYTES: usize = 512 * 1024;
/// Maximum accepted JSON body (base64-encoded 10 MiB attachment + slack). The
/// handlers still enforce the decoded size limits; this only stops axum's
/// default 2 MiB extractor limit from answering 413 for valid uploads.
pub const MAX_ENCODED_BODY_BYTES: usize = 16 * 1024 * 1024;
/// Upper bound for the encoded string itself, checked before decoding so a
/// hostile body cannot force a huge allocation.
fn max_encoded_len(decoded_max: usize) -> usize {
    // 4 encoded chars per 3 bytes, plus padding/slack.
    decoded_max / 3 * 4 + 8
}

/// `PUT /api/v1/threads/{id}/bindings/{member}` body.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PutThreadBindingRequest {
    pub session_id: String,
}

/// `POST /api/v1/sessions/{id}/attachments` body.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadAttachmentRequest {
    pub filename: String,
    pub content_type: String,
    pub data_base64: String,
}

/// `PUT /api/v1/members/{id}/avatar` body.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadAvatarRequest {
    pub content_type: String,
    pub data_base64: String,
}

/// `POST /api/v1/sessions/{id}/messages` body: frozen request + optional
/// attachment references (superset; empty list is byte-identical to today).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendSessionMessageHttpRequest {
    pub text: String,
    #[serde(default)]
    pub request_id: Option<String>,
    #[serde(default)]
    pub attachment_ids: Vec<String>,
}

/// Map a store error onto the HTTP contract: invalid input is a client error
/// (400), IO/corruption is an honest 502.
pub fn store_error(error: StoreError) -> ApiError {
    match error {
        StoreError::Invalid { message } => {
            ApiError::Contract(PharosApiError::InvalidRequest { message })
        }
        other => ApiError::Contract(PharosApiError::OperationFailed {
            message: other.to_string(),
        }),
    }
}

/// Strict standard base64 decoder (dependency-free).
///
/// Rejects a non-zero trailing bit count, characters outside the alphabet and
/// wrong/absent padding instead of returning silently truncated bytes.
pub fn decode_base64(input: &str) -> Result<Vec<u8>, String> {
    let bytes = input.as_bytes();
    if bytes.is_empty() {
        return Ok(Vec::new());
    }
    if bytes.len() % 4 != 0 {
        return Err("base64 length must be a multiple of 4".to_string());
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    for (index, chunk) in bytes.chunks(4).enumerate() {
        let last = index + 1 == bytes.len() / 4;
        let mut values = [0u8; 4];
        let mut padding = 0usize;
        for (position, &byte) in chunk.iter().enumerate() {
            let value = match byte {
                b'A'..=b'Z' => byte - b'A',
                b'a'..=b'z' => byte - b'a' + 26,
                b'0'..=b'9' => byte - b'0' + 52,
                b'+' => 62,
                b'/' => 63,
                b'=' => {
                    // Padding is only valid at the end of the input.
                    if !last || position < 2 {
                        return Err("base64 padding in the middle of the input".to_string());
                    }
                    padding += 1;
                    continue;
                }
                _ => return Err(format!("invalid base64 character {:?}", byte as char)),
            };
            if padding > 0 {
                return Err("base64 padding must be trailing".to_string());
            }
            values[position] = value;
        }
        out.push((values[0] << 2) | (values[1] >> 4));
        if padding < 2 {
            out.push((values[1] << 4) | (values[2] >> 2));
        }
        if padding == 0 {
            out.push((values[2] << 6) | values[3]);
        }
    }
    Ok(out)
}

// --- thread ↔ session bindings ---------------------------------------------

/// Validate that `member` is acceptable as a Thread member name.
fn validate_member_name(member: &str) -> Result<(), ApiError> {
    let valid = !member.is_empty()
        && member.chars().count() <= 40
        && member
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if valid {
        Ok(())
    } else {
        Err(PharosApiError::InvalidRequest {
            message: format!("member name {member:?} must be 1..=40 chars of [A-Za-z0-9_-]"),
        }
        .into())
    }
}

async fn thread_summary(state: &AppState, thread_id: &str) -> ApiResult<ThreadSummary> {
    state
        .threads
        .get_thread(thread_id)
        .await
        .map_err(Into::into)
}

pub async fn list_thread_bindings(
    State(state): State<AppState>,
    Path(thread_id): Path<String>,
) -> ApiResult<Json<Value>> {
    thread_summary(&state, &thread_id).await?;
    let bindings = state.bindings.list(&thread_id).await.map_err(store_error)?;
    Ok(Json(json!({ "bindings": bindings })))
}

pub async fn get_thread_binding(
    State(state): State<AppState>,
    Path((thread_id, member)): Path<(String, String)>,
) -> ApiResult<Json<Value>> {
    thread_summary(&state, &thread_id).await?;
    match state
        .bindings
        .get(&thread_id, &member)
        .await
        .map_err(store_error)?
    {
        Some(binding) => Ok(Json(json!(binding))),
        None => Err(ApiError::thread_binding_not_found(&thread_id, &member)),
    }
}

pub async fn put_thread_binding(
    State(state): State<AppState>,
    Path((thread_id, member)): Path<(String, String)>,
    Json(body): Json<PutThreadBindingRequest>,
) -> ApiResult<Json<Value>> {
    thread_summary(&state, &thread_id).await?;
    validate_member_name(&member)?;
    if body.session_id.trim().is_empty() {
        return Err(PharosApiError::InvalidRequest {
            message: "sessionId must not be blank".to_string(),
        }
        .into());
    }
    // Validate against the current inventory: a binding must reference a real
    // session (local now, remote once the cross-host stream composes inventory).
    let session = state.sessions.get_session(&body.session_id).await?;
    let binding = ThreadBinding::new(
        thread_id.clone(),
        member.clone(),
        body.session_id.clone(),
        Some(session.agent_type.clone()),
    );
    let stored = state.bindings.upsert(binding).await.map_err(store_error)?;
    Ok(Json(json!(stored)))
}

pub async fn delete_thread_binding(
    State(state): State<AppState>,
    Path((thread_id, member)): Path<(String, String)>,
) -> ApiResult<Json<Value>> {
    thread_summary(&state, &thread_id).await?;
    let removed = state
        .bindings
        .remove(&thread_id, &member)
        .await
        .map_err(store_error)?;
    if !removed {
        return Err(ApiError::thread_binding_not_found(&thread_id, &member));
    }
    Ok(Json(json!({
        "ok": true,
        "threadId": thread_id,
        "member": member,
        "removed": true,
    })))
}

/// `GET /api/v1/threads/{id}/members` — replica members plus bound session
/// members, each with its durable settings.
pub async fn thread_members(
    State(state): State<AppState>,
    Path(thread_id): Path<String>,
) -> ApiResult<Json<Value>> {
    let thread = thread_summary(&state, &thread_id).await?;
    let bindings = state.bindings.list(&thread_id).await.map_err(store_error)?;
    let sessions = state.sessions.list_sessions().await?;
    let mut member_ids: Vec<String> = thread.member_ids.clone();
    for binding in &bindings {
        if !member_ids.contains(&binding.member) {
            member_ids.push(binding.member.clone());
        }
    }
    let mut members = Vec::with_capacity(member_ids.len());
    for member_id in member_ids {
        let binding = bindings.iter().find(|binding| binding.member == member_id);
        let session = binding.and_then(|binding| {
            sessions
                .iter()
                .find(|session| session.session_id == binding.session_id)
        });
        let settings = state.members.get(&member_id).await.map_err(store_error)?;
        members.push(json!({
            "memberId": member_id,
            "nick": member_id,
            "agentType": session.map(|session| session.agent_type.clone())
                .or_else(|| binding.and_then(|binding| binding.agent_type.clone())),
            "machineId": session.map(|session| session.machine_id.clone()),
            "status": session.map(|session| session.status),
            "sessionId": binding.map(|binding| binding.session_id.clone()),
            "boundAt": binding.map(|binding| binding.bound_at.clone()),
            "settings": settings,
        }));
    }
    Ok(Json(json!({ "members": members })))
}

// --- session configuration --------------------------------------------------

pub async fn get_session_config(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
) -> ApiResult<Json<Value>> {
    let view = state
        .sessions
        .session_config(&session_id)
        .await
        .map_err(ApiError::from_capability_error)?;
    Ok(Json(json!(view)))
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct PatchSessionConfigRequest {
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub mode: Option<String>,
}

pub async fn patch_session_config(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
    Json(body): Json<PatchSessionConfigRequest>,
) -> ApiResult<Json<Value>> {
    let patch = crate::services::SessionConfigPatch {
        model: body.model,
        mode: body.mode,
    };
    if let Err(message) = patch.validate() {
        return Err(PharosApiError::InvalidRequest { message }.into());
    }
    let view = state
        .sessions
        .update_session_config(&session_id, patch)
        .await
        .map_err(ApiError::from_capability_error)?;
    Ok(Json(json!(view)))
}

// --- stop / revive ----------------------------------------------------------

pub async fn stop_session(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
) -> ApiResult<Json<Value>> {
    let response = state
        .sessions
        .stop_session(&session_id)
        .await
        .map_err(ApiError::from_capability_error)?;
    Ok(Json(json!(response)))
}

pub async fn revive_session(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
) -> ApiResult<Json<Value>> {
    let response = state
        .sessions
        .revive_session(&session_id)
        .await
        .map_err(ApiError::from_capability_error)?;
    Ok(Json(json!(response)))
}

// --- attachments ------------------------------------------------------------

pub async fn list_session_attachments(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
) -> ApiResult<Json<Value>> {
    state.sessions.get_session(&session_id).await?;
    let attachments = state
        .attachments
        .list_for_session(&session_id)
        .await
        .map_err(store_error)?;
    Ok(Json(json!({ "attachments": attachments })))
}

pub async fn upload_session_attachment(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
    Json(body): Json<UploadAttachmentRequest>,
) -> ApiResult<Json<Value>> {
    state.sessions.get_session(&session_id).await?;
    if body.data_base64.len() > max_encoded_len(MAX_ATTACHMENT_BYTES) {
        return Err(PharosApiError::InvalidRequest {
            message: format!("attachment exceeds the {MAX_ATTACHMENT_BYTES} byte limit"),
        }
        .into());
    }
    let bytes = decode_base64(&body.data_base64).map_err(|message| {
        ApiError::Contract(PharosApiError::InvalidRequest {
            message: format!("invalid base64 payload: {message}"),
        })
    })?;
    let metadata = state
        .attachments
        .create(
            &session_id,
            crate::services::UploadedAttachment {
                filename: body.filename,
                content_type: body.content_type,
                bytes,
            },
        )
        .await
        .map_err(store_error)?;
    Ok(Json(json!(metadata)))
}

pub async fn get_attachment(
    State(state): State<AppState>,
    Path(attachment_id): Path<String>,
) -> ApiResult<Json<Value>> {
    match state
        .attachments
        .get(&attachment_id)
        .await
        .map_err(store_error)?
    {
        Some(metadata) => Ok(Json(json!(metadata))),
        None => Err(ApiError::attachment_not_found(&attachment_id)),
    }
}

pub async fn get_attachment_content(
    State(state): State<AppState>,
    Path(attachment_id): Path<String>,
) -> ApiResult<Response> {
    let Some(metadata) = state
        .attachments
        .get(&attachment_id)
        .await
        .map_err(store_error)?
    else {
        return Err(ApiError::attachment_not_found(&attachment_id));
    };
    let Some(bytes) = state
        .attachments
        .read(&attachment_id)
        .await
        .map_err(store_error)?
    else {
        return Err(ApiError::attachment_not_found(&attachment_id));
    };
    Ok((
        StatusCode::OK,
        [(header::CONTENT_TYPE, metadata.content_type)],
        bytes,
    )
        .into_response())
}

// --- member settings / avatars ---------------------------------------------

fn serialize_settings(settings: MemberSettingsView, bindings: Vec<ThreadBinding>) -> Value {
    // The contract always exposes `bindings` (possibly empty); the store view
    // skips empty vectors, so build the wire object explicitly.
    let mut value = json!(settings);
    value["bindings"] = json!(bindings.iter().map(ThreadBinding::view).collect::<Vec<_>>());
    value
}

async fn settings_with_bindings(state: &AppState, member_id: &str) -> ApiResult<Value> {
    let settings = state.members.get(member_id).await.map_err(store_error)?;
    let bindings = state
        .bindings
        .for_member(member_id)
        .await
        .map_err(store_error)?;
    Ok(serialize_settings(settings, bindings))
}

pub async fn get_member(
    State(state): State<AppState>,
    Path(member_id): Path<String>,
) -> ApiResult<Json<Value>> {
    Ok(Json(settings_with_bindings(&state, &member_id).await?))
}

pub async fn patch_member(
    State(state): State<AppState>,
    Path(member_id): Path<String>,
    Json(body): Json<MemberSettingsPatch>,
) -> ApiResult<Json<Value>> {
    state
        .members
        .patch(&member_id, body)
        .await
        .map_err(store_error)?;
    Ok(Json(settings_with_bindings(&state, &member_id).await?))
}

pub async fn put_member_avatar(
    State(state): State<AppState>,
    Path(member_id): Path<String>,
    Json(body): Json<UploadAvatarRequest>,
) -> ApiResult<Json<Value>> {
    if body.data_base64.len() > max_encoded_len(MAX_AVATAR_BYTES) {
        return Err(PharosApiError::InvalidRequest {
            message: format!("avatar exceeds the {MAX_AVATAR_BYTES} byte limit"),
        }
        .into());
    }
    let bytes = decode_base64(&body.data_base64).map_err(|message| {
        ApiError::Contract(PharosApiError::InvalidRequest {
            message: format!("invalid base64 payload: {message}"),
        })
    })?;
    state
        .members
        .put_avatar(&member_id, &body.content_type, bytes)
        .await
        .map_err(store_error)?;
    Ok(Json(settings_with_bindings(&state, &member_id).await?))
}

pub async fn get_member_avatar(
    State(state): State<AppState>,
    Path(member_id): Path<String>,
) -> ApiResult<Response> {
    let avatar = state
        .members
        .get_avatar(&member_id)
        .await
        .map_err(store_error)?;
    let Some(avatar) = avatar else {
        return Err(ApiError::attachment_not_found(&format!(
            "avatar of member {member_id}"
        )));
    };
    Ok((
        StatusCode::OK,
        [(header::CONTENT_TYPE, avatar.content_type)],
        avatar.bytes,
    )
        .into_response())
}

pub async fn delete_member_avatar(
    State(state): State<AppState>,
    Path(member_id): Path<String>,
) -> ApiResult<Json<Value>> {
    let removed = state
        .members
        .delete_avatar(&member_id)
        .await
        .map_err(store_error)?;
    if !removed {
        return Err(ApiError::attachment_not_found(&format!(
            "avatar of member {member_id}"
        )));
    }
    Ok(Json(json!({ "ok": true, "memberId": member_id })))
}

// --- session message send with attachment references ------------------------

pub async fn send_session_message(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
    Json(body): Json<SendSessionMessageHttpRequest>,
) -> ApiResult<Json<Value>> {
    let request = SendSessionMessageRequest {
        text: body.text,
        request_id: body.request_id,
    };
    let turn = if body.attachment_ids.is_empty() {
        state.sessions.send_message(&session_id, request).await?
    } else {
        // Every referenced attachment must exist and belong to this session.
        for attachment_id in &body.attachment_ids {
            let Some(metadata) = state
                .attachments
                .get(attachment_id)
                .await
                .map_err(store_error)?
            else {
                return Err(ApiError::attachment_not_found(attachment_id));
            };
            if metadata.session_id != session_id {
                return Err(PharosApiError::InvalidRequest {
                    message: format!(
                        "attachment {attachment_id} belongs to session {}, not {session_id}",
                        metadata.session_id
                    ),
                }
                .into());
            }
        }
        state
            .sessions
            .send_message_with_attachments(&session_id, request, body.attachment_ids)
            .await
            .map_err(ApiError::from_capability_error)?
    };
    Ok(Json(json!(turn)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_decodes_known_vectors() {
        assert_eq!(decode_base64("").unwrap(), Vec::<u8>::new());
        assert_eq!(decode_base64("aGVsbG8=").unwrap(), b"hello");
        assert_eq!(decode_base64("aGVsbG8h").unwrap(), b"hello!");
        assert_eq!(decode_base64("AAEC").unwrap(), vec![0u8, 1, 2]);
    }

    #[test]
    fn base64_rejects_invalid_input() {
        assert!(decode_base64("a").is_err());
        assert!(decode_base64("aGVsbG8").is_err(), "missing padding");
        assert!(decode_base64("aGVsbG8*").is_err(), "bad char");
        assert!(decode_base64("aG=sbG8=").is_err(), "padding in the middle");
        assert!(decode_base64("====").is_err());
    }

    #[test]
    fn encoded_size_guard_allows_limits() {
        let encoded = max_encoded_len(MAX_ATTACHMENT_BYTES);
        assert!(encoded >= MAX_ATTACHMENT_BYTES);
        assert!(max_encoded_len(MAX_AVATAR_BYTES) >= MAX_AVATAR_BYTES);
    }
}
