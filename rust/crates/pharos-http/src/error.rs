//! Map contract / HTTP-extension errors → HTTP status + JSON `ErrorBody`.
//!
//! Most handlers fail with a frozen [`PharosApiError`]. The web-endpoints
//! stream adds a few *server-side extension* codes (`unsupportedField`,
//! `threadBindingNotFound`, `attachmentNotFound`, `memberNotFound`) without
//! touching the frozen `pharos-api` enum; they carry the same error envelope
//! plus an optional `field`.

use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use pharos_api::{CONTRACTS_VERSION, ErrorBody, PharosApiError};
use serde_json::json;

/// Axum response wrapper around contract errors and HTTP-layer extensions.
#[derive(Debug, Clone)]
pub enum ApiError {
    /// Frozen `pharos-api` contract error.
    Contract(PharosApiError),
    /// Additive server-side error code (see module docs).
    Web {
        status: StatusCode,
        code: &'static str,
        message: String,
        field: Option<String>,
    },
}

impl From<PharosApiError> for ApiError {
    fn from(value: PharosApiError) -> Self {
        Self::Contract(value)
    }
}

impl ApiError {
    /// A 502 for an honestly-unsupported feature/field (never a fake success).
    pub fn unsupported_field(field: impl Into<String>, message: impl Into<String>) -> Self {
        let field = field.into();
        Self::Web {
            status: StatusCode::BAD_GATEWAY,
            code: "unsupportedField",
            message: message.into(),
            field: Some(field),
        }
    }

    /// A 404 for a Thread↔session binding that does not exist.
    pub fn thread_binding_not_found(thread_id: &str, member: &str) -> Self {
        Self::Web {
            status: StatusCode::NOT_FOUND,
            code: "threadBindingNotFound",
            message: format!("thread {thread_id} member {member} has no bound session"),
            field: None,
        }
    }

    /// A 404 for an unknown attachment / avatar record.
    pub fn attachment_not_found(id: &str) -> Self {
        Self::Web {
            status: StatusCode::NOT_FOUND,
            code: "attachmentNotFound",
            message: format!("attachment {id} not found"),
            field: None,
        }
    }

    /// A 404 for an unknown member settings record.
    pub fn member_not_found(member_id: &str) -> Self {
        Self::Web {
            status: StatusCode::NOT_FOUND,
            code: "memberNotFound",
            message: format!("member {member_id} not found"),
            field: None,
        }
    }

    /// Map an `OperationFailed` marker message produced by
    /// [`crate::services::session::unsupported_field`] /
    /// [`crate::services::session::unsupported_operation`] onto the explicit
    /// 502 extension codes; any other contract error keeps its frozen mapping.
    pub fn from_capability_error(error: PharosApiError) -> Self {
        let PharosApiError::OperationFailed { message } = &error else {
            return Self::Contract(error);
        };
        if let Some(rest) = message.strip_prefix(crate::services::UNSUPPORTED_FIELD_PREFIX)
            && let Some((field, reason)) = rest.split_once("`: ")
        {
            return Self::unsupported_field(field, reason);
        }
        if let Some(rest) = message.strip_prefix(crate::services::UNSUPPORTED_OPERATION_PREFIX)
            && let Some((operation, reason)) = rest.split_once("`: ")
        {
            return Self::Web {
                status: StatusCode::BAD_GATEWAY,
                code: "unsupportedOperation",
                message: reason.to_string(),
                field: Some(operation.to_string()),
            };
        }
        Self::Contract(error)
    }

    pub fn status(&self) -> StatusCode {
        match self {
            Self::Contract(error) => match error {
                PharosApiError::SessionNotFound { .. }
                | PharosApiError::ThreadNotFound { .. }
                | PharosApiError::ApprovalNotFound { .. } => StatusCode::NOT_FOUND,
                PharosApiError::InvalidRequest { .. } => StatusCode::BAD_REQUEST,
                PharosApiError::Conflict { .. } => StatusCode::CONFLICT,
                PharosApiError::BackendUnreachable { .. }
                | PharosApiError::ConnectionFailed { .. }
                | PharosApiError::OperationFailed { .. } => StatusCode::BAD_GATEWAY,
            },
            Self::Web { status, .. } => *status,
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = self.status();
        match self {
            Self::Contract(error) => {
                let body = ErrorBody::new(error);
                (status, Json(body)).into_response()
            }
            Self::Web {
                code,
                message,
                field,
                ..
            } => {
                let mut error = json!({ "code": code, "message": message });
                if let Some(field) = field {
                    error["field"] = json!(field);
                }
                let body = json!({
                    "error": error,
                    "contractsVersion": CONTRACTS_VERSION,
                });
                (status, Json(body)).into_response()
            }
        }
    }
}

pub type ApiResult<T> = Result<T, ApiError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contract_errors_keep_frozen_status_mapping() {
        assert_eq!(
            ApiError::from(PharosApiError::ThreadNotFound { id: "t".into() }).status(),
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            ApiError::from(PharosApiError::InvalidRequest {
                message: "bad".into()
            })
            .status(),
            StatusCode::BAD_REQUEST
        );
        assert_eq!(
            ApiError::from(PharosApiError::OperationFailed {
                message: "boom".into()
            })
            .status(),
            StatusCode::BAD_GATEWAY
        );
    }

    #[test]
    fn extension_errors_have_explicit_status_and_code() {
        let error = ApiError::unsupported_field("model", "adapter cannot change model");
        assert_eq!(error.status(), StatusCode::BAD_GATEWAY);
        let error = ApiError::thread_binding_not_found("t1", "grokbot");
        assert_eq!(error.status(), StatusCode::NOT_FOUND);
    }
}
