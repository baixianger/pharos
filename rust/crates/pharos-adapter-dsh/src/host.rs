//! Isolated `dsh web` Host process management.
//!
//! Spawns `dsh --profile web --no-open --port 0 --host 127.0.0.1` under a private
//! `DSH_HOME`. Never touches the shared 3080 Host / its token / ipc.sock /
//! workspace.json. Auth is seeded by copying `~/.dsh/.credentials.yaml` only;
//! tokens stay in memory and are never logged.

use pharos_codex_adapter::AdapterError;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

/// Default model routing patch for isolated product-path Hosts (matches Swift
/// `MeshHostThreadBindingTests` isolated DSH setup).
pub const DEFAULT_MODEL_PATCH: &str = r#"- id: agent-default-model
  name: "@deepseek-ai/dsh-agent-default-model"
  config:
    provider: opencode-go
    model: deepseek-v4.1-flash
- id: llm-pi-ai
  name: "@deepseek-ai/dsh-llm-pi-ai"
  config:
    providers:
      opencode-go:
        apiKeyEnv: OPENCODE_GO_API_KEY
"#;

#[derive(Debug, Clone)]
pub struct DshHostConfig {
    pub executable: PathBuf,
    pub dsh_home: PathBuf,
    pub workspace: PathBuf,
    pub model_patch: Option<PathBuf>,
    /// Extra env (must not include secrets that we would log).
    pub extra_env: Vec<(String, String)>,
}

impl Default for DshHostConfig {
    fn default() -> Self {
        Self {
            executable: resolve_dsh_executable_default(),
            dsh_home: PathBuf::from("/tmp/pharos-dsh-home-unset"),
            workspace: PathBuf::from("/tmp/pharos-dsh-work-unset"),
            model_patch: None,
            extra_env: Vec::new(),
        }
    }
}

fn resolve_dsh_executable_default() -> PathBuf {
    if let Ok(path) = std::env::var("PHAROS_DSH_EXECUTABLE") {
        return PathBuf::from(path);
    }
    for candidate in [
        "/home/box/.local/bin/dsh",
        "/usr/local/bin/dsh",
        "/opt/homebrew/bin/dsh",
    ] {
        let path = PathBuf::from(candidate);
        if path.is_file() {
            return path;
        }
    }
    PathBuf::from("dsh")
}

/// Copy credentials (+ anonymous id) into an empty isolated `DSH_HOME`.
/// Also returns `OPENCODE_GO_API_KEY` when present in credentials or the process env.
pub fn prepare_isolated_home(isolated_home: &Path) -> Result<Option<String>, AdapterError> {
    fs::create_dir_all(isolated_home).map_err(|e| {
        AdapterError::new(format!(
            "create isolated DSH_HOME {}: {e}",
            isolated_home.display()
        ))
    })?;
    let user_home = dirs_dsh_user_home()?;
    let credentials = user_home.join(".credentials.yaml");
    if !credentials.is_file() {
        return Err(AdapterError::new(
            "missing ~/.dsh/.credentials.yaml; cannot seed isolated DSH_HOME",
        ));
    }
    let dest_creds = isolated_home.join(".credentials.yaml");
    if !dest_creds.exists() {
        fs::copy(&credentials, &dest_creds)
            .map_err(|e| AdapterError::new(format!("copy credentials: {e}")))?;
        // Restrict perms best-effort.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&dest_creds, fs::Permissions::from_mode(0o600));
        }
    }
    let anonymous = user_home.join(".anonymous-user-id");
    if anonymous.is_file() {
        let dest = isolated_home.join(".anonymous-user-id");
        if !dest.exists() {
            let _ = fs::copy(&anonymous, &dest);
        }
    }

    if let Ok(value) = std::env::var("OPENCODE_GO_API_KEY")
        && !value.is_empty()
    {
        return Ok(Some(value));
    }
    let text = fs::read_to_string(&credentials)
        .map_err(|e| AdapterError::new(format!("read credentials: {e}")))?;
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("OPENCODE_GO_API_KEY:") {
            let value = rest.trim();
            if !value.is_empty() {
                return Ok(Some(value.to_owned()));
            }
        }
    }
    Ok(None)
}

fn dirs_dsh_user_home() -> Result<PathBuf, AdapterError> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| AdapterError::new("HOME unset"))?;
    Ok(home.join(".dsh"))
}

/// Running isolated `dsh web` Host. Token is held only in memory.
pub struct DshHost {
    child: Child,
    port: u16,
    token: String,
    _home: PathBuf,
}

impl DshHost {
    pub fn start(config: DshHostConfig) -> Result<Self, AdapterError> {
        fs::create_dir_all(&config.dsh_home).map_err(|e| {
            AdapterError::new(format!("DSH_HOME {}: {e}", config.dsh_home.display()))
        })?;
        fs::create_dir_all(&config.workspace).map_err(|e| {
            AdapterError::new(format!("workspace {}: {e}", config.workspace.display()))
        })?;

        let api_key = prepare_isolated_home(&config.dsh_home)?;
        let api_key = api_key.ok_or_else(|| {
            AdapterError::new("OPENCODE_GO_API_KEY unavailable for isolated DSH Host")
        })?;

        let patch = match &config.model_patch {
            Some(path) => path.clone(),
            None => {
                let path = config.dsh_home.join("pharos-model.patch.yml");
                fs::write(&path, DEFAULT_MODEL_PATCH)
                    .map_err(|e| AdapterError::new(format!("write model patch: {e}")))?;
                path
            }
        };

        let mut command = Command::new(&config.executable);
        command
            .arg("--profile")
            .arg("web")
            .arg("--patch")
            .arg(&patch)
            .arg("--no-open")
            .arg("--port")
            .arg("0")
            .arg("--host")
            .arg("127.0.0.1")
            .current_dir(&config.workspace)
            .env("DSH_HOME", &config.dsh_home)
            .env("OPENCODE_GO_API_KEY", &api_key)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .stdin(Stdio::null());
        // Never inherit a foreign DSH_HOME pointing at the 3080 Host.
        for (key, value) in &config.extra_env {
            command.env(key, value);
        }

        let mut child = command
            .spawn()
            .map_err(|e| AdapterError::new(format!("spawn dsh web: {e}")))?;

        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| AdapterError::new("dsh web stdout missing"))?;
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines().map_while(Result::ok) {
                if let Some(endpoint) = parse_startup_line(&line) {
                    let _ = tx.send(endpoint);
                    // Keep draining so the child does not block on a full pipe.
                }
            }
        });

        let deadline = Instant::now() + Duration::from_secs(20);
        let (port, token) = loop {
            if Instant::now() > deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err(AdapterError::new(
                    "DSH Host did not announce a loopback endpoint within 20s",
                ));
            }
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(endpoint) => break endpoint,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if let Ok(Some(status)) = child.try_wait() {
                        return Err(AdapterError::new(format!(
                            "DSH Host exited during startup: {status}"
                        )));
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(AdapterError::new(
                        "DSH Host stdout closed before announcing endpoint",
                    ));
                }
            }
        };

        Ok(Self {
            child,
            port,
            token,
            _home: config.dsh_home,
        })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// Volatile auth token — callers must not log or persist this.
    pub fn token(&self) -> &str {
        &self.token
    }

    pub fn is_running(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    pub fn stop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for DshHost {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Parse `dsh web: http://127.0.0.1:<port>/?token=<token>` without logging the token.
pub fn parse_startup_line(line: &str) -> Option<(u16, String)> {
    let marker = "dsh web: http://127.0.0.1:";
    let idx = line.find(marker)?;
    let rest = &line[idx + marker.len()..];
    let (port_s, after) = rest.split_once("/?token=")?;
    let port: u16 = port_s.parse().ok()?;
    let token = after.split_whitespace().next()?.to_owned();
    if token.is_empty() {
        return None;
    }
    Some((port, token))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_startup_line_extracts_port() {
        let line = "dsh web: http://127.0.0.1:41234/?token=abcTOKEN123";
        let (port, token) = parse_startup_line(line).expect("parse");
        assert_eq!(port, 41234);
        assert_eq!(token, "abcTOKEN123");
    }

    #[test]
    fn parse_startup_line_rejects_noise() {
        assert!(parse_startup_line("listening on something else").is_none());
    }
}
