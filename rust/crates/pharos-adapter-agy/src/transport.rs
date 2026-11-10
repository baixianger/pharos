//! ACP stdio JSON-RPC transport for `agy acp --stdio`.
//!
//! A background reader thread owns stdout so `session/prompt` can run without
//! blocking the adapter while still allowing `session/cancel` mid-turn.

use crate::error::AdapterError;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const MAX_PENDING_NOTIFICATIONS: usize = 1_024;

#[derive(Debug, Clone)]
pub struct PromptTerminal {
    pub stop_reason: String,
    pub assistant_text: String,
    pub error: Option<String>,
}

struct SharedState {
    /// Completed JSON-RPC responses keyed by numeric id.
    responses: HashMap<u64, Result<Value, String>>,
    /// In-flight prompt request id → accumulated assistant text.
    assistant_text: HashMap<u64, String>,
    /// Terminal prompt outcomes keyed by request id.
    prompt_terminals: HashMap<u64, PromptTerminal>,
    /// sessionId → currently active prompt request id.
    active_prompt_by_session: HashMap<String, u64>,
    notifications: VecDeque<Value>,
    child_error: Option<String>,
    reader_done: bool,
}

/// Long-running `agy acp --stdio` child.
pub struct AcpTransport {
    child: Child,
    stdin: ChildStdin,
    shared: Arc<Mutex<SharedState>>,
    cv: Arc<Condvar>,
    next_id: u64,
    closed: Arc<AtomicBool>,
}

pub struct AcpSpawnOptions {
    pub executable: PathBuf,
    pub workspace_hint: Option<PathBuf>,
    /// When set, pass `--gemini-dir` + relative `--app-data-dir` for isolation.
    pub isolated_gemini_dir: Option<PathBuf>,
    pub app_data_dir_name: String,
    pub dangerously_skip_permissions: bool,
}

impl Default for AcpSpawnOptions {
    fn default() -> Self {
        Self {
            executable: PathBuf::from("agy"),
            workspace_hint: None,
            isolated_gemini_dir: None,
            app_data_dir_name: "antigravity-cli".into(),
            dangerously_skip_permissions: true,
        }
    }
}

impl AcpTransport {
    pub fn spawn(options: AcpSpawnOptions) -> Result<Self, AdapterError> {
        if let Some(dir) = options.isolated_gemini_dir.as_ref() {
            seed_isolated_gemini(dir, &options.app_data_dir_name)?;
        }

        let mut command = Command::new(&options.executable);
        command
            .arg("acp")
            .arg("--stdio")
            .arg("--disable-telemetry")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if options.dangerously_skip_permissions {
            command.arg("--dangerously-skip-permissions");
        }
        if let Some(gemini_dir) = options.isolated_gemini_dir.as_ref() {
            command.arg("--gemini-dir").arg(gemini_dir);
            command
                .arg("--app-data-dir")
                .arg(&options.app_data_dir_name);
        }
        let _ = options.workspace_hint;

        let mut child = command
            .spawn()
            .map_err(|error| AdapterError::new(format!("start agy acp: {error}")))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| AdapterError::new("agy acp stdin unavailable"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| AdapterError::new("agy acp stdout unavailable"))?;

        let shared = Arc::new(Mutex::new(SharedState {
            responses: HashMap::new(),
            assistant_text: HashMap::new(),
            prompt_terminals: HashMap::new(),
            active_prompt_by_session: HashMap::new(),
            notifications: VecDeque::new(),
            child_error: None,
            reader_done: false,
        }));
        let cv = Arc::new(Condvar::new());
        let closed = Arc::new(AtomicBool::new(false));

        let reader_shared = Arc::clone(&shared);
        let reader_cv = Arc::clone(&cv);
        let reader_closed = Arc::clone(&closed);
        thread::Builder::new()
            .name("agy-acp-reader".into())
            .spawn(move || {
                read_loop(stdout, reader_shared, reader_cv, reader_closed);
            })
            .map_err(|error| AdapterError::new(format!("spawn agy reader: {error}")))?;

        let mut transport = Self {
            child,
            stdin,
            shared,
            cv,
            next_id: 1,
            closed,
        };
        transport.handshake()?;
        Ok(transport)
    }

    fn handshake(&mut self) -> Result<(), AdapterError> {
        let _ = self.request(
            "initialize",
            json!({
                "protocolVersion": 1,
                "clientCapabilities": {
                    "fs": {"readTextFile": true, "writeTextFile": true}
                },
                "clientInfo": {"name": "pharos", "version": "0.1.0"}
            }),
        )?;
        self.notify("initialized", json!({}))?;
        Ok(())
    }

    fn alloc_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id = self.next_id.saturating_add(1);
        id
    }

    fn write_json(&mut self, value: &Value) -> Result<(), AdapterError> {
        let payload =
            serde_json::to_vec(value).map_err(|error| AdapterError::new(error.to_string()))?;
        self.stdin
            .write_all(&payload)
            .and_then(|_| self.stdin.write_all(b"\n"))
            .and_then(|_| self.stdin.flush())
            .map_err(|error| AdapterError::new(format!("agy acp write: {error}")))
    }

    pub fn notify(&mut self, method: &str, params: Value) -> Result<(), AdapterError> {
        self.write_json(&json!({"jsonrpc": "2.0", "method": method, "params": params}))
    }

    pub fn request(&mut self, method: &str, params: Value) -> Result<Value, AdapterError> {
        let id = self.alloc_id();
        self.write_json(&json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        }))?;
        self.wait_response(id, Duration::from_secs(120))
    }

    /// Start a long-running `session/prompt` without blocking until completion.
    pub fn start_prompt(
        &mut self,
        session_id: &str,
        prompt: &str,
    ) -> Result<(u64, String), AdapterError> {
        let id = self.alloc_id();
        let turn_id = format!("agy-turn-{id}");
        {
            let mut state = self
                .shared
                .lock()
                .map_err(|_| AdapterError::new("agy shared lock poisoned"))?;
            state.assistant_text.insert(id, String::new());
            state
                .active_prompt_by_session
                .insert(session_id.to_owned(), id);
        }
        self.write_json(&json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/prompt",
            "params": {
                "sessionId": session_id,
                "prompt": [{"type": "text", "text": prompt}]
            }
        }))?;
        Ok((id, turn_id))
    }

    pub fn cancel_session(&mut self, session_id: &str) -> Result<(), AdapterError> {
        // ACP cancel is a notification (no id); the in-flight prompt returns
        // with stopReason=cancelled.
        self.notify("session/cancel", json!({"sessionId": session_id}))
    }

    pub fn wait_prompt(
        &mut self,
        request_id: u64,
        timeout: Duration,
    ) -> Result<PromptTerminal, AdapterError> {
        let deadline = Instant::now() + timeout;
        loop {
            {
                let state = self
                    .shared
                    .lock()
                    .map_err(|_| AdapterError::new("agy shared lock poisoned"))?;
                if let Some(terminal) = state.prompt_terminals.get(&request_id).cloned() {
                    return Ok(terminal);
                }
                if let Some(err) = state.child_error.as_ref() {
                    return Err(AdapterError::new(err.clone()));
                }
                // Fallback: raw response without prompt_terminals (e.g. error).
                if let Some(result) = state.responses.get(&request_id) {
                    match result {
                        Ok(value) => {
                            let stop_reason = value
                                .get("stopReason")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_owned();
                            let assistant_text = state
                                .assistant_text
                                .get(&request_id)
                                .cloned()
                                .unwrap_or_default();
                            return Ok(PromptTerminal {
                                stop_reason,
                                assistant_text,
                                error: None,
                            });
                        }
                        Err(message) => return Err(AdapterError::new(message.clone())),
                    }
                }
                if state.reader_done {
                    return Err(AdapterError::new(
                        "agy acp reader exited before prompt completed",
                    ));
                }
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(AdapterError::new(format!(
                    "timed out waiting for agy prompt id={request_id}"
                )));
            }
            let state = self
                .shared
                .lock()
                .map_err(|_| AdapterError::new("agy shared lock poisoned"))?;
            let (state, _) = self
                .cv
                .wait_timeout(state, remaining.min(Duration::from_millis(500)))
                .map_err(|_| AdapterError::new("agy wait poisoned"))?;
            drop(state);
        }
    }

    fn wait_response(&mut self, id: u64, timeout: Duration) -> Result<Value, AdapterError> {
        let deadline = Instant::now() + timeout;
        loop {
            {
                let state = self
                    .shared
                    .lock()
                    .map_err(|_| AdapterError::new("agy shared lock poisoned"))?;
                if let Some(result) = state.responses.get(&id) {
                    return match result {
                        Ok(value) => Ok(value.clone()),
                        Err(message) => Err(AdapterError::new(message.clone())),
                    };
                }
                if let Some(err) = state.child_error.as_ref() {
                    return Err(AdapterError::new(err.clone()));
                }
                if state.reader_done {
                    return Err(AdapterError::new(
                        "agy acp reader exited before response arrived",
                    ));
                }
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(AdapterError::new(format!(
                    "timed out waiting for agy response id={id}"
                )));
            }
            let state = self
                .shared
                .lock()
                .map_err(|_| AdapterError::new("agy shared lock poisoned"))?;
            let (state, _) = self
                .cv
                .wait_timeout(state, remaining.min(Duration::from_millis(500)))
                .map_err(|_| AdapterError::new("agy wait poisoned"))?;
            drop(state);
        }
    }

    pub fn take_notifications(&mut self) -> Vec<Value> {
        self.shared
            .lock()
            .map(|mut state| state.notifications.drain(..).collect())
            .unwrap_or_default()
    }

    pub fn close(&mut self) {
        if self.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Ok(mut state) = self.shared.lock() {
            state.reader_done = true;
        }
        self.cv.notify_all();
    }
}

impl Drop for AcpTransport {
    fn drop(&mut self) {
        self.close();
    }
}

fn read_loop(
    stdout: impl std::io::Read + Send + 'static,
    shared: Arc<Mutex<SharedState>>,
    cv: Arc<Condvar>,
    closed: Arc<AtomicBool>,
) {
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    loop {
        if closed.load(Ordering::SeqCst) {
            break;
        }
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }
                let Ok(message) = serde_json::from_str::<Value>(trimmed) else {
                    continue;
                };
                handle_incoming(&shared, &cv, message);
            }
            Err(_) => break,
        }
    }
    if let Ok(mut state) = shared.lock() {
        state.reader_done = true;
    }
    cv.notify_all();
}

fn handle_incoming(shared: &Arc<Mutex<SharedState>>, cv: &Arc<Condvar>, message: Value) {
    let Ok(mut state) = shared.lock() else {
        return;
    };

    // Server→client request (e.g. session/request_permission). Auto-deny is
    // avoided; product path uses --dangerously-skip-permissions. Still answer
    // generically so the child does not hang if a request slips through.
    if message.get("method").is_some()
        && message.get("id").is_some()
        && message.get("result").is_none()
        && message.get("error").is_none()
    {
        // Reader cannot write stdin; stash as notification for the adapter
        // side. Permission auto-reply is handled at spawn via CLI flag.
        capture_notification(&mut state.notifications, &message);
        cv.notify_all();
        return;
    }

    if let Some(id) = message.get("id").and_then(Value::as_u64) {
        if let Some(error) = message.get("error") {
            let detail = error
                .get("message")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .unwrap_or_else(|| error.to_string());
            let assistant_text = state.assistant_text.remove(&id).unwrap_or_default();
            state.prompt_terminals.insert(
                id,
                PromptTerminal {
                    stop_reason: "error".into(),
                    assistant_text,
                    error: Some(detail.clone()),
                },
            );
            state.responses.insert(id, Err(detail));
            clear_active_prompt(&mut state, id);
            cv.notify_all();
            return;
        }
        let result = message.get("result").cloned().unwrap_or(Value::Null);
        if let Some(stop_reason) = result.get("stopReason").and_then(Value::as_str) {
            let assistant_text = state.assistant_text.remove(&id).unwrap_or_default();
            state.prompt_terminals.insert(
                id,
                PromptTerminal {
                    stop_reason: stop_reason.to_owned(),
                    assistant_text,
                    error: None,
                },
            );
            clear_active_prompt(&mut state, id);
        }
        state.responses.insert(id, Ok(result));
        cv.notify_all();
        return;
    }

    // Notifications (no id).
    if let Some(method) = message.get("method").and_then(Value::as_str) {
        if method == "session/update" {
            accumulate_agent_chunk(&mut state, &message);
        }
        capture_notification(&mut state.notifications, &message);
        cv.notify_all();
    }
}

fn clear_active_prompt(state: &mut SharedState, request_id: u64) {
    state
        .active_prompt_by_session
        .retain(|_, id| *id != request_id);
}

fn accumulate_agent_chunk(state: &mut SharedState, message: &Value) {
    let params = message.get("params").cloned().unwrap_or(Value::Null);
    let session_id = params
        .get("sessionId")
        .and_then(Value::as_str)
        .unwrap_or("");
    let update = params.get("update").cloned().unwrap_or(params.clone());
    let kind = update
        .get("sessionUpdate")
        .and_then(Value::as_str)
        .unwrap_or("");
    if kind != "agent_message_chunk" {
        return;
    }
    let chunk = update
        .pointer("/content/text")
        .and_then(Value::as_str)
        .unwrap_or("");
    if chunk.is_empty() {
        return;
    }
    let Some(request_id) = state.active_prompt_by_session.get(session_id).copied() else {
        return;
    };
    if let Some(buf) = state.assistant_text.get_mut(&request_id) {
        buf.push_str(chunk);
    }
}

fn capture_notification(queue: &mut VecDeque<Value>, message: &Value) {
    if queue.len() == MAX_PENDING_NOTIFICATIONS {
        let _ = queue.pop_front();
    }
    queue.push_back(message.clone());
}

/// Seed an isolated gemini-dir with only the auth material the CLI needs.
/// Never logs token contents.
fn seed_isolated_gemini(gemini_dir: &Path, app_data_name: &str) -> Result<(), AdapterError> {
    let app_data = gemini_dir.join(app_data_name);
    std::fs::create_dir_all(&app_data)
        .map_err(|error| AdapterError::new(format!("create isolated gemini dir: {error}")))?;
    let src = crate::resolve::default_gemini_dir().join("antigravity-cli");
    for name in [
        "antigravity-oauth-token",
        "settings.json",
        "installation_id",
    ] {
        let from = src.join(name);
        let to = app_data.join(name);
        if from.is_file() {
            std::fs::copy(&from, &to)
                .map_err(|error| AdapterError::new(format!("seed {name}: {error}")))?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if let Ok(meta) = std::fs::metadata(&from) {
                    let _ = std::fs::set_permissions(&to, meta.permissions());
                } else {
                    let _ = std::fs::set_permissions(&to, std::fs::Permissions::from_mode(0o600));
                }
            }
        } else if from.is_dir() {
            copy_dir_recursive(&from, &to)?;
        }
    }
    Ok(())
}

fn copy_dir_recursive(from: &Path, to: &Path) -> Result<(), AdapterError> {
    std::fs::create_dir_all(to)
        .map_err(|error| AdapterError::new(format!("mkdir {}: {error}", to.display())))?;
    for entry in std::fs::read_dir(from)
        .map_err(|error| AdapterError::new(format!("read_dir {}: {error}", from.display())))?
    {
        let entry = entry.map_err(|error| AdapterError::new(format!("read_dir entry: {error}")))?;
        let src = entry.path();
        let dst = to.join(entry.file_name());
        if src.is_dir() {
            copy_dir_recursive(&src, &dst)?;
        } else if src.is_file() {
            std::fs::copy(&src, &dst)
                .map_err(|error| AdapterError::new(format!("copy {}: {error}", src.display())))?;
        }
    }
    Ok(())
}
