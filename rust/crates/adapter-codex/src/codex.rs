use crate::delivery::{
    DeliveryDispatchResult, DeliveryJob, DeliveryWorker, format_delivery_prompt,
};
use crate::error::AdapterError;
use crate::resolve::resolve_codex_executable;
use crate::session::{
    InterruptOutcome, PromptMode, SessionAdapter, StartSessionRequest, StartedSession, StartedTurn,
    TurnOutcome, TurnStatus,
};
use crate::transport::{AppServerTransport, CodexTransport, DaemonProxyAppServer, StdioAppServer};
use pharos_api::AdapterManifest;
use pharos_protocol::AdapterKind;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

/// Codex CLI App Server session + delivery adapter (S5a).
pub struct CodexSessionAdapter {
    transport: CodexTransport,
    /// Pharos session id → vendor thread id
    sessions: HashMap<String, String>,
    /// session id → active turn id
    active_turns: HashMap<String, String>,
}

impl CodexSessionAdapter {
    pub fn connect_stdio() -> Result<Self, AdapterError> {
        let executable = resolve_codex_executable().map_err(AdapterError::new)?;
        Self::connect_stdio_executable(&executable)
    }

    pub fn connect_stdio_executable(executable: &Path) -> Result<Self, AdapterError> {
        let transport = StdioAppServer::connect(executable)?;
        Ok(Self {
            transport: CodexTransport::Stdio(transport),
            sessions: HashMap::new(),
            active_turns: HashMap::new(),
        })
    }

    /// Isolated CODEX_HOME under `pharos-msg-test` (auth/config seeded, no secrets logged).
    pub fn connect_stdio_isolated(codex_home: &Path) -> Result<Self, AdapterError> {
        let executable = resolve_codex_executable().map_err(AdapterError::new)?;
        let transport = StdioAppServer::connect_isolated(&executable, codex_home)?;
        Ok(Self {
            transport: CodexTransport::Stdio(transport),
            sessions: HashMap::new(),
            active_turns: HashMap::new(),
        })
    }

    pub fn connect_daemon_proxy() -> Result<Self, AdapterError> {
        let executable = resolve_codex_executable().map_err(AdapterError::new)?;
        let transport = DaemonProxyAppServer::connect(&executable)?;
        Ok(Self {
            transport: CodexTransport::DaemonProxy(transport),
            sessions: HashMap::new(),
            active_turns: HashMap::new(),
        })
    }

    /// Build an adapter over an arbitrary transport (recorded/fake in tests).
    pub fn from_transport(transport: CodexTransport) -> Self {
        Self {
            transport,
            sessions: HashMap::new(),
            active_turns: HashMap::new(),
        }
    }

    /// Underlying transport (test assertions only; no live I/O on `Recorded`).
    pub fn transport(&self) -> &CodexTransport {
        &self.transport
    }

    pub fn raw_request(
        &mut self,
        id: Value,
        method: &str,
        params: Value,
    ) -> Result<Value, AdapterError> {
        self.transport.request(id, method, params)
    }

    pub fn take_notifications(&mut self) -> Vec<Value> {
        self.transport.take_notifications()
    }

    fn thread_id(&self, session_id: &str) -> Result<String, AdapterError> {
        self.sessions
            .get(session_id)
            .cloned()
            .ok_or_else(|| AdapterError::new(format!("unknown session: {session_id}")))
    }

    fn parse_turns(thread: &Value) -> Vec<TurnOutcome> {
        let turns = thread
            .get("turns")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        turns
            .iter()
            .filter_map(|turn| {
                let turn_id = turn.get("id")?.as_str()?.to_owned();
                let raw_status = turn
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                let status = TurnStatus::parse(&raw_status);
                let items = turn
                    .get("items")
                    .and_then(Value::as_array)
                    .map(Vec::as_slice)
                    .unwrap_or(&[]);
                // Only the final answer counts as the reply: never join every
                // agentMessage (that leaks streamed commentary into the reply).
                let assistant_text = crate::reply::assistant_reply_text(items).unwrap_or_default();
                let vendor_error = turn.get("error").and_then(extract_vendor_error);
                Some(TurnOutcome {
                    turn_id,
                    status,
                    raw_status,
                    assistant_text,
                    vendor_error,
                })
            })
            .collect()
    }

    fn read_thread(&mut self, thread_id: &str, include_turns: bool) -> Result<Value, AdapterError> {
        let result = self.transport.request(
            Value::from(format!("read-{thread_id}-{include_turns}")),
            "thread/read",
            json!({"threadId": thread_id, "includeTurns": include_turns}),
        )?;
        Ok(result.get("thread").cloned().unwrap_or(result))
    }

    /// Wait until the vendor thread reports idle.
    ///
    /// Uses `includeTurns: false` — Codex 0.167 can reject `includeTurns: true`
    /// with `list_turns is not supported yet` on a fresh/empty thread, which is
    /// exactly when we need idle checks before the first follow-up turn.
    pub fn wait_until_idle(
        &mut self,
        session_id: &str,
        timeout: Duration,
    ) -> Result<(), AdapterError> {
        let thread_id = self.thread_id(session_id)?;
        let deadline = Instant::now() + timeout;
        let mut last_status = String::from("<unread>");
        let mut last_error: Option<String> = None;
        let mut saw_readable = false;
        while Instant::now() < deadline {
            match self.read_thread(&thread_id, false) {
                Ok(thread) => {
                    saw_readable = true;
                    let status_type = thread
                        .pointer("/status/type")
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    last_status = status_type.to_owned();
                    if status_type == "idle" || status_type.is_empty() {
                        let _ = self.transport.take_notifications();
                        return Ok(());
                    }
                }
                Err(error) => {
                    last_error = Some(error.message.clone());
                    // Empty-rollout / list_turns races: if we have no local active
                    // turn, allow progress instead of spinning for the full timeout.
                    if !self.active_turns.contains_key(session_id)
                        && is_benign_thread_read_race(&error.message)
                    {
                        let _ = self.transport.take_notifications();
                        return Ok(());
                    }
                }
            }
            let _ = self.transport.take_notifications();
            thread::sleep(Duration::from_millis(250));
        }
        Err(AdapterError::new(format!(
            "timed out waiting for Codex thread idle (last status={last_status}; readable={saw_readable}{})",
            last_error
                .map(|e| format!("; last read error: {e}"))
                .unwrap_or_default()
        )))
    }
}

fn is_benign_thread_read_race(message: &str) -> bool {
    message.contains("list_turns is not supported yet")
        || (message.contains("rollout") && message.contains("empty"))
        || message.contains("failed to read session metadata")
}

fn extract_vendor_error(error: &Value) -> Option<String> {
    if error.is_null() {
        return None;
    }
    if let Some(message) = error.as_str() {
        return Some(message.to_owned());
    }
    if let Some(message) = error.get("message").and_then(Value::as_str) {
        return Some(message.to_owned());
    }
    Some(error.to_string())
}

impl SessionAdapter for CodexSessionAdapter {
    fn kind(&self) -> AdapterKind {
        AdapterKind::Codex
    }

    fn manifest(&self) -> AdapterManifest {
        AdapterManifest {
            id: "pharos.codex".to_string(),
            kind: AdapterKind::Codex,
            capabilities: vec![
                "delivery.poll".into(),
                "session.list".into(),
                "message.send".into(),
                "session.observe".into(),
                "turn.interrupt".into(),
            ],
        }
    }

    fn start_session(
        &mut self,
        request: StartSessionRequest,
    ) -> Result<StartedSession, AdapterError> {
        // Product-path / delivery worker default: never block on approvals.
        // Mode `"yolo"` and non-yolo both map to never for now; safe/on-request
        // can land once S2 wires HITL approvals through this adapter.
        let approval_policy = "never";
        let mut params = json!({
            "cwd": request.workspace_path,
            "approvalPolicy": approval_policy,
        });
        if let Some(model) = request
            .model
            .as_ref()
            .filter(|m| !m.is_empty() && *m != "default")
        {
            params["model"] = Value::from(model.clone());
        }
        let result = self
            .transport
            .request(Value::from("thread-start"), "thread/start", params)?;
        let thread = result.get("thread").cloned().unwrap_or(result);
        let vendor_thread_id = thread
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| AdapterError::new("thread/start missing thread id"))?
            .to_owned();
        let session_id = vendor_thread_id.clone();
        self.sessions
            .insert(session_id.clone(), vendor_thread_id.clone());
        Ok(StartedSession {
            session_id,
            vendor_thread_id,
        })
    }

    fn send_prompt(
        &mut self,
        session_id: &str,
        prompt: &str,
        mode: PromptMode,
    ) -> Result<StartedTurn, AdapterError> {
        let thread_id = self.thread_id(session_id)?;
        let (method, params) = match mode {
            PromptMode::Queue => {
                // Queue turns require an idle thread; starting while active is a
                // known Codex race (empty rollout / immediate failed turn).
                self.wait_until_idle(session_id, Duration::from_secs(45))?;
                (
                    "turn/start",
                    json!({
                        "threadId": thread_id,
                        "input": [{"type": "text", "text": prompt}],
                    }),
                )
            }
            PromptMode::Steer => {
                if let Some(active) = self.active_turns.get(session_id).cloned() {
                    (
                        "turn/steer",
                        json!({
                            "threadId": thread_id,
                            "expectedTurnId": active,
                            "input": [{"type": "text", "text": prompt}],
                        }),
                    )
                } else {
                    self.wait_until_idle(session_id, Duration::from_secs(45))?;
                    (
                        "turn/start",
                        json!({
                            "threadId": thread_id,
                            "input": [{"type": "text", "text": prompt}],
                        }),
                    )
                }
            }
        };
        let result = self.transport.request(
            Value::from(format!("turn-{}", uuid::Uuid::new_v4())),
            method,
            params,
        )?;
        let turn = result.get("turn").cloned().unwrap_or(result);
        let turn_id = turn
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| AdapterError::new("turn/start missing turn id"))?
            .to_owned();
        self.active_turns
            .insert(session_id.to_owned(), turn_id.clone());
        Ok(StartedTurn {
            session_id: session_id.to_owned(),
            turn_id,
        })
    }

    fn interrupt(&mut self, session_id: &str) -> Result<InterruptOutcome, AdapterError> {
        let thread_id = self.thread_id(session_id)?;
        let Some(turn_id) = self.active_turns.get(session_id).cloned() else {
            return Ok(InterruptOutcome {
                session_id: session_id.to_owned(),
                turn_id: None,
                turn_status: None,
            });
        };
        match self.transport.request(
            Value::from(format!("interrupt-{turn_id}")),
            "turn/interrupt",
            json!({"threadId": thread_id, "turnId": turn_id}),
        ) {
            Ok(_) => {}
            Err(error) if error.message.contains("no active turn to interrupt") => {}
            Err(error) => return Err(error),
        }
        self.active_turns.remove(session_id);
        // Observe terminal status; must not be Completed.
        let outcome = self
            .wait_turn(session_id, &turn_id, Duration::from_secs(60))
            .ok();
        let turn_status = outcome.as_ref().map(|o| o.status);
        if turn_status == Some(TurnStatus::Completed) {
            return Err(AdapterError::new(
                "interrupt reported completed (protocol violation)",
            ));
        }
        Ok(InterruptOutcome {
            session_id: session_id.to_owned(),
            turn_id: Some(turn_id),
            turn_status,
        })
    }

    fn wait_turn(
        &mut self,
        session_id: &str,
        turn_id: &str,
        timeout: Duration,
    ) -> Result<TurnOutcome, AdapterError> {
        let thread_id = self.thread_id(session_id)?;
        let deadline = Instant::now() + timeout;
        let mut last_error: Option<String> = None;
        while Instant::now() < deadline {
            match self.read_thread(&thread_id, true) {
                Ok(thread) => {
                    let turns = Self::parse_turns(&thread);
                    if let Some(found) = turns.into_iter().find(|t| t.turn_id == turn_id)
                        && found.status.is_terminal()
                    {
                        if found.status == TurnStatus::Completed {
                            self.active_turns.remove(session_id);
                        }
                        return Ok(found);
                    }
                }
                Err(error) => {
                    // Codex can race an empty rollout right after thread/start /
                    // turn/start; keep polling.
                    last_error = Some(error.message);
                }
            }
            // Drain notifications so the transport buffer stays bounded.
            let _ = self.transport.take_notifications();
            thread::sleep(Duration::from_millis(400));
        }
        Err(AdapterError::new(format!(
            "timed out waiting for turn {turn_id}{}",
            last_error
                .map(|e| format!(" (last read error: {e})"))
                .unwrap_or_default()
        )))
    }

    fn read_turns(&mut self, session_id: &str) -> Result<Vec<TurnOutcome>, AdapterError> {
        let thread_id = self.thread_id(session_id)?;
        let thread = self.read_thread(&thread_id, true)?;
        Ok(Self::parse_turns(&thread))
    }

    fn close(&mut self) {
        self.transport.close();
        self.sessions.clear();
        self.active_turns.clear();
    }
}

impl DeliveryWorker for CodexSessionAdapter {
    fn dispatch(&mut self, job: DeliveryJob) -> Result<DeliveryDispatchResult, AdapterError> {
        // Bind delivery conversation session if needed.
        if !self.sessions.contains_key(&job.session_id) {
            self.sessions
                .insert(job.session_id.clone(), job.session_id.clone());
        }
        let prompt = format_delivery_prompt(&job.payload, &job.session_id);
        let started = match self.send_prompt(&job.session_id, &prompt, PromptMode::Queue) {
            Ok(started) => started,
            Err(error) => {
                return Ok(DeliveryDispatchResult::failed(
                    job.delivery_id,
                    format!("Codex turn/start failed before dispatch: {error}"),
                ));
            }
        };
        let outcome =
            match self.wait_turn(&job.session_id, &started.turn_id, Duration::from_secs(180)) {
                Ok(outcome) => outcome,
                Err(error) => {
                    return Ok(DeliveryDispatchResult::failed_turn(
                        job.delivery_id,
                        started.turn_id,
                        format!("Codex wait_turn failed: {error}"),
                    ));
                }
            };
        let detail = outcome.failure_detail();
        match outcome.status {
            TurnStatus::Completed => {
                if outcome.assistant_text.trim().is_empty() {
                    Ok(DeliveryDispatchResult::failed_turn(
                        job.delivery_id,
                        outcome.turn_id,
                        format!("Codex turn completed without assistant text; {detail}"),
                    ))
                } else {
                    Ok(DeliveryDispatchResult::completed(
                        job.delivery_id,
                        outcome.turn_id,
                        outcome.assistant_text,
                    ))
                }
            }
            TurnStatus::Interrupted => Ok(DeliveryDispatchResult::interrupted(
                job.delivery_id,
                outcome.turn_id,
                format!("Codex turn interrupted; {detail}"),
            )),
            TurnStatus::Failed => Ok(DeliveryDispatchResult::failed_turn(
                job.delivery_id,
                outcome.turn_id,
                format!("Codex turn failed; {detail}"),
            )),
            other => Ok(DeliveryDispatchResult::failed_turn(
                job.delivery_id,
                outcome.turn_id,
                format!("Codex turn ended in non-success status {other:?}; {detail}"),
            )),
        }
    }
}

impl Drop for CodexSessionAdapter {
    fn drop(&mut self) {
        self.close();
    }
}

/// Helper used by the JSONL stdio binary (`pharos-codex-adapter`).
pub fn run_jsonl_daemon_proxy_bridge() -> Result<(), String> {
    use pharos_agent_core::{AdapterRequest, AdapterResponse};
    use std::io::{self, BufRead, Write};

    let executable = resolve_codex_executable()?;
    let mut app_server = DaemonProxyAppServer::connect(&executable).map_err(|e| e.message)?;
    app_server
        .request(
            Value::from("pharos-initialize"),
            "initialize",
            json!({
                "clientInfo": {"name": "pharos", "title": "Pharos", "version": "0.1.0"},
                "capabilities": {"experimentalApi": false}
            }),
        )
        .map_err(|e| e.message)?;

    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = line.map_err(|error| error.to_string())?;
        if line.trim().is_empty() {
            continue;
        }
        let response = match serde_json::from_str::<AdapterRequest>(&line) {
            Ok(request) if request.method == "codex.events" => {
                let poll_id = Value::from(format!("pharos-events-{}", request.id));
                match app_server.request(poll_id, "thread/list", json!({"limit": 1})) {
                    Ok(_) => AdapterResponse::success(
                        request.id,
                        json!({"events": app_server.take_notifications()}),
                    ),
                    Err(error) => AdapterResponse::failure(request.id, error.message),
                }
            }
            Ok(request) => {
                // codex-cli 0.167 elides/errors `thread/read includeTurns:true`
                // depending on connection/thread history state; normalize it via
                // the supported thread/turns/list fallback so reply correlation
                // reads real final answers instead of polling to turn-timeout.
                let result =
                    if crate::thread_turns::is_include_turns_read(&request.method, &request.params)
                    {
                        crate::thread_turns::thread_read_include_turns(
                            &mut app_server,
                            request.id.clone(),
                            request.params,
                        )
                    } else {
                        app_server.request(request.id.clone(), &request.method, request.params)
                    };
                match result {
                    Ok(result) => AdapterResponse::success(request.id, result),
                    Err(error) => AdapterResponse::failure(request.id, error.message),
                }
            }
            Err(error) => {
                AdapterResponse::failure(Value::Null, format!("invalid request: {error}"))
            }
        };
        serde_json::to_writer(&mut stdout, &response).map_err(|error| error.to_string())?;
        stdout.write_all(b"\n").map_err(|error| error.to_string())?;
        stdout.flush().map_err(|error| error.to_string())?;
    }
    Ok(())
}

/// Convenience: msg-test data directory root for live evidence.
pub fn msg_test_root() -> PathBuf {
    crate::resolve::home_dir().join("personal/pharos-msg-test")
}
