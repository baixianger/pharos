//! End-to-end HTTP tests for the rust/web-endpoints routes served by the real
//! `pharos-web` HTTP stack over real sockets and a real `tempfile` data dir.
//!
//! Coverage:
//! - fake/production-composition mode (`persistent_app_state`: fake S1/S2,
//!   file-backed bindings/member settings/avatars/attachments) round-trip and
//!   **restart persistence**;
//! - `400 invalidRequest` validation for every write body;
//! - `404` extension codes (`threadBindingNotFound`, `attachmentNotFound`,
//!   `memberNotFound`, `threadNotFound`, `sessionNotFound`);
//! - honest `502 unsupportedField` / `unsupportedOperation` for an adapter that
//!   genuinely cannot apply a configuration field or operation (never a fake
//!   success);
//! - fake config/stop/revive/attachment-send capabilities end to end.
//!
//! The real (unconfigured) backend has no sessions at all, so its capability
//! errors are covered by the adapter-shaped test at the bottom.

use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use pharos_api::{
    CanonicalTurn, HostInventorySnapshot, HostInventoryStatus, PharosApiError, ProjectSummary,
    ResolveApprovalRequest, SendSessionMessageRequest, SessionActivityStatus, SessionProgress,
    SessionSummary, SteerSessionRequest, TurnStatus,
};
use pharos_http::AppState;
use pharos_http::services::SessionAdapterChoice;
use pharos_http::services::fake::ids as fake_ids;
use pharos_http::services::{
    FakeThreadService, InMemoryApprovalService, InMemoryAttachmentService,
    InMemoryMemberSettingsService, InMemoryThreadBindingService, SessionConfigView, SessionService,
    UploadedAttachment,
};
use pharos_web::{
    AuthToken, persistent_app_state, real_app_state, resolve_webui_dir, serve_ephemeral,
    serve_ephemeral_with_token,
};
use reqwest::StatusCode;
use serde_json::{Value, json};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

/// SHA-256 of `b"hello world"` (used for deterministic attachment/avatar checks).
const HELLO_WORLD_SHA256: &str = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";

fn webui() -> PathBuf {
    resolve_webui_dir(None).expect("webui/ must exist at the repo root")
}

fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .expect("http client")
}

/// Minimal standard base64 encoder (no crate dependency in pharos-web).
fn base64_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        match chunk {
            [b0, b1, b2] => {
                out.push(ALPHABET[(b0 >> 2) as usize] as char);
                out.push(ALPHABET[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
                out.push(ALPHABET[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char);
                out.push(ALPHABET[(b2 & 0x3f) as usize] as char);
            }
            [b0, b1] => {
                out.push(ALPHABET[(b0 >> 2) as usize] as char);
                out.push(ALPHABET[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
                out.push(ALPHABET[((b1 & 0x0f) << 2) as usize] as char);
                out.push('=');
            }
            [b0] => {
                out.push(ALPHABET[(b0 >> 2) as usize] as char);
                out.push(ALPHABET[((b0 & 0x03) << 4) as usize] as char);
                out.push('=');
                out.push('=');
            }
            _ => unreachable!("chunks(3) yields 1..=3 bytes"),
        }
    }
    out
}

fn error_code(body: &Value) -> &str {
    body["error"]["code"].as_str().unwrap_or("<missing>")
}

fn error_field(body: &Value) -> &str {
    body["error"]["field"].as_str().unwrap_or("<missing>")
}

async fn get_json(client: &reqwest::Client, url: &str) -> (StatusCode, Value) {
    let response = client.get(url).send().await.expect("GET request");
    let status = response.status();
    let body = response
        .json()
        .await
        .unwrap_or_else(|error| panic!("GET {url} -> {status}: json decode: {error}"));
    (status, body)
}

async fn send_json(
    client: &reqwest::Client,
    method: reqwest::Method,
    url: &str,
    body: Value,
) -> (StatusCode, Value) {
    let response = client
        .request(method.clone(), url)
        .json(&body)
        .send()
        .await
        .expect("request");
    let status = response.status();
    let body = response
        .json()
        .await
        .unwrap_or_else(|error| panic!("{method} {url} -> {status}: json decode: {error}"));
    (status, body)
}

async fn post_json(client: &reqwest::Client, url: &str, body: Value) -> (StatusCode, Value) {
    send_json(client, reqwest::Method::POST, url, body).await
}

async fn put_json(client: &reqwest::Client, url: &str, body: Value) -> (StatusCode, Value) {
    send_json(client, reqwest::Method::PUT, url, body).await
}

async fn patch_json(client: &reqwest::Client, url: &str, body: Value) -> (StatusCode, Value) {
    send_json(client, reqwest::Method::PATCH, url, body).await
}

async fn delete_json(client: &reqwest::Client, url: &str) -> (StatusCode, Value) {
    let response = client.delete(url).send().await.expect("DELETE request");
    let status = response.status();
    let body = response.json().await.expect("DELETE json body");
    (status, body)
}

/// GET raw bytes + content type (attachment / avatar content routes).
async fn get_bytes(client: &reqwest::Client, url: &str) -> (StatusCode, Option<String>, Vec<u8>) {
    let response = client.get(url).send().await.expect("GET bytes");
    let status = response.status();
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(ToString::to_string);
    let bytes = response.bytes().await.expect("bytes body").to_vec();
    (status, content_type, bytes)
}

fn png_avatar() -> Vec<u8> {
    // Arbitrary bytes: the store checks the declared content type + size, not
    // image decoding (Swift renders it).
    b"hello world".to_vec()
}

fn session_url(base: &str, session_id: &str, suffix: &str) -> String {
    format!("{base}/api/v1/sessions/{session_id}{suffix}")
}

fn thread_url(base: &str, thread_id: &str, suffix: &str) -> String {
    format!("{base}/api/v1/threads/{thread_id}{suffix}")
}

async fn shutdown(handle: tokio::task::JoinHandle<()>) {
    handle.abort();
    let _ = handle.await;
}

// ---------------------------------------------------------------------------
// 1. fake composition mode: round-trip + restart persistence
// ---------------------------------------------------------------------------

#[tokio::test]
async fn fake_mode_web_endpoints_round_trip_and_restart_persistence() {
    let data_dir = tempfile::tempdir().expect("tempdir");
    let webui_dir = webui();
    let client = client();
    let thread = fake_ids::THREAD;
    let session = fake_ids::SESSION;

    let (attachment_id, avatar_sha);
    {
        let state = persistent_app_state(data_dir.path()).expect("persistent fake state");
        let (addr, handle) = serve_ephemeral(webui_dir.clone(), state)
            .await
            .expect("serve ephemeral");
        let base = format!("http://{addr}");

        // --- thread members before any binding -----------------------------
        let (status, members) = get_json(&client, &thread_url(&base, thread, "/members")).await;
        assert_eq!(status, StatusCode::OK, "thread members: {members}");
        let members = members["members"].as_array().expect("members array");
        assert!(members.iter().any(|member| member["memberId"] == "human"));
        assert!(members.iter().any(|member| member["memberId"] == "grokbot"));
        let human = members
            .iter()
            .find(|member| member["memberId"] == "human")
            .expect("human member");
        assert_eq!(human["nick"], "human");
        assert_eq!(human["sessionId"], Value::Null);
        assert_eq!(human["settings"]["memberId"], "human");
        assert_eq!(human["settings"]["avatar"], Value::Null);
        // `settings` in the thread member list is the store view; the router
        // composes `bindings` only on the dedicated member routes.
        assert!(
            human["settings"]["bindings"].is_null() || human["settings"]["bindings"] == json!([]),
            "unexpected settings.bindings: {}",
            human["settings"]["bindings"]
        );

        // --- session config: fake adapter is honestly supported ------------
        let (status, config) = get_json(&client, &session_url(&base, session, "/config")).await;
        assert_eq!(status, StatusCode::OK, "config: {config}");
        assert_eq!(config["sessionId"], session);
        assert_eq!(config["supported"], true);
        assert_eq!(config["supportedFields"], json!(["model", "mode"]));
        assert_eq!(config["model"], "fake-1");
        assert_eq!(config["mode"], "safe");
        assert_eq!(config["models"], json!(["fake-1"]));
        assert_eq!(
            config["modes"],
            json!([
                {"value": "safe", "name": "Safe"},
                {"value": "yolo", "name": "YOLO"}
            ])
        );
        assert_eq!(config["capabilities"]["attachments"], true);
        assert_eq!(config["capabilities"]["commands"], false);
        assert_eq!(config["capabilities"]["stop"], true);
        assert_eq!(config["capabilities"]["revive"], true);
        assert_eq!(config["readonly"], false);

        let (status, patched) = patch_json(
            &client,
            &session_url(&base, session, "/config"),
            json!({ "mode": "yolo", "model": "fake-2" }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "patch config: {patched}");
        assert_eq!(patched["mode"], "yolo");
        assert_eq!(patched["model"], "fake-2");
        let (_, config) = get_json(&client, &session_url(&base, session, "/config")).await;
        assert_eq!(config["mode"], "yolo");
        assert_eq!(config["model"], "fake-2");

        // --- stop / revive --------------------------------------------------
        let (status, stopped) =
            post_json(&client, &session_url(&base, session, "/stop"), json!({})).await;
        assert_eq!(status, StatusCode::OK, "stop: {stopped}");
        assert_eq!(stopped["ok"], true);
        assert_eq!(stopped["sessionId"], session);
        assert_eq!(stopped["status"], "stopped");
        let (_, summary) = get_json(&client, &session_url(&base, session, "")).await;
        assert_eq!(summary["status"], "stopped");
        let (status, revived) =
            post_json(&client, &session_url(&base, session, "/revive"), json!({})).await;
        assert_eq!(status, StatusCode::OK, "revive: {revived}");
        assert_eq!(revived["status"], "idle");

        // --- bindings: upsert / get / list / thread members -----------------
        let (status, binding) = put_json(
            &client,
            &thread_url(&base, thread, "/bindings/grokbot"),
            json!({ "sessionId": session }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "put binding: {binding}");
        assert_eq!(binding["threadId"], thread);
        assert_eq!(binding["member"], "grokbot");
        assert_eq!(binding["sessionId"], session);
        assert_eq!(binding["agentType"], "fake");
        assert!(
            binding["boundAt"]
                .as_str()
                .is_some_and(|value| value.ends_with('Z')),
            "boundAt must be RFC3339: {binding}"
        );

        let (status, fetched) =
            get_json(&client, &thread_url(&base, thread, "/bindings/grokbot")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(fetched, binding);
        let (status, listed) = get_json(&client, &thread_url(&base, thread, "/bindings")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(listed["bindings"], json!([binding]));

        let (_, members) = get_json(&client, &thread_url(&base, thread, "/members")).await;
        let bound = members["members"]
            .as_array()
            .expect("members")
            .iter()
            .find(|member| member["memberId"] == "grokbot")
            .expect("grokbot member")
            .clone();
        assert_eq!(bound["sessionId"], session);
        assert_eq!(bound["agentType"], "fake");
        assert_eq!(bound["machineId"], "fake-host");

        // --- member settings / avatar ---------------------------------------
        let (status, member) = get_json(&client, &format!("{base}/api/v1/members/human")).await;
        assert_eq!(status, StatusCode::OK, "get member: {member}");
        assert_eq!(member["memberId"], "human");
        assert_eq!(member["displayName"], Value::Null);
        assert_eq!(member["avatar"], Value::Null);
        assert_eq!(member["bindings"], json!([]));

        let (status, updated) = patch_json(
            &client,
            &format!("{base}/api/v1/members/human"),
            json!({
                "displayName": "Pai",
                "model": "gpt-5",
                "mode": "safe",
                "avatarShape": "circle",
                "avatarColor": "#112233",
            }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "patch member: {updated}");
        assert_eq!(updated["displayName"], "Pai");
        assert_eq!(updated["model"], "gpt-5");
        assert_eq!(updated["mode"], "safe");
        assert_eq!(updated["avatarShape"], "circle");
        assert_eq!(updated["avatarColor"], "#112233");
        assert!(updated["updatedAt"].as_str().is_some());

        let avatar_bytes = png_avatar();
        let (status, with_avatar) = put_json(
            &client,
            &format!("{base}/api/v1/members/human/avatar"),
            json!({
                "contentType": "image/png",
                "dataBase64": base64_encode(&avatar_bytes),
            }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "put avatar: {with_avatar}");
        let avatar = &with_avatar["avatar"];
        assert_eq!(avatar["contentType"], "image/png");
        assert_eq!(avatar["sizeBytes"], avatar_bytes.len());
        assert_eq!(avatar["sha256"], HELLO_WORLD_SHA256);
        assert_eq!(avatar["avatarId"], HELLO_WORLD_SHA256);
        avatar_sha = avatar["sha256"].as_str().expect("sha").to_string();

        let (status, content_type, bytes) =
            get_bytes(&client, &format!("{base}/api/v1/members/human/avatar")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(content_type.as_deref(), Some("image/png"));
        assert_eq!(bytes, avatar_bytes);

        // --- attachments -----------------------------------------------------
        let attachment_payload = b"hello world";
        let (status, attachment) = post_json(
            &client,
            &session_url(&base, session, "/attachments"),
            json!({
                "filename": "notes.txt",
                "contentType": "text/plain",
                "dataBase64": base64_encode(attachment_payload),
            }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "upload attachment: {attachment}");
        assert_eq!(attachment["sessionId"], session);
        assert_eq!(attachment["filename"], "notes.txt");
        assert_eq!(attachment["contentType"], "text/plain");
        assert_eq!(attachment["sizeBytes"], attachment_payload.len());
        assert_eq!(attachment["sha256"], HELLO_WORLD_SHA256);
        let id = attachment["attachmentId"]
            .as_str()
            .expect("attachment id")
            .to_string();
        assert_eq!(id.len(), 32, "attachment id must be 32 hex chars: {id}");
        assert!(
            id.bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
            "attachment id must be lowercase hex: {id}"
        );
        attachment_id = id.clone();

        let (status, metadata) =
            get_json(&client, &format!("{base}/api/v1/attachments/{id}")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(metadata, attachment);
        let (status, content_type, bytes) =
            get_bytes(&client, &format!("{base}/api/v1/attachments/{id}/content")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(content_type.as_deref(), Some("text/plain"));
        assert_eq!(bytes, attachment_payload.to_vec());
        let (status, list) = get_json(&client, &session_url(&base, session, "/attachments")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(list["attachments"], json!([attachment]));

        // --- send a message referencing the attachment ----------------------
        let (status, turn) = post_json(
            &client,
            &session_url(&base, session, "/messages"),
            json!({ "text": "please look at the notes", "attachmentIds": [id] }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "send with attachment: {turn}");
        assert_eq!(turn["sessionId"], session);
        assert_eq!(turn["status"], "completed");
        // And the plain frozen path is unchanged.
        let (status, plain_turn) = post_json(
            &client,
            &session_url(&base, session, "/messages"),
            json!({ "text": "plain message" }),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(plain_turn["status"], "completed");

        // --- durable files exist under the data dir -------------------------
        assert!(data_dir.path().join("thread-bindings.json").is_file());
        assert!(data_dir.path().join("member-settings.json").is_file());
        assert!(
            data_dir
                .path()
                .join("avatars")
                .join(format!("{avatar_sha}.png"))
                .is_file(),
            "avatar blob must be content-addressed under avatars/"
        );
        assert!(
            data_dir
                .path()
                .join("attachments")
                .join("index.json")
                .is_file()
        );
        assert!(
            data_dir
                .path()
                .join("attachments")
                .join(&attachment_id)
                .is_file()
        );

        shutdown(handle).await;
    }

    // --- restart: rebuild the server on the same data dir -------------------
    let state = persistent_app_state(data_dir.path()).expect("reopened persistent state");
    let (addr, handle) = serve_ephemeral(webui_dir, state)
        .await
        .expect("serve ephemeral after restart");
    let base = format!("http://{addr}");

    let (status, binding) =
        get_json(&client, &thread_url(&base, thread, "/bindings/grokbot")).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "binding must survive restart: {binding}"
    );
    assert_eq!(binding["sessionId"], session);
    let (status, members) = get_json(&client, &thread_url(&base, thread, "/bindings")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(members["bindings"].as_array().expect("bindings").len(), 1);

    let (status, member) = get_json(&client, &format!("{base}/api/v1/members/human")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(member["displayName"], "Pai");
    assert_eq!(member["avatarShape"], "circle");
    assert_eq!(member["avatarColor"], "#112233");
    assert_eq!(member["avatar"]["sha256"], avatar_sha);
    // Human has no binding; the bound member is grokbot.
    assert_eq!(member["bindings"], json!([]));
    let (status, grokbot) = get_json(&client, &format!("{base}/api/v1/members/grokbot")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        grokbot["bindings"],
        json!([{ "threadId": thread, "sessionId": session }])
    );

    let (status, content_type, bytes) =
        get_bytes(&client, &format!("{base}/api/v1/members/human/avatar")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(content_type.as_deref(), Some("image/png"));
    assert_eq!(bytes, png_avatar());

    let (status, content_type, bytes) = get_bytes(
        &client,
        &format!("{base}/api/v1/attachments/{attachment_id}/content"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(content_type.as_deref(), Some("text/plain"));
    assert_eq!(bytes, b"hello world".to_vec());
    let (status, list) = get_json(&client, &session_url(&base, session, "/attachments")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(list["attachments"].as_array().expect("list").len(), 1);

    shutdown(handle).await;
}

// ---------------------------------------------------------------------------
// 2. validation (400) and not-found (404) errors
// ---------------------------------------------------------------------------

#[tokio::test]
async fn web_endpoints_reject_invalid_input_and_missing_records() {
    let data_dir = tempfile::tempdir().expect("tempdir");
    let state = persistent_app_state(data_dir.path()).expect("persistent fake state");
    let (addr, handle) = serve_ephemeral(webui(), state)
        .await
        .expect("serve ephemeral");
    let base = format!("http://{addr}");
    let client = client();
    let thread = fake_ids::THREAD;
    let session = fake_ids::SESSION;

    // --- 400 invalidRequest: bindings ---------------------------------------
    let (status, body) = put_json(
        &client,
        &thread_url(&base, thread, "/bindings/human"),
        json!({ "sessionId": "   " }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "blank sessionId: {body}");
    assert_eq!(error_code(&body), "invalidRequest");

    let (status, body) = put_json(
        &client,
        &thread_url(&base, thread, "/bindings/not a member!"),
        json!({ "sessionId": session }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "bad member name: {body}");
    assert_eq!(error_code(&body), "invalidRequest");

    // Unknown session is an honest 404, not a stored dangling binding.
    let (status, body) = put_json(
        &client,
        &thread_url(&base, thread, "/bindings/human"),
        json!({ "sessionId": "does-not-exist" }),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "unknown session: {body}");
    assert_eq!(error_code(&body), "sessionNotFound");
    let (status, body) = get_json(&client, &thread_url(&base, thread, "/bindings/human")).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "unbound pair: {body}");
    assert_eq!(error_code(&body), "threadBindingNotFound");
    let (status, body) = delete_json(&client, &thread_url(&base, thread, "/bindings/human")).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "delete unbound: {body}");
    assert_eq!(error_code(&body), "threadBindingNotFound");

    // Unknown thread is threadNotFound for any binding/member read.
    for suffix in ["/bindings", "/bindings/human", "/members"] {
        let (status, body) = get_json(&client, &thread_url(&base, "no-such-thread", suffix)).await;
        assert_eq!(
            status,
            StatusCode::NOT_FOUND,
            "unknown thread {suffix}: {body}"
        );
        assert_eq!(error_code(&body), "threadNotFound");
    }

    // --- 400 invalidRequest: session config ---------------------------------
    let config_url = session_url(&base, session, "/config");
    let (status, body) = patch_json(&client, &config_url, json!({})).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "empty patch: {body}");
    assert_eq!(error_code(&body), "invalidRequest");
    let (status, body) = patch_json(&client, &config_url, json!({ "model": "   " })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "blank model: {body}");
    assert_eq!(error_code(&body), "invalidRequest");
    let (status, body) = patch_json(&client, &config_url, json!({ "mode": "turbo" })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "bad mode: {body}");
    assert_eq!(error_code(&body), "invalidRequest");

    // Unknown sessions answer sessionNotFound (never an invented config).
    for (method, suffix, body) in [
        (reqwest::Method::GET, "/config", Value::Null),
        (
            reqwest::Method::PATCH,
            "/config",
            json!({ "model": "gpt-5" }),
        ),
        (reqwest::Method::POST, "/stop", json!({})),
        (reqwest::Method::POST, "/revive", json!({})),
        (reqwest::Method::GET, "/attachments", Value::Null),
    ] {
        let url = session_url(&base, "no-such-session", suffix);
        let (status, body) = if method == reqwest::Method::GET {
            get_json(&client, &url).await
        } else {
            send_json(&client, method, &url, body).await
        };
        assert_eq!(
            status,
            StatusCode::NOT_FOUND,
            "{suffix} unknown session: {body}"
        );
        assert_eq!(error_code(&body), "sessionNotFound", "{suffix}: {body}");
    }
    let (status, body) = post_json(
        &client,
        &session_url(&base, "no-such-session", "/attachments"),
        json!({
            "filename": "a.txt",
            "contentType": "text/plain",
            "dataBase64": base64_encode(b"x"),
        }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "upload unknown session: {body}"
    );
    assert_eq!(error_code(&body), "sessionNotFound");

    // --- 400 invalidRequest: member settings --------------------------------
    let member_url = format!("{base}/api/v1/members/human");
    let (status, body) = patch_json(&client, &member_url, json!({})).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "empty member patch: {body}"
    );
    assert_eq!(error_code(&body), "invalidRequest");
    for bad in [
        json!({ "displayName": "" }),
        json!({ "displayName": "x".repeat(81) }),
        json!({ "model": "m".repeat(121) }),
        json!({ "mode": "turbo" }),
        json!({ "avatarShape": "s".repeat(33) }),
        json!({ "avatarColor": " " }),
    ] {
        let (status, body) = patch_json(&client, &member_url, bad.clone()).await;
        assert_eq!(
            status,
            StatusCode::BAD_REQUEST,
            "invalid member patch {bad}: {body}"
        );
        assert_eq!(error_code(&body), "invalidRequest");
    }
    // Malformed member id.
    let long_member = "m".repeat(65);
    let (status, body) = get_json(&client, &format!("{base}/api/v1/members/{long_member}")).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "over-long member id: {body}"
    );
    assert_eq!(error_code(&body), "invalidRequest");

    // --- 400 invalidRequest: avatar uploads --------------------------------
    let avatar_url = format!("{base}/api/v1/members/human/avatar");
    for bad in [
        json!({ "contentType": "image/gif", "dataBase64": base64_encode(b"x") }),
        json!({ "contentType": "text/plain", "dataBase64": base64_encode(b"x") }),
        json!({ "contentType": "image/png", "dataBase64": "" }),
        json!({ "contentType": "image/png", "dataBase64": "not base64!" }),
    ] {
        let (status, body) = put_json(&client, &avatar_url, bad.clone()).await;
        assert_eq!(
            status,
            StatusCode::BAD_REQUEST,
            "invalid avatar {bad}: {body}"
        );
        assert_eq!(error_code(&body), "invalidRequest");
    }
    // No avatar stored -> explicit attachmentNotFound for GET/DELETE.
    let (status, body) = get_json(&client, &avatar_url).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "no avatar: {body}");
    assert_eq!(error_code(&body), "attachmentNotFound");
    let (status, body) = delete_json(&client, &avatar_url).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "delete no avatar: {body}");
    assert_eq!(error_code(&body), "attachmentNotFound");

    // --- 400 invalidRequest / 404: attachments ------------------------------
    let attachments_url = session_url(&base, session, "/attachments");
    for bad in [
        json!({ "filename": "", "contentType": "text/plain", "dataBase64": base64_encode(b"x") }),
        json!({ "filename": "a/b.txt", "contentType": "text/plain", "dataBase64": base64_encode(b"x") }),
        json!({ "filename": "a\\b.txt", "contentType": "text/plain", "dataBase64": base64_encode(b"x") }),
        json!({ "filename": "a.txt", "contentType": "text/html", "dataBase64": base64_encode(b"x") }),
        json!({ "filename": "a.txt", "contentType": "text/plain", "dataBase64": "" }),
        json!({ "filename": "a.txt", "contentType": "text/plain", "dataBase64": "not base64!" }),
    ] {
        let (status, body) = post_json(&client, &attachments_url, bad.clone()).await;
        assert_eq!(
            status,
            StatusCode::BAD_REQUEST,
            "invalid attachment {bad}: {body}"
        );
        assert_eq!(error_code(&body), "invalidRequest");
    }

    let unknown_attachment = "0123456789abcdef0123456789abcdef";
    let (status, body) = get_json(
        &client,
        &format!("{base}/api/v1/attachments/{unknown_attachment}"),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "unknown attachment: {body}");
    assert_eq!(error_code(&body), "attachmentNotFound");
    let (status, _content_type, body) = get_bytes(
        &client,
        &format!("{base}/api/v1/attachments/{unknown_attachment}/content"),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "unknown attachment content: {:?}",
        String::from_utf8_lossy(&body)
    );

    // Message attachment ids must exist and belong to the session.
    let (status, body) = post_json(
        &client,
        &session_url(&base, session, "/messages"),
        json!({ "text": "x", "attachmentIds": [unknown_attachment] }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "unknown attachment id: {body}"
    );
    assert_eq!(error_code(&body), "attachmentNotFound");

    // A thread that does not exist is 404 for messages too.
    let (status, body) = get_json(&client, &thread_url(&base, "no-such-thread", "/members")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(error_code(&body), "threadNotFound");

    shutdown(handle).await;
}

// ---------------------------------------------------------------------------
// 3. honest 502s for an adapter that cannot apply the operation
// ---------------------------------------------------------------------------

const ADAPTER_SESSION: &str = "adapter-session-1";

/// Session service for an adapter that exposes exactly one session but cannot
/// report configuration, change it, stop/revive it, cancel turns or consume
/// attachment bytes. Every unsupported path must answer an explicit 502.
#[derive(Debug, Clone, Copy)]
struct UnsupportedCapabilitySession;

impl UnsupportedCapabilitySession {
    fn summary() -> SessionSummary {
        SessionSummary {
            session_id: ADAPTER_SESSION.to_string(),
            machine_id: "adapter-host".to_string(),
            agent_type: "codex".to_string(),
            workspace_path: "/tmp/pharos-adapter-ws".to_string(),
            title: "Adapter Session".to_string(),
            status: SessionActivityStatus::Idle,
            latest_message_preview: None,
            updated_at: "2026-11-11T00:00:00Z".to_string(),
            avatar_seed: "codex".to_string(),
            inventory_stale: None,
            connection_route: Some("stdio".to_string()),
        }
    }

    fn ensure_known(session_id: &str) -> Result<(), PharosApiError> {
        if session_id == ADAPTER_SESSION {
            Ok(())
        } else {
            Err(PharosApiError::SessionNotFound {
                id: session_id.to_string(),
            })
        }
    }
}

type BoxedWithLifetime<'a, T> =
    Pin<Box<dyn Future<Output = Result<T, PharosApiError>> + Send + 'a>>;

macro_rules! known {
    ($session_id:expr) => {
        UnsupportedCapabilitySession::ensure_known($session_id)
    };
}

impl SessionService for UnsupportedCapabilitySession {
    fn list_sessions<'life0, 'async_trait>(
        &'life0 self,
    ) -> BoxedWithLifetime<'async_trait, Vec<SessionSummary>>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move { Ok(vec![Self::summary()]) })
    }

    fn get_session<'life0, 'life1, 'async_trait>(
        &'life0 self,
        session_id: &'life1 str,
    ) -> BoxedWithLifetime<'async_trait, SessionSummary>
    where
        'life0: 'async_trait,
        'life1: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            known!(session_id)?;
            Ok(Self::summary())
        })
    }

    fn list_history<'life0, 'life1, 'async_trait>(
        &'life0 self,
        session_id: &'life1 str,
    ) -> BoxedWithLifetime<'async_trait, Vec<CanonicalTurn>>
    where
        'life0: 'async_trait,
        'life1: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            known!(session_id)?;
            Ok(Vec::new())
        })
    }

    fn send_message<'life0, 'life1, 'async_trait>(
        &'life0 self,
        session_id: &'life1 str,
        request: SendSessionMessageRequest,
    ) -> BoxedWithLifetime<'async_trait, CanonicalTurn>
    where
        'life0: 'async_trait,
        'life1: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            known!(session_id)?;
            Ok(CanonicalTurn {
                turn_id: "adapter-turn-1".to_string(),
                session_id: session_id.to_string(),
                turn_number: 1,
                status: TurnStatus::Completed,
                created_at: "2026-11-11T00:00:01Z".to_string(),
                completed_at: Some("2026-11-11T00:00:02Z".to_string()),
                assistant_text: vec![format!("adapter echo: {}", request.text)],
            })
        })
    }

    fn steer<'life0, 'life1, 'async_trait>(
        &'life0 self,
        session_id: &'life1 str,
        _request: SteerSessionRequest,
    ) -> BoxedWithLifetime<'async_trait, ()>
    where
        'life0: 'async_trait,
        'life1: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            known!(session_id)?;
            Ok(())
        })
    }

    fn resolve_approval<'life0, 'life1, 'async_trait>(
        &'life0 self,
        session_id: &'life1 str,
        _request: ResolveApprovalRequest,
    ) -> BoxedWithLifetime<'async_trait, ()>
    where
        'life0: 'async_trait,
        'life1: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            known!(session_id)?;
            Ok(())
        })
    }

    fn progress<'life0, 'life1, 'async_trait>(
        &'life0 self,
        session_id: &'life1 str,
    ) -> BoxedWithLifetime<'async_trait, SessionProgress>
    where
        'life0: 'async_trait,
        'life1: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            known!(session_id)?;
            Ok(SessionProgress {
                goal: None,
                todos: Vec::new(),
            })
        })
    }

    fn list_projects<'life0, 'async_trait>(
        &'life0 self,
    ) -> BoxedWithLifetime<'async_trait, Vec<ProjectSummary>>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move { Ok(Vec::new()) })
    }

    fn inventory<'life0, 'async_trait>(
        &'life0 self,
    ) -> BoxedWithLifetime<'async_trait, HostInventorySnapshot>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            Ok(HostInventorySnapshot {
                sessions: vec![Self::summary()],
                status: HostInventoryStatus {
                    supported_agents: vec!["codex".to_string()],
                    unavailable_agents: Vec::new(),
                },
            })
        })
    }

    fn session_config<'life0, 'life1, 'async_trait>(
        &'life0 self,
        session_id: &'life1 str,
    ) -> BoxedWithLifetime<'async_trait, SessionConfigView>
    where
        'life0: 'async_trait,
        'life1: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            known!(session_id)?;
            Ok(SessionConfigView::unsupported(session_id))
        })
    }

    fn update_session_config<'life0, 'life1, 'async_trait>(
        &'life0 self,
        session_id: &'life1 str,
        patch: pharos_http::services::SessionConfigPatch,
    ) -> BoxedWithLifetime<'async_trait, SessionConfigView>
    where
        'life0: 'async_trait,
        'life1: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            known!(session_id)?;
            let field = if patch.model.is_some() {
                "model"
            } else {
                "mode"
            };
            Err(pharos_http::services::unsupported_field(
                field,
                "the codex session adapter does not support updating session configuration",
            ))
        })
    }

    fn stop_session<'life0, 'life1, 'async_trait>(
        &'life0 self,
        session_id: &'life1 str,
    ) -> BoxedWithLifetime<'async_trait, pharos_http::services::SessionLifecycleResponse>
    where
        'life0: 'async_trait,
        'life1: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            known!(session_id)?;
            Err(pharos_http::services::unsupported_operation(
                "stop",
                "the codex session adapter does not support stopping sessions",
            ))
        })
    }

    fn revive_session<'life0, 'life1, 'async_trait>(
        &'life0 self,
        session_id: &'life1 str,
    ) -> BoxedWithLifetime<'async_trait, pharos_http::services::SessionLifecycleResponse>
    where
        'life0: 'async_trait,
        'life1: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            known!(session_id)?;
            Err(pharos_http::services::unsupported_operation(
                "revive",
                "the codex session adapter does not support reviving sessions",
            ))
        })
    }

    fn send_message_with_attachments<'life0, 'life1, 'async_trait>(
        &'life0 self,
        session_id: &'life1 str,
        _request: SendSessionMessageRequest,
        _attachment_ids: Vec<String>,
    ) -> BoxedWithLifetime<'async_trait, CanonicalTurn>
    where
        'life0: 'async_trait,
        'life1: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            known!(session_id)?;
            Err(pharos_http::services::unsupported_field(
                "attachments",
                "the codex session adapter cannot consume message attachments",
            ))
        })
    }
}

#[tokio::test]
async fn unsupported_adapter_capabilities_answer_honest_502() {
    let events = pharos_http::EventBus::new(64);
    let state = Arc::new(AppState::with_extras(
        Arc::new(FakeThreadService::new(events.clone())),
        Arc::new(UnsupportedCapabilitySession),
        events,
        Arc::new(InMemoryApprovalService::new()),
        Arc::new(InMemoryThreadBindingService::new()),
        Arc::new(InMemoryMemberSettingsService::new()),
        Arc::new(InMemoryAttachmentService::new()),
    ));
    // Upload an attachment through the service so the message route can pass
    // its existence/session validation before hitting the unsupported adapter.
    let attachment = state
        .attachments
        .create(
            ADAPTER_SESSION,
            UploadedAttachment {
                filename: "notes.txt".to_string(),
                content_type: "text/plain".to_string(),
                bytes: b"hello world".to_vec(),
            },
        )
        .await
        .expect("seed attachment");
    let state = Arc::try_unwrap(state).unwrap_or_else(|_| panic!("unique state"));
    let (addr, handle) = serve_ephemeral(webui(), state)
        .await
        .expect("serve ephemeral");
    let base = format!("http://{addr}");
    let client = client();

    // Known session: honest empty config view (never invented values).
    let (status, config) = get_json(&client, &session_url(&base, ADAPTER_SESSION, "/config")).await;
    assert_eq!(status, StatusCode::OK, "config: {config}");
    assert_eq!(config["sessionId"], ADAPTER_SESSION);
    assert_eq!(config["supported"], false);
    assert_eq!(config["supportedFields"], json!([]));
    assert_eq!(config["model"], Value::Null);
    assert_eq!(config["mode"], Value::Null);
    assert_eq!(config["models"], json!([]));
    assert_eq!(config["modes"], json!([]));
    assert_eq!(config["readonly"], true);
    assert_eq!(config["capabilities"]["attachments"], false);
    assert_eq!(config["capabilities"]["stop"], false);
    assert_eq!(config["capabilities"]["revive"], false);

    // PATCH config: 502 unsupportedField with the exact field, never "saved".
    for (body, field) in [
        (json!({ "model": "gpt-5" }), "model"),
        (json!({ "mode": "yolo" }), "mode"),
    ] {
        let (status, error) = patch_json(
            &client,
            &session_url(&base, ADAPTER_SESSION, "/config"),
            body.clone(),
        )
        .await;
        assert_eq!(
            status,
            StatusCode::BAD_GATEWAY,
            "unsupported config {body}: {error}"
        );
        assert_eq!(error_code(&error), "unsupportedField");
        assert_eq!(error_field(&error), field);
        assert_eq!(error["contractsVersion"], "0.1.0");
        assert!(
            error["error"]["message"]
                .as_str()
                .is_some_and(|message| !message.is_empty()),
            "502 must carry a human message: {error}"
        );
    }

    // stop / revive: 502 unsupportedOperation (field names the operation).
    for operation in ["stop", "revive"] {
        let (status, error) = post_json(
            &client,
            &session_url(&base, ADAPTER_SESSION, &format!("/{operation}")),
            json!({}),
        )
        .await;
        assert_eq!(
            status,
            StatusCode::BAD_GATEWAY,
            "unsupported {operation}: {error}"
        );
        assert_eq!(error_code(&error), "unsupportedOperation");
        assert_eq!(error_field(&error), operation);
    }

    // Messages with attachments: 502 unsupportedField("attachments").
    let (status, error) = post_json(
        &client,
        &session_url(&base, ADAPTER_SESSION, "/messages"),
        json!({ "text": "see file", "attachmentIds": [attachment.attachment_id] }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::BAD_GATEWAY,
        "unsupported attachments: {error}"
    );
    assert_eq!(error_code(&error), "unsupportedField");
    assert_eq!(error_field(&error), "attachments");

    // The plain frozen message path still works through the same adapter.
    let (status, turn) = post_json(
        &client,
        &session_url(&base, ADAPTER_SESSION, "/messages"),
        json!({ "text": "plain" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "plain send: {turn}");
    assert_eq!(turn["turnId"], "adapter-turn-1");

    // Unknown session ids stay 404 for every capability route.
    for (method, suffix) in [
        (reqwest::Method::GET, "/config"),
        (reqwest::Method::POST, "/stop"),
        (reqwest::Method::POST, "/revive"),
        (reqwest::Method::GET, "/attachments"),
    ] {
        let url = session_url(&base, "missing-adapter-session", suffix);
        let (status, error) = if method == reqwest::Method::GET {
            get_json(&client, &url).await
        } else {
            post_json(&client, &url, json!({})).await
        };
        assert_eq!(
            status,
            StatusCode::NOT_FOUND,
            "unknown session {method} {suffix}: {error}"
        );
        assert_eq!(error_code(&error), "sessionNotFound");
    }

    shutdown(handle).await;
}

// ---------------------------------------------------------------------------
// 4. bearer-token auth matrix on the new routes (real app state)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn bearer_token_protects_new_web_routes() {
    let data_dir = tempfile::tempdir().expect("tempdir");
    let state = real_app_state(data_dir.path(), SessionAdapterChoice::None).expect("real state");
    let token = AuthToken::new("web-endpoints-token").expect("token");
    let (addr, handle) = serve_ephemeral_with_token(webui(), state, Some(token))
        .await
        .expect("serve ephemeral with token");
    let base = format!("http://{addr}");
    let client = client();

    // Liveness stays public before any token is supplied.
    let (status, health) = get_json(&client, &format!("{base}/health")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(health["ok"], true);

    // Every new write/read route is behind the bearer layer: no Authorization
    // header is a 401 *before* the handler runs (so no store is touched).
    for (method, path, body) in [
        (
            reqwest::Method::GET,
            "/api/v1/threads/t1/bindings",
            Value::Null,
        ),
        (
            reqwest::Method::PUT,
            "/api/v1/threads/t1/bindings/human",
            json!({ "sessionId": "s1" }),
        ),
        (
            reqwest::Method::GET,
            "/api/v1/threads/t1/members",
            Value::Null,
        ),
        (
            reqwest::Method::GET,
            "/api/v1/sessions/s1/config",
            Value::Null,
        ),
        (
            reqwest::Method::PATCH,
            "/api/v1/sessions/s1/config",
            json!({ "model": "gpt-5" }),
        ),
        (reqwest::Method::POST, "/api/v1/sessions/s1/stop", json!({})),
        (
            reqwest::Method::POST,
            "/api/v1/sessions/s1/revive",
            json!({}),
        ),
        (
            reqwest::Method::POST,
            "/api/v1/sessions/s1/attachments",
            json!({ "filename": "a.txt", "contentType": "text/plain", "dataBase64": "aGk=" }),
        ),
        (reqwest::Method::GET, "/api/v1/attachments/abc", Value::Null),
        (reqwest::Method::GET, "/api/v1/members/human", Value::Null),
        (
            reqwest::Method::PATCH,
            "/api/v1/members/human",
            json!({ "displayName": "Pai" }),
        ),
        (
            reqwest::Method::PUT,
            "/api/v1/members/human/avatar",
            json!({ "contentType": "image/png", "dataBase64": "aGk=" }),
        ),
        (
            reqwest::Method::GET,
            "/api/v1/members/human/avatar",
            Value::Null,
        ),
    ] {
        let url = format!("{base}{path}");
        let request = client.request(method.clone(), &url);
        let response = if method == reqwest::Method::GET {
            request.send().await.expect("unauth GET")
        } else {
            request.json(&body).send().await.expect("unauth write")
        };
        assert_eq!(
            response.status(),
            StatusCode::UNAUTHORIZED,
            "{method} {path} must require a token"
        );
        let error: Value = response.json().await.expect("401 json");
        assert_eq!(error_code(&error), "unauthorized", "{method} {path}");
    }

    // Bearer header reaches the handlers: known member -> 200, real backend
    // has no sessions / threads, so those are the honest 404s (not 401).
    let response = client
        .get(format!("{base}/api/v1/members/human"))
        .bearer_auth("web-endpoints-token")
        .send()
        .await
        .expect("authed GET member");
    assert_eq!(response.status(), StatusCode::OK);
    let member: Value = response.json().await.expect("member json");
    assert_eq!(member["memberId"], "human");
    assert_eq!(member["avatar"], Value::Null);

    // `?token=` is accepted for GETs (browser EventSource/fetch fallback).
    let (status, member) = get_json(
        &client,
        &format!("{base}/api/v1/members/human?token=web-endpoints-token"),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "query token: {member}");
    assert_eq!(member["memberId"], "human");

    for (path, expected_code) in [
        ("/api/v1/sessions/real-session/config", "sessionNotFound"),
        ("/api/v1/threads/real-thread/bindings", "threadNotFound"),
        (
            "/api/v1/attachments/0123456789abcdef0123456789abcdef",
            "attachmentNotFound",
        ),
    ] {
        let response = client
            .get(format!("{base}{path}"))
            .bearer_auth("web-endpoints-token")
            .send()
            .await
            .expect("authed GET");
        assert_eq!(response.status(), StatusCode::NOT_FOUND, "{path}");
        let error: Value = response.json().await.expect("404 json");
        assert_eq!(error_code(&error), expected_code, "{path}: {error}");
    }

    shutdown(handle).await;
}

// ---------------------------------------------------------------------------
// 5. real-mode member/avatar restart persistence + corrupt-store refusal
// ---------------------------------------------------------------------------

#[tokio::test]
async fn real_mode_member_and_avatar_persist_across_restart() {
    let data_dir = tempfile::tempdir().expect("tempdir");
    let webui_dir = webui();
    let client = client();
    let avatar_bytes = b"real-mode-avatar-bytes".to_vec();

    let avatar_sha;
    {
        let state =
            real_app_state(data_dir.path(), SessionAdapterChoice::None).expect("real state");
        let (addr, handle) = serve_ephemeral(webui_dir.clone(), state)
            .await
            .expect("serve ephemeral");
        let base = format!("http://{addr}");

        let (status, member) = patch_json(
            &client,
            &format!("{base}/api/v1/members/human"),
            json!({
                "displayName": "Pai",
                "model": "gpt-5",
                "mode": "safe",
                "avatarShape": "circle",
                "avatarColor": "#112233",
            }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "patch member: {member}");
        assert_eq!(member["displayName"], "Pai");
        assert_eq!(member["avatar"], Value::Null);

        let (status, with_avatar) = put_json(
            &client,
            &format!("{base}/api/v1/members/human/avatar"),
            json!({
                "contentType": "image/png",
                "dataBase64": base64_encode(&avatar_bytes),
            }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "put avatar: {with_avatar}");
        assert_eq!(with_avatar["avatar"]["contentType"], "image/png");
        assert_eq!(with_avatar["avatar"]["sizeBytes"], avatar_bytes.len());
        avatar_sha = with_avatar["avatar"]["sha256"]
            .as_str()
            .expect("sha")
            .to_string();

        let (status, content_type, bytes) =
            get_bytes(&client, &format!("{base}/api/v1/members/human/avatar")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(content_type.as_deref(), Some("image/png"));
        assert_eq!(bytes, avatar_bytes);
        assert!(data_dir.path().join("member-settings.json").is_file());

        shutdown(handle).await;
    }

    // Reopen the very same real data dir: settings + avatar survive.
    let state =
        real_app_state(data_dir.path(), SessionAdapterChoice::None).expect("reopened real state");
    let (addr, handle) = serve_ephemeral(webui_dir, state)
        .await
        .expect("serve ephemeral after restart");
    let base = format!("http://{addr}");
    let (status, member) = get_json(&client, &format!("{base}/api/v1/members/human")).await;
    assert_eq!(status, StatusCode::OK, "member after restart: {member}");
    assert_eq!(member["displayName"], "Pai");
    assert_eq!(member["model"], "gpt-5");
    assert_eq!(member["mode"], "safe");
    assert_eq!(member["avatarShape"], "circle");
    assert_eq!(member["avatarColor"], "#112233");
    assert_eq!(member["avatar"]["sha256"], avatar_sha);
    let (status, content_type, bytes) =
        get_bytes(&client, &format!("{base}/api/v1/members/human/avatar")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(content_type.as_deref(), Some("image/png"));
    assert_eq!(bytes, avatar_bytes);
    shutdown(handle).await;
}

#[test]
fn corrupt_member_settings_store_is_refused_by_real_app_state() {
    let data_dir = tempfile::tempdir().expect("tempdir");
    std::fs::write(data_dir.path().join("member-settings.json"), b"{ not json")
        .expect("write corrupt store");
    let error = match pharos_web::real_app_state(data_dir.path(), SessionAdapterChoice::None) {
        Ok(_) => panic!("corrupt member-settings store must be a hard error"),
        Err(error) => error,
    };
    assert!(
        error.contains("member-settings.json") && error.contains("corrupt"),
        "error must name the corrupt store: {error}"
    );
    assert_eq!(
        std::fs::read(data_dir.path().join("member-settings.json")).expect("read"),
        b"{ not json".to_vec(),
        "corrupt bytes must be preserved for inspection"
    );
}
