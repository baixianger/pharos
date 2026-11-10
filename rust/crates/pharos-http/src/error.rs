//! Map `PharosApiError` → HTTP status + JSON `ErrorBody`.

use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use pharos_api::{ErrorBody, PharosApiError};

/// Axum response wrapper around contract errors.
#[derive(Debug, Clone)]
pub struct ApiError(pub PharosApiError);

impl From<PharosApiError> for ApiError {
    fn from(value: PharosApiError) -> Self {
        Self(value)
    }
}

impl ApiError {
    fn status(&self) -> StatusCode {
        match &self.0 {
            PharosApiError::SessionNotFound { .. }
            | PharosApiError::ThreadNotFound { .. }
            | PharosApiError::ApprovalNotFound { .. } => StatusCode::NOT_FOUND,
            PharosApiError::InvalidRequest { .. } => StatusCode::BAD_REQUEST,
            PharosApiError::Conflict { .. } => StatusCode::CONFLICT,
            PharosApiError::BackendUnreachable { .. }
            | PharosApiError::ConnectionFailed { .. }
            | PharosApiError::OperationFailed { .. } => StatusCode::BAD_GATEWAY,
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = self.status();
        let body = ErrorBody::new(self.0);
        (status, Json(body)).into_response()
    }
}

pub type ApiResult<T> = Result<T, ApiError>;
