//! S4 acceptance gates against **fake** S1/S2 services.
//!
//! - GET /health
//! - OpenAPI stub served
//! - Static Web UI: index.html + JS/CSS resolve
//! - WS event pump receives FakeEventBus demo frames

use std::time::Duration;

use futures_util::StreamExt;
use pharos_http::services::FakeEventBus;
use pharos_web::{fake_app_state, resolve_webui_dir, serve_ephemeral};
use serde_json::Value;
use tokio_tungstenite::tungstenite::Message;

fn webui() -> std::path::PathBuf {
    resolve_webui_dir(None).expect("webui/ must exist at repo root for acceptance")
}

#[tokio::test]
async fn health_openapi_static_and_ws_pump() {
    let webui_dir = webui();
    assert!(webui_dir.join("index.html").is_file());
    assert!(webui_dir.join("dsh-stream.js").is_file());
    assert!(webui_dir.join("dsh-stream.css").is_file());

    let state = fake_app_state();
    let events = state.events.clone();
    let (addr, _handle) = serve_ephemeral(webui_dir.clone(), state)
        .await
        .expect("bind");
    let base = format!("http://{addr}");

    // --- GET /health ---
    let health: Value = reqwest::get(format!("{base}/health"))
        .await
        .expect("health request")
        .error_for_status()
        .expect("health status")
        .json()
        .await
        .expect("health json");
    assert_eq!(health["ok"], true);
    assert_eq!(health["contractsVersion"], "0.1.0");
    assert_eq!(health["service"], "pharos-meshd");

    // --- OpenAPI ---
    let openapi: Value = reqwest::get(format!("{base}/openapi.json"))
        .await
        .expect("openapi request")
        .error_for_status()
        .expect("openapi status")
        .json()
        .await
        .expect("openapi json");
    assert_eq!(openapi["openapi"], "3.0.3");
    assert_eq!(openapi["info"]["version"], "0.1.0");
    assert!(openapi["paths"].get("/health").is_some());
    assert!(openapi["paths"].get("/api/v1/events").is_some());

    // --- Static Web UI (index + JS/CSS) ---
    let index = reqwest::get(format!("{base}/"))
        .await
        .expect("index")
        .error_for_status()
        .expect("index status")
        .text()
        .await
        .expect("index body");
    assert!(
        index.contains("dsh-stream.css") && index.contains("dsh-stream.js"),
        "index.html must reference css/js"
    );

    let css = reqwest::get(format!("{base}/dsh-stream.css"))
        .await
        .expect("css")
        .error_for_status()
        .expect("css status")
        .text()
        .await
        .expect("css body");
    assert!(!css.is_empty(), "dsh-stream.css must be non-empty");

    let js = reqwest::get(format!("{base}/dsh-stream.js"))
        .await
        .expect("js")
        .error_for_status()
        .expect("js status")
        .text()
        .await
        .expect("js body");
    assert!(!js.is_empty(), "dsh-stream.js must be non-empty");

    // Headless resolve check: parse asset hrefs/srcs from index and GET each.
    for needle in ["dsh-stream.css", "dsh-stream.js"] {
        assert!(index.contains(needle));
        let status = reqwest::get(format!("{base}/{needle}"))
            .await
            .unwrap()
            .status();
        assert!(status.is_success(), "{needle} => {status}");
    }

    // --- WS event pump against FakeEventBus ---
    let ws_url = format!("ws://{addr}/api/v1/events");
    let (mut ws, _resp) = tokio_tungstenite::connect_async(&ws_url)
        .await
        .expect("ws connect");

    // First frame is ws-ready hello from pharos-http.
    let ready = tokio::time::timeout(Duration::from_secs(2), ws.next())
        .await
        .expect("ready timeout")
        .expect("ready stream")
        .expect("ready msg");
    let ready_text = match ready {
        Message::Text(t) => t.to_string(),
        other => panic!("expected text ready frame, got {other:?}"),
    };
    let ready_json: Value = serde_json::from_str(&ready_text).unwrap();
    assert_eq!(ready_json["eventType"], "memberStatusChanged");
    assert_eq!(ready_json["status"], "ws-ready");

    // Give the server a moment to register the broadcast subscriber, then pump.
    tokio::time::sleep(Duration::from_millis(50)).await;
    let fake_pump = FakeEventBus::new(events);
    fake_pump.pump_demo_events();

    let mut saw_pump_message = false;
    let mut saw_session_restored = false;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    while tokio::time::Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let frame = tokio::time::timeout(remaining, ws.next()).await;
        let Ok(Some(Ok(Message::Text(text)))) = frame else {
            continue;
        };
        let json: Value = serde_json::from_str(&text).unwrap();
        match json["eventType"].as_str() {
            Some("threadMessageReceived") if json["threadMessage"]["text"] == "ws pump demo" => {
                saw_pump_message = true;
            }
            Some("sessionConnectionRestored") if json["sessionId"] == "fake-session-1" => {
                saw_session_restored = true;
            }
            _ => {}
        }
        if saw_pump_message && saw_session_restored {
            break;
        }
    }
    assert!(
        saw_pump_message && saw_session_restored,
        "WS pump must deliver FakeEventBus demo frames (msg={saw_pump_message}, restored={saw_session_restored})"
    );

    drop(ws);
}
