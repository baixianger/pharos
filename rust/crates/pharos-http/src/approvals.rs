//! `GET /api/v1/approvals` — current pending HITL approval snapshot.
//!
//! Browsers fetch this on page load / WebSocket reconnect so an approval that
//! arrived before the event subscription is not lost. This route is additive:
//! the existing `GET /api/v1/events` stream and session routes are unchanged.

use axum::Json;
use axum::extract::{Query, State};
use pharos_api::PharosApiError;
use serde::Deserialize;

use crate::error::ApiResult;
use crate::services::PendingApprovalListResponse;
use crate::state::AppState;

/// Route mounted by [`crate::router::api_router`].
pub const APPROVALS_ROUTE: &str = "/api/v1/approvals";

/// Query string for the snapshot endpoint.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApprovalsQuery {
    /// Only `pending` is supported today; omitted means `pending`.
    pub state: Option<String>,
    /// Optional session filter (all sessions when omitted).
    pub session_id: Option<String>,
}

/// Serve the durable pending-approval snapshot.
pub async fn list_approvals(
    State(state): State<AppState>,
    Query(query): Query<ApprovalsQuery>,
) -> ApiResult<Json<PendingApprovalListResponse>> {
    match query.state.as_deref() {
        None | Some("pending") => {}
        Some(other) => {
            return Err(PharosApiError::InvalidRequest {
                message: format!(
                    "unsupported approvals state {other:?} (only \"pending\" is available)"
                ),
            }
            .into());
        }
    }
    let session_id = query
        .session_id
        .filter(|value| !value.trim().is_empty());
    let approvals = state.approvals.list_pending(session_id).await?;
    Ok(Json(PendingApprovalListResponse { approvals }))
}
