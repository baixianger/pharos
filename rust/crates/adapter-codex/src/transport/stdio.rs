use super::{
    AppServerTransport, MAX_PENDING_NOTIFICATIONS, capture_notification_into, response_result,
};
use crate::error::AdapterError;
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

/// Isolated stdio App Server (`codex app-server`) — equivalent of Swift
/// `CodexStdioTransport`. Prefer this for product-path tests so the shared
/// daemon worker cannot steal deliveries.
pub struct StdioAppServer {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    notifications: VecDeque<Value>,
    next_id: u64,
}

impl StdioAppServer {
    pub fn connect(executable: &Path) -> Result<Self, AdapterError> {
        Self::connect_with_env(executable, None)
    }

    pub fn connect_with_env(
        executable: &Path,
        extra_env: Option<&[(String, String)]>,
    ) -> Result<Self, AdapterError> {
        let mut command = Command::new(executable);
        command
            .arg("app-server")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        // Never inherit a stale CODEX_HOME from the parent agent shell unless
        // the caller explicitly set one in extra_env.
        command.env_remove("CODEX_HOME");
        if let Some(pairs) = extra_env {
            for (key, value) in pairs {
                command.env(key, value);
            }
        }
        let mut child = command
            .spawn()
            .map_err(|error| AdapterError::new(format!("start codex app-server: {error}")))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| AdapterError::new("app-server stdin unavailable"))?;
        let stdout = BufReader::new(
            child
                .stdout
                .take()
                .ok_or_else(|| AdapterError::new("app-server stdout unavailable"))?,
        );
        let mut server = Self {
            child,
            stdin,
            stdout,
            notifications: VecDeque::new(),
            next_id: 1,
        };
        server.request(
            Value::from("pharos-initialize"),
            "initialize",
            json!({
                "clientInfo": {"name": "pharos", "title": "Pharos", "version": "0.1.0"},
                "capabilities": {"experimentalApi": false}
            }),
        )?;
        // Best-effort initialized notification (some builds ignore it).
        let _ = server.notify("initialized", json!({}));
        Ok(server)
    }

    pub fn connect_isolated(executable: &Path, codex_home: &Path) -> Result<Self, AdapterError> {
        std::fs::create_dir_all(codex_home)
            .map_err(|error| AdapterError::new(format!("create CODEX_HOME: {error}")))?;
        // Copy auth/config from the user home without logging contents.
        seed_codex_home(codex_home)?;
        Self::connect_with_env(
            executable,
            Some(&[("CODEX_HOME".to_string(), codex_home.display().to_string())]),
        )
    }

    fn notify(&mut self, method: &str, params: Value) -> Result<(), AdapterError> {
        let payload = serde_json::to_vec(&json!({"method": method, "params": params}))
            .map_err(|error| AdapterError::new(error.to_string()))?;
        self.stdin
            .write_all(&payload)
            .and_then(|_| self.stdin.write_all(b"\n"))
            .and_then(|_| self.stdin.flush())
            .map_err(|error| AdapterError::new(error.to_string()))
    }

    fn write_request(
        &mut self,
        id: &Value,
        method: &str,
        params: Value,
    ) -> Result<(), AdapterError> {
        let payload = serde_json::to_vec(&json!({"id": id, "method": method, "params": params}))
            .map_err(|error| AdapterError::new(error.to_string()))?;
        self.stdin
            .write_all(&payload)
            .and_then(|_| self.stdin.write_all(b"\n"))
            .and_then(|_| self.stdin.flush())
            .map_err(|error| AdapterError::new(error.to_string()))
    }

    fn read_message(&mut self, timeout: Duration) -> Result<Value, AdapterError> {
        let deadline = Instant::now() + timeout;
        loop {
            if Instant::now() >= deadline {
                return Err(AdapterError::new("Codex app-server read timed out"));
            }
            if let Some(status) = self
                .child
                .try_wait()
                .map_err(|error| AdapterError::new(error.to_string()))?
            {
                let mut stderr = String::new();
                if let Some(mut err) = self.child.stderr.take() {
                    let _ = std::io::Read::read_to_string(&mut err, &mut stderr);
                }
                let detail = stderr.trim();
                return Err(AdapterError::new(if detail.is_empty() {
                    format!("Codex app-server exited ({status})")
                } else {
                    format!("Codex app-server exited ({status}): {detail}")
                }));
            }
            // BufReader has no native timeout; poll via non-blocking would need
            // nix. Use a short blocking read with try_wait checks between lines
            // by setting read timeout on the fd when available.
            let mut line = String::new();
            match self.stdout.read_line(&mut line) {
                Ok(0) => {
                    std::thread::sleep(Duration::from_millis(20));
                    continue;
                }
                Ok(_) => {
                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        continue;
                    }
                    return serde_json::from_str(trimmed)
                        .map_err(|error| AdapterError::new(error.to_string()));
                }
                Err(error) => return Err(AdapterError::new(error.to_string())),
            }
        }
    }

    fn answer_server_request(&mut self, message: &Value) -> Result<(), AdapterError> {
        let Some(id) = message.get("id").cloned() else {
            return Ok(());
        };
        let method = message.get("method").and_then(Value::as_str).unwrap_or("");
        let result = if method.contains("approval") || method.contains("commandExecution") {
            json!({"decision": "accept"})
        } else {
            json!({})
        };
        let payload = serde_json::to_vec(&json!({"id": id, "result": result}))
            .map_err(|error| AdapterError::new(error.to_string()))?;
        self.stdin
            .write_all(&payload)
            .and_then(|_| self.stdin.write_all(b"\n"))
            .and_then(|_| self.stdin.flush())
            .map_err(|error| AdapterError::new(error.to_string()))
    }
}

impl AppServerTransport for StdioAppServer {
    fn request(&mut self, id: Value, method: &str, params: Value) -> Result<Value, AdapterError> {
        let id = if id.is_null() {
            let generated = Value::from(self.next_id);
            self.next_id = self.next_id.saturating_add(1);
            generated
        } else {
            id
        };
        self.write_request(&id, method, params)?;
        let deadline = Duration::from_secs(120);
        let started = Instant::now();
        loop {
            let remaining = deadline.saturating_sub(started.elapsed());
            if remaining.is_zero() {
                return Err(AdapterError::new(format!(
                    "timed out waiting for Codex response to {method}"
                )));
            }
            let message = self.read_message(remaining.min(Duration::from_secs(30)))?;
            // Server→client request
            if message.get("method").is_some()
                && message.get("id").is_some()
                && message.get("result").is_none()
                && message.get("error").is_none()
            {
                self.answer_server_request(&message)?;
                continue;
            }
            if let Some(result) = response_result(&message, &id)? {
                return Ok(result);
            }
            capture_notification_into(&mut self.notifications, &message, MAX_PENDING_NOTIFICATIONS);
        }
    }

    fn take_notifications(&mut self) -> Vec<Value> {
        self.notifications.drain(..).collect()
    }

    fn close(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for StdioAppServer {
    fn drop(&mut self) {
        self.close();
    }
}

fn seed_codex_home(codex_home: &Path) -> Result<(), AdapterError> {
    let user_home = crate::resolve::home_dir().join(".codex");
    for name in ["auth.json", "config.toml"] {
        let src = user_home.join(name);
        if src.is_file() {
            let dst = codex_home.join(name);
            std::fs::copy(&src, &dst)
                .map_err(|error| AdapterError::new(format!("seed {name}: {error}")))?;
            // Preserve restrictive mode best-effort.
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if let Ok(meta) = std::fs::metadata(&src) {
                    let _ = std::fs::set_permissions(&dst, meta.permissions());
                } else {
                    let _ = std::fs::set_permissions(&dst, std::fs::Permissions::from_mode(0o600));
                }
            }
        }
    }
    // Ensure sessions dir exists so rollouts are not empty-race as often.
    let _ = std::fs::create_dir_all(codex_home.join("sessions"));
    let _ = PathBuf::from(codex_home);
    Ok(())
}
