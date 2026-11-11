//! Minimal bearer-token auth for non-loopback `pharos-web` binds.
//!
//! The web server is local-first: binds are restricted to loopback unless the
//! operator supplies a token (see [`crate::validate_bind`]). When a token is
//! configured every API route requires either:
//!
//! - `Authorization: Bearer <token>` (scheme case-insensitive), or
//! - `?token=<token>` in the query string — needed by browser `WebSocket`
//!   clients and simple clients that cannot set headers.
//!
//! Static Web UI assets are served outside the API router and therefore never
//! require auth. `/health` is also reachable unauthenticated so a client can
//! tell a live server apart from a wrong-token 401 before it has the token.

use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;

use axum::extract::{Query, State};
use axum::http::{StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::{Json, Router};

/// Liveness route that stays reachable without a token.
///
/// Kept in sync with `pharos_api::routes::HEALTH`; hardcoded here so the
/// middleware stays independent of the router crate.
const UNAUTHENTICATED_PATHS: &[&str] = &["/health"];

/// A validated, non-blank bearer token.
///
/// The inner value is private and its [`fmt::Debug`] implementation redacts the
/// secret so token material cannot leak into logs or test failures.
#[derive(Clone)]
pub struct AuthToken(Arc<str>);

impl AuthToken {
    /// Validate and wrap a token. Empty or whitespace-only tokens are rejected.
    pub fn new(token: impl Into<String>) -> Result<Self, String> {
        let token = token.into();
        if token.trim().is_empty() {
            return Err("auth token must not be empty or blank".to_string());
        }
        Ok(Self(Arc::from(token)))
    }

    /// Borrow the raw token (for client construction / logs where needed).
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Constant-time-ish comparison against a candidate token.
    ///
    /// XORs every byte over the longer of the two inputs (missing bytes count
    /// as `0`) and folds the length difference into the same accumulator, so
    /// the loop runtime depends only on the longest input length, not on the
    /// position of the first mismatch.
    pub fn matches(&self, candidate: &str) -> bool {
        constant_time_eq(self.0.as_bytes(), candidate.as_bytes())
    }
}

impl fmt::Debug for AuthToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AuthToken(<redacted>)")
    }
}

fn constant_time_eq(expected: &[u8], candidate: &[u8]) -> bool {
    let mut diff: usize = expected.len() ^ candidate.len();
    let max = expected.len().max(candidate.len());
    for index in 0..max {
        let expected_byte = expected.get(index).copied().unwrap_or(0);
        let candidate_byte = candidate.get(index).copied().unwrap_or(0);
        diff |= usize::from(expected_byte ^ candidate_byte);
    }
    diff == 0
}

/// Axum middleware: require a valid bearer token on API routes.
///
/// Accepts `Authorization: Bearer <token>` (scheme case-insensitive) or the
/// `token` query parameter. Unauthenticated liveness paths
/// ([`UNAUTHENTICATED_PATHS`]) pass through.
pub async fn require_bearer(
    State(token): State<AuthToken>,
    request: axum::extract::Request,
    next: Next,
) -> Response {
    if UNAUTHENTICATED_PATHS.contains(&request.uri().path()) {
        return next.run(request).await;
    }

    let candidate = header_token(&request).or_else(|| query_token(&request));
    if candidate.is_some_and(|candidate| token.matches(&candidate)) {
        return next.run(request).await;
    }

    unauthorized()
}

/// Apply [`require_bearer`] to every route currently in `router`.
///
/// Routes/fallback added after this call are not wrapped, so build the API
/// router first and add the static-file fallback afterwards.
pub fn with_bearer_auth(router: Router, token: AuthToken) -> Router {
    router.layer(middleware::from_fn_with_state(token, require_bearer))
}

fn header_token(request: &axum::extract::Request) -> Option<String> {
    let value = request.headers().get(header::AUTHORIZATION)?;
    let value = value.to_str().ok()?;
    let mut parts = value.split_whitespace();
    let scheme = parts.next()?;
    let candidate = parts.next()?;
    if parts.next().is_some() || !scheme.eq_ignore_ascii_case("bearer") {
        return None;
    }
    Some(candidate.to_string())
}

fn query_token(request: &axum::extract::Request) -> Option<String> {
    Query::<HashMap<String, String>>::try_from_uri(request.uri())
        .ok()
        .and_then(|query| query.0.get("token").cloned())
}

fn unauthorized() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        Json(serde_json::json!({
            "error": {
                "code": "unauthorized",
                "message": "missing or invalid bearer token",
            }
        })),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::to_bytes;
    use axum::http::Request;
    use axum::routing::get;
    use serde_json::Value;
    use tower::ServiceExt;

    fn token() -> AuthToken {
        AuthToken::new("s3cret-token").expect("valid token")
    }

    fn app() -> Router {
        with_bearer_auth(
            Router::new()
                .route("/api/v1/threads", get(|| async { "threads-ok" }))
                .route("/health", get(|| async { "healthy" })),
            token(),
        )
    }

    async fn call(app: Router, request: Request<axum::body::Body>) -> (StatusCode, String) {
        let response = app.oneshot(request).await.expect("router call");
        let status = response.status();
        let body = to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body");
        (status, String::from_utf8_lossy(&body).into_owned())
    }

    fn get_request(uri: &str) -> Request<axum::body::Body> {
        Request::builder()
            .uri(uri)
            .body(axum::body::Body::empty())
            .unwrap()
    }

    async fn unauthorized_body(app: Router, request: Request<axum::body::Body>) {
        let (status, body) = call(app, request).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        let json: Value = serde_json::from_str(&body).expect("json error body");
        assert_eq!(json["error"]["code"], "unauthorized");
        assert_eq!(json["error"]["message"], "missing or invalid bearer token");
    }

    #[tokio::test]
    async fn missing_authorization_is_401() {
        unauthorized_body(app(), get_request("/api/v1/threads")).await;
    }

    #[tokio::test]
    async fn wrong_token_is_401() {
        let request = Request::builder()
            .uri("/api/v1/threads")
            .header(header::AUTHORIZATION, "Bearer not-the-token")
            .body(axum::body::Body::empty())
            .unwrap();
        unauthorized_body(app(), request).await;
    }

    #[tokio::test]
    async fn wrong_query_token_is_401() {
        unauthorized_body(app(), get_request("/api/v1/threads?token=nope")).await;
    }

    #[tokio::test]
    async fn correct_bearer_header_is_200() {
        let request = Request::builder()
            .uri("/api/v1/threads")
            .header(header::AUTHORIZATION, "Bearer s3cret-token")
            .body(axum::body::Body::empty())
            .unwrap();
        let (status, body) = call(app(), request).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, "threads-ok");
    }

    #[tokio::test]
    async fn bearer_scheme_is_case_insensitive() {
        let request = Request::builder()
            .uri("/api/v1/threads")
            .header(header::AUTHORIZATION, "bEaReR s3cret-token")
            .body(axum::body::Body::empty())
            .unwrap();
        let (status, _) = call(app(), request).await;
        assert_eq!(status, StatusCode::OK);
    }

    #[tokio::test]
    async fn correct_query_token_is_200() {
        let (status, body) = call(app(), get_request("/api/v1/threads?token=s3cret-token")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, "threads-ok");
    }

    #[tokio::test]
    async fn health_stays_public() {
        let (status, body) = call(app(), get_request("/health")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, "healthy");
    }

    #[test]
    fn new_rejects_empty_and_blank_tokens() {
        assert!(AuthToken::new("").is_err());
        assert!(AuthToken::new("   ").is_err());
        assert!(AuthToken::new("\t\n ").is_err());
        assert!(AuthToken::new("token").is_ok());
    }

    #[test]
    fn matches_accepts_exact_and_rejects_mismatches() {
        let token = token();
        assert!(token.matches("s3cret-token"));
        assert!(!token.matches("s3cret-toke"));
        assert!(!token.matches("s3cret-token-extra"));
        assert!(!token.matches(""));
        assert!(!token.matches("S3CRET-TOKEN"));
        assert!(!token.matches("s3cret-tokem"));
    }

    #[test]
    fn matches_folds_length_differences() {
        // A shared prefix with a longer candidate must not compare equal, and
        // the length fold must not be truncated (256-byte difference would
        // vanish if the length XOR were squeezed into a single byte).
        let token = AuthToken::new("abcd").unwrap();
        assert!(token.matches("abcd"));
        assert!(!token.matches("abcde"));
        assert!(!token.matches(&format!("abcd{}", "x".repeat(252))));
        assert!(!token.matches(&"x".repeat(256)));
    }

    #[test]
    fn constant_time_eq_is_correct_for_all_short_cases() {
        for a in ["", "a", "ab", "abc"] {
            for b in ["", "a", "ab", "abc", "abcd"] {
                assert_eq!(constant_time_eq(a.as_bytes(), b.as_bytes()), a == b);
            }
        }
    }

    #[test]
    fn debug_redacts_token() {
        let rendered = format!("{token:?}", token = token());
        assert!(rendered.contains("redacted"));
        assert!(!rendered.contains("s3cret-token"));
    }
}
