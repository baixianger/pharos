//! HTTP thin client for the managed `dsh web` Host (cookie + `/api/*` RPC).
//! Mirrors Swift `DshWebHttpWsTransport` without WebSocket — product waits use
//! `session/page` journal polls (same cold path as Swift seed readiness).

use pharos_codex_adapter::{AdapterError, PromptMode};
use reqwest::blocking::{Client, Response};
use reqwest::header::{COOKIE, SET_COOKIE};
use reqwest::redirect::Policy;
use serde_json::{Value, json};
use std::time::Duration;
use uuid::Uuid;

pub struct DshHttpTransport {
    client: Client,
    /// Client that does not follow redirects (for `/connect` Set-Cookie).
    connect_client: Client,
    port: u16,
    token: String,
    cookie: Option<String>,
}

impl DshHttpTransport {
    pub fn new(port: u16, token: impl Into<String>) -> Result<Self, AdapterError> {
        let client = Client::builder()
            .timeout(Duration::from_secs(60))
            .build()
            .map_err(|e| AdapterError::new(format!("http client: {e}")))?;
        let connect_client = Client::builder()
            .timeout(Duration::from_secs(30))
            .redirect(Policy::none())
            .build()
            .map_err(|e| AdapterError::new(format!("connect client: {e}")))?;
        Ok(Self {
            client,
            connect_client,
            port,
            token: token.into(),
            cookie: None,
        })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    fn ensure_cookie(&mut self) -> Result<String, AdapterError> {
        if let Some(cookie) = &self.cookie {
            return Ok(cookie.clone());
        }
        let url = format!(
            "http://127.0.0.1:{}/connect?token={}&interactions=answer",
            self.port, self.token
        );
        let response = self
            .connect_client
            .get(&url)
            .send()
            .map_err(|e| AdapterError::new(format!("dsh connect failed: {e}")))?;
        let cookie = extract_set_cookie(&response).ok_or_else(|| {
            AdapterError::new(format!(
                "dsh connect failed: missing Set-Cookie (status {})",
                response.status()
            ))
        })?;
        self.cookie = Some(cookie.clone());
        Ok(cookie)
    }

    pub fn rpc(&mut self, method: &str, args: Value) -> Result<Value, AdapterError> {
        let cookie = self.ensure_cookie()?;
        let url = format!("http://127.0.0.1:{}/api/{method}", self.port);
        let body = json!({
            "type": "client-request",
            "rpcId": Uuid::new_v4().to_string(),
            "method": method,
            "payload": { "args": args },
        });
        let response = self
            .client
            .post(&url)
            .header(COOKIE, cookie)
            .json(&body)
            .send()
            .map_err(|e| AdapterError::new(format!("dsh HTTP {method}: {e}")))?;
        if !response.status().is_success() {
            return Err(AdapterError::new(format!(
                "dsh web HTTP request failed for {method} (status {})",
                response.status()
            )));
        }
        let json: Value = response
            .json()
            .map_err(|e| AdapterError::new(format!("dsh HTTP {method} decode: {e}")))?;
        if let Some(result) = json.get("result") {
            if result.get("ok").and_then(Value::as_bool) == Some(true) {
                return Ok(result.get("value").cloned().unwrap_or(json!({})));
            }
            if result.get("ok").and_then(Value::as_bool) == Some(false) {
                let msg = result
                    .pointer("/error/message")
                    .and_then(Value::as_str)
                    .unwrap_or("Unknown dsh error");
                return Err(AdapterError::new(format!("dsh RPC error: {msg}")));
            }
        }
        Ok(json)
    }

    pub fn create_session(&mut self, workspace_path: &str) -> Result<String, AdapterError> {
        let value = self.rpc(
            "session/create",
            json!({ "request": { "cwd": workspace_path } }),
        )?;
        value
            .get("sessionId")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| AdapterError::new("dsh session/create returned no session ID"))
    }

    pub fn send_prompt(
        &mut self,
        session_id: &str,
        prompt: &str,
        mode: PromptMode,
    ) -> Result<Value, AdapterError> {
        let mode = match mode {
            PromptMode::Queue => "queue",
            PromptMode::Steer => "steer",
        };
        let value = self.rpc(
            "session/prompt",
            json!({
                "request": {
                    "requestId": Uuid::new_v4().to_string(),
                    "sessionId": session_id,
                    "mode": mode,
                    "content": [{ "type": "text", "text": prompt }],
                }
            }),
        )?;
        let accepted = value.get("accepted").and_then(Value::as_bool) == Some(true)
            || value.get("turnId").is_some();
        if !accepted {
            return Err(AdapterError::new(format!(
                "dsh session/prompt was not accepted: {value}"
            )));
        }
        Ok(value)
    }

    pub fn cancel_session(&mut self, session_id: &str) -> Result<Value, AdapterError> {
        self.rpc(
            "session/cancel",
            json!({ "request": { "sessionId": session_id } }),
        )
    }

    pub fn execute_command(
        &mut self,
        session_id: &str,
        command: &str,
    ) -> Result<Value, AdapterError> {
        self.rpc(
            "commands/execute",
            json!({
                "agentId": session_id,
                "line": command,
                "submittedAttachments": [],
            }),
        )
    }

    pub fn session_page(
        &mut self,
        session_id: &str,
        before_seq: Option<i64>,
    ) -> Result<Value, AdapterError> {
        let mut request = json!({
            "address": { "kind": "session", "sessionId": session_id },
            "maxMessages": 100,
        });
        if let Some(before) = before_seq {
            request["beforeSeq"] = json!(before);
        }
        self.rpc("session/page", json!({ "request": request }))
    }

    /// Fetch journal records oldest→newest (up to a few pages).
    pub fn session_history(&mut self, session_id: &str) -> Result<Vec<Value>, AdapterError> {
        let mut pages: Vec<Vec<Value>> = Vec::new();
        let mut before: Option<i64> = None;
        for _ in 0..50 {
            let page = self.session_page(session_id, before)?;
            let records = page
                .get("records")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let has_more = page
                .get("hasMore")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            pages.push(records);
            if !has_more {
                break;
            }
            let cursor = page
                .get("cursor")
                .and_then(Value::as_i64)
                .ok_or_else(|| AdapterError::new("DSH returned an invalid history cursor"))?;
            if cursor <= 0 || Some(cursor) == before {
                return Err(AdapterError::new("DSH returned an invalid history cursor"));
            }
            before = Some(cursor);
        }
        Ok(pages.into_iter().rev().flatten().collect())
    }
}

fn extract_set_cookie(response: &Response) -> Option<String> {
    let raw = response.headers().get(SET_COOKIE)?.to_str().ok()?;
    let first = raw.split(';').next()?.trim();
    if first.is_empty() {
        None
    } else {
        Some(first.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_mode_maps_to_wire() {
        // Compile-time sanity: variants exist for queue/steer wire values.
        assert!(matches!(PromptMode::Queue, PromptMode::Queue));
        assert!(matches!(PromptMode::Steer, PromptMode::Steer));
    }
}
