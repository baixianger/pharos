//! Deferred-approval Codex App Server client for live HITL.
//!
//! Unlike `pharos-codex-adapter` stdio transport (which auto-accepts approvals),
//! this client **queues** `item/*/requestApproval` server requests until
//! [`CodexHitlClient::resolve_approval`] answers them.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use pharos_api::{ApprovalDecision, ApprovalKind, ApprovalRequest};
use pharos_codex_adapter::resolve::resolve_codex_executable;
use serde_json::{Value, json};

use crate::error::HitlError;
use crate::pending::HitlDecision;

#[derive(Debug, Clone)]
pub struct PendingCodexApproval {
    /// JSON-RPC request id from Codex (answer with same id).
    pub rpc_id: Value,
    pub method: String,
    pub approval: ApprovalRequest,
    pub command: Option<String>,
    pub cwd: Option<String>,
}

pub struct CodexHitlClient {
    child: Child,
    /// Local code-mode host (Codex 0.167 shell path); killed on drop.
    code_mode_host: Option<Child>,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_id: u64,
    pending_approvals: VecDeque<PendingCodexApproval>,
    notifications: VecDeque<Value>,
    thread_id: Option<String>,
}

impl CodexHitlClient {
    pub fn connect_stdio() -> Result<Self, HitlError> {
        let executable = resolve_codex_executable().map_err(HitlError::new)?;
        Self::connect_stdio_executable(&executable, None, None, None)
    }

    /// Isolated CODEX_HOME + local code-mode-host for HITL approvals.
    ///
    /// Copies `auth.json` only (never logs it) and writes a minimal
    /// `config.toml` with `approval_policy=on-request` so the user's global
    /// `approval_policy=never` cannot suppress approvals. Spawns a loopback
    /// `codex-code-mode-host` (required on Codex 0.167 or shell times out).
    pub fn connect_stdio_hitl_home(codex_home: &Path) -> Result<Self, HitlError> {
        let executable = resolve_codex_executable().map_err(HitlError::new)?;
        prepare_hitl_codex_home(codex_home)?;
        let (code_mode_host, code_mode_url) = spawn_code_mode_host()?;
        Self::connect_stdio_executable(
            &executable,
            Some(codex_home),
            Some(code_mode_host),
            Some(code_mode_url),
        )
    }

    pub fn connect_stdio_executable(
        executable: &Path,
        codex_home: Option<&Path>,
        code_mode_host: Option<Child>,
        code_mode_url: Option<String>,
    ) -> Result<Self, HitlError> {
        let mut command = Command::new(executable);
        command
            .arg("app-server")
            .arg("--stdio")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env_remove("CODEX_HOME");
        if let Some(home) = codex_home {
            command.env("CODEX_HOME", home);
        }
        if let Some(url) = &code_mode_url {
            command.arg("--code-mode-host").arg(url);
        }
        command.arg("-c").arg("approval_policy=\"on-request\"");
        command.arg("-c").arg("sandbox_mode=\"read-only\"");
        let mut child = command
            .spawn()
            .map_err(|e| HitlError::new(format!("spawn codex app-server: {e}")))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| HitlError::new("missing stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| HitlError::new("missing stdout"))?;
        let mut client = Self {
            child,
            code_mode_host,
            stdin,
            stdout: BufReader::new(stdout),
            next_id: 1,
            pending_approvals: VecDeque::new(),
            notifications: VecDeque::new(),
            thread_id: None,
        };
        client.request(
            "initialize",
            json!({
                "clientInfo": {"name": "pharos-hitl", "title": "Pharos HITL", "version": "0.1.0"},
                "capabilities": {"experimentalApi": true}
            }),
        )?;
        // Best-effort initialized notification.
        let _ = client.notify("initialized", json!({}));
        Ok(client)
    }

    pub fn start_session_on_request(&mut self, workspace: &Path) -> Result<String, HitlError> {
        let result = self.request(
            "thread/start",
            json!({
                "cwd": workspace.display().to_string(),
                "approvalPolicy": "on-request",
                // read-only forces escalation prompts for shell exec (Swift peer HITL parity).
                "sandbox": "read-only",
            }),
        )?;
        let thread = result.get("thread").cloned().unwrap_or(result);
        let id = thread
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| HitlError::new("thread/start missing id"))?
            .to_owned();
        self.thread_id = Some(id.clone());
        Ok(id)
    }

    pub fn start_turn(&mut self, prompt: &str) -> Result<String, HitlError> {
        let thread_id = self
            .thread_id
            .clone()
            .ok_or_else(|| HitlError::new("no thread"))?;
        // Ensure idle before queueing a new turn (Codex race).
        self.wait_until_idle(Duration::from_secs(45))?;
        let result = self.request(
            "turn/start",
            json!({
                "threadId": thread_id,
                "input": [{"type": "text", "text": prompt}],
                "approvalPolicy": "on-request",
            }),
        )?;
        let turn = result.get("turn").cloned().unwrap_or(result);
        turn.get("id")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| HitlError::new("turn/start missing id"))
    }

    pub fn wait_turn_terminal(
        &mut self,
        turn_id: &str,
        timeout: Duration,
    ) -> Result<String, HitlError> {
        let deadline = Instant::now() + timeout;
        let mut last_error: Option<String> = None;
        while Instant::now() < deadline {
            match self.turn_status(turn_id) {
                Ok(Some(status))
                    if matches!(
                        status.as_str(),
                        "completed" | "failed" | "interrupted" | "cancelled"
                    ) =>
                {
                    return Ok(status);
                }
                Ok(_) => {}
                Err(e) => last_error = Some(e.to_string()),
            }
            thread::sleep(Duration::from_millis(400));
        }
        Err(HitlError::new(format!(
            "timed out waiting for turn {turn_id}{}",
            last_error
                .map(|e| format!(" (last error: {e})"))
                .unwrap_or_default()
        )))
    }

    pub fn poll_approval(
        &mut self,
        wait: Duration,
    ) -> Result<Option<PendingCodexApproval>, HitlError> {
        let deadline = Instant::now() + wait;
        loop {
            if let Some(pending) = self.pending_approvals.pop_front() {
                return Ok(Some(pending));
            }
            if Instant::now() >= deadline {
                return Ok(None);
            }
            // Drive I/O via thread/read so server→client approval requests are captured
            // inside `request()` (blocking read only while a response is expected).
            let _ = self.turn_status("__poll__");
            thread::sleep(Duration::from_millis(300));
        }
    }

    pub fn resolve_approval(
        &mut self,
        pending: &PendingCodexApproval,
        decision: HitlDecision,
    ) -> Result<(), HitlError> {
        let decision_str = match decision {
            HitlDecision::AllowedOnce => "accept",
            HitlDecision::Denied => "decline",
        };
        let payload = json!({
            "id": pending.rpc_id.clone(),
            "result": { "decision": decision_str }
        });
        self.write_json(&payload)?;
        Ok(())
    }

    pub fn api_decision(decision: HitlDecision) -> ApprovalDecision {
        match decision {
            HitlDecision::AllowedOnce => ApprovalDecision::AllowedOnce,
            HitlDecision::Denied => ApprovalDecision::Rejected,
        }
    }

    fn wait_until_idle(&mut self, timeout: Duration) -> Result<(), HitlError> {
        let Some(thread_id) = self.thread_id.clone() else {
            return Ok(());
        };
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            // Prefer thread/read without includeTurns (empty threads may reject includeTurns).
            match self.request(
                "thread/read",
                json!({
                    "threadId": thread_id,
                }),
            ) {
                Ok(result) => {
                    let thread = result.get("thread").cloned().unwrap_or(result);
                    let status = thread
                        .get("status")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown");
                    if matches!(status, "idle" | "ready" | "") {
                        return Ok(());
                    }
                    let turns = thread
                        .get("turns")
                        .and_then(Value::as_array)
                        .cloned()
                        .unwrap_or_default();
                    let any_active = turns.iter().any(|t| {
                        matches!(
                            t.get("status").and_then(Value::as_str),
                            Some("inProgress") | Some("active")
                        )
                    });
                    if !any_active {
                        return Ok(());
                    }
                }
                Err(_) => {
                    // Empty-thread races are possible; keep trying.
                }
            }
            thread::sleep(Duration::from_millis(300));
        }
        Ok(())
    }

    fn turn_status(&mut self, turn_id: &str) -> Result<Option<String>, HitlError> {
        let Some(thread_id) = self.thread_id.clone() else {
            return Ok(None);
        };
        let result = self.request(
            "thread/read",
            json!({
                "threadId": thread_id,
                "includeTurns": true,
            }),
        )?;
        let thread = result.get("thread").cloned().unwrap_or(result);
        let turns = thread
            .get("turns")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for turn in turns {
            if turn.get("id").and_then(Value::as_str) == Some(turn_id) {
                return Ok(turn
                    .get("status")
                    .and_then(Value::as_str)
                    .map(str::to_owned));
            }
        }
        Ok(None)
    }

    fn notify(&mut self, method: &str, params: Value) -> Result<(), HitlError> {
        self.write_json(&json!({"method": method, "params": params}))
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value, HitlError> {
        let id = Value::from(self.next_id);
        self.next_id = self.next_id.saturating_add(1);
        self.write_json(&json!({"id": id.clone(), "method": method, "params": params}))?;
        let deadline = Instant::now() + Duration::from_secs(120);
        loop {
            if Instant::now() >= deadline {
                return Err(HitlError::new(format!(
                    "timed out waiting for Codex response to {method}"
                )));
            }
            if let Some(status) = self
                .child
                .try_wait()
                .map_err(|e| HitlError::new(e.to_string()))?
            {
                return Err(HitlError::new(format!(
                    "Codex app-server exited ({status})"
                )));
            }
            let message = self.read_line_blocking()?;
            if message.get("method").is_some()
                && message.get("id").is_some()
                && message.get("result").is_none()
                && message.get("error").is_none()
            {
                self.capture_server_request(&message)?;
                continue;
            }
            if message.get("id") == Some(&id) {
                if let Some(err) = message.get("error") {
                    return Err(HitlError::new(format!("Codex error on {method}: {err}")));
                }
                return Ok(message.get("result").cloned().unwrap_or(Value::Null));
            }
            self.notifications.push_back(message);
            while self.notifications.len() > 64 {
                self.notifications.pop_front();
            }
        }
    }

    fn capture_server_request(&mut self, message: &Value) -> Result<(), HitlError> {
        let method = message
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        let rpc_id = message
            .get("id")
            .cloned()
            .ok_or_else(|| HitlError::new("server request missing id"))?;
        let params = message.get("params").cloned().unwrap_or(Value::Null);

        if method.contains("requestApproval") || method.contains("requestUserInput") {
            let approval_id = rpc_id
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| rpc_id.to_string());
            let session_id = self.thread_id.clone().unwrap_or_default();
            let command = params
                .get("command")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let cwd = params.get("cwd").and_then(Value::as_str).map(str::to_owned);
            let reason = params
                .get("reason")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let tool_name = if method.contains("fileChange") {
                "fileChange"
            } else if method.contains("requestUserInput") {
                "requestUserInput"
            } else {
                "commandExecution"
            };
            let mut tool_params = serde_json::Map::new();
            if let Some(cmd) = &command {
                tool_params.insert("command".into(), Value::String(cmd.clone()));
            }
            if let Some(c) = &cwd {
                tool_params.insert("cwd".into(), Value::String(c.clone()));
            }
            let approval = ApprovalRequest {
                approval_id: approval_id.clone(),
                session_id,
                kind: ApprovalKind::ToolPermission {
                    tool_name: tool_name.into(),
                    params: Value::Object(tool_params),
                    explanation: reason,
                },
                available_choices: Some(vec![
                    "rejected".into(),
                    "allowedOnce".into(),
                    "allowedAlways".into(),
                ]),
            };
            self.pending_approvals.push_back(PendingCodexApproval {
                rpc_id,
                method,
                approval,
                command,
                cwd,
            });
            return Ok(());
        }

        // Unknown server request: acknowledge empty to avoid stalling Codex.
        let payload = json!({"id": rpc_id, "result": {}});
        self.write_json(&payload)?;
        Ok(())
    }

    fn write_json(&mut self, value: &Value) -> Result<(), HitlError> {
        let bytes = serde_json::to_vec(value)?;
        self.stdin.write_all(&bytes)?;
        self.stdin.write_all(b"\n")?;
        self.stdin.flush()?;
        Ok(())
    }

    fn read_line_blocking(&mut self) -> Result<Value, HitlError> {
        loop {
            let mut line = String::new();
            match self.stdout.read_line(&mut line) {
                Ok(0) => {
                    thread::sleep(Duration::from_millis(20));
                    continue;
                }
                Ok(_) => {
                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        continue;
                    }
                    return Ok(serde_json::from_str(trimmed)?);
                }
                Err(e) => return Err(HitlError::new(e.to_string())),
            }
        }
    }
}

impl Drop for CodexHitlClient {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(mut host) = self.code_mode_host.take() {
            let _ = host.kill();
            let _ = host.wait();
        }
    }
}

fn spawn_code_mode_host() -> Result<(Child, String), HitlError> {
    // Prefer the versioned daemon package binary next to managed Codex installs.
    let home = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("/"));
    let packaged = home
        .join(".codex/packages/app-server-daemon/releases/0.167.0-aarch64-apple-darwin/bin/codex-code-mode-host");
    let candidates = [
        packaged,
        Path::new("/opt/homebrew/bin/codex-code-mode-host").to_path_buf(),
    ];
    let bin = candidates
        .into_iter()
        .find(|p| p.is_file())
        .ok_or_else(|| HitlError::new("codex-code-mode-host binary not found"))?;
    // Bind an ephemeral port via asking the OS — host CLI wants host:port; pick free port.
    let listener = std::net::TcpListener::bind("127.0.0.1:0")
        .map_err(|e| HitlError::new(format!("bind ephemeral for code-mode-host: {e}")))?;
    let port = listener
        .local_addr()
        .map_err(|e| HitlError::new(e.to_string()))?
        .port();
    drop(listener);
    let url = format!("http://127.0.0.1:{port}");
    let child = Command::new(bin)
        .arg("--listen")
        .arg(format!("grpc://127.0.0.1:{port}"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| HitlError::new(format!("spawn codex-code-mode-host: {e}")))?;
    // Brief settle so app-server can connect.
    thread::sleep(Duration::from_millis(400));
    Ok((child, url))
}

/// Prepare an isolated HITL CODEX_HOME under msg-test.
/// Copies auth only; writes HITL-forcing config. Never logs auth contents.
pub fn prepare_hitl_codex_home(codex_home: &Path) -> Result<(), HitlError> {
    std::fs::create_dir_all(codex_home)?;
    let _ = std::fs::create_dir_all(codex_home.join("sessions"));
    let user_home = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("/"))
        .join(".codex");
    let auth_src = user_home.join("auth.json");
    if auth_src.is_file() {
        let dst = codex_home.join("auth.json");
        std::fs::copy(&auth_src, &dst)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&dst, std::fs::Permissions::from_mode(0o600));
        }
    }
    // Force approvals — do not copy the user's global config.toml (often `never`).
    let config = concat!(
        "approval_policy = \"on-request\"\n",
        "approvals_reviewer = \"user\"\n",
        "sandbox_mode = \"read-only\"\n",
    );
    let cfg_path = codex_home.join("config.toml");
    std::fs::write(&cfg_path, config)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&cfg_path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}
