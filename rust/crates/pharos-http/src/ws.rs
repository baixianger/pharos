//! WebSocket event pump for `GET /api/v1/events` (`ClientEvent` JSON frames).

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{State, ws};
use axum::response::IntoResponse;
use futures_util::{SinkExt, StreamExt};
use tracing::{debug, warn};

use crate::state::AppState;

/// Upgrade handler mounted at `pharos_api::routes::EVENTS_WS`.
pub async fn events_ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| events_ws_loop(socket, state))
}

async fn events_ws_loop(socket: WebSocket, state: AppState) {
    let (mut sink, mut stream) = socket.split();
    let mut subscriber = state.events.subscribe();

    // Hello / ready frame so clients and tests know the pump is live.
    let hello = serde_json::json!({
        "eventType": "memberStatusChanged",
        "memberName": "pharos-http",
        "status": "ws-ready"
    });
    if sink
        .send(Message::Text(hello.to_string().into()))
        .await
        .is_err()
    {
        return;
    }

    loop {
        tokio::select! {
            biased;
            client_msg = stream.next() => {
                match client_msg {
                    Some(Ok(ws::Message::Close(_))) | None => break,
                    Some(Ok(ws::Message::Ping(data))) => {
                        if sink.send(Message::Pong(data)).await.is_err() {
                            break;
                        }
                    }
                    Some(Ok(ws::Message::Text(text))) => {
                        debug!(%text, "ws client text ignored (server→client pump only)");
                    }
                    Some(Ok(_)) => {}
                    Some(Err(err)) => {
                        warn!(?err, "ws client stream error");
                        break;
                    }
                }
            }
            event = subscriber.recv() => {
                match event {
                    Ok(ev) => {
                        let Ok(payload) = serde_json::to_string(&ev) else {
                            continue;
                        };
                        if sink.send(Message::Text(payload.into())).await.is_err() {
                            break;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        warn!(lagged = n, "ws event subscriber lagged");
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
        }
    }
}
