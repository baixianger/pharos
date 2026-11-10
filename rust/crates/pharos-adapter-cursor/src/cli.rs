//! Headless Cursor `agent` CLI process helpers (public CLI only).

use pharos_codex_adapter::{AdapterError, TurnOutcome, TurnStatus};
use serde_json::Value;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// In-flight `agent --print` turn.
pub struct ActiveCliTurn {
    pub turn_id: String,
    pub chat_id: String,
    child: Child,
    collector: Arc<Mutex<CollectedOutput>>,
    reader: Option<JoinHandle<()>>,
}

#[derive(Debug, Default, Clone)]
struct CollectedOutput {
    stdout: String,
    stderr: String,
}

#[derive(Debug, Clone)]
pub struct CliTurnResult {
    pub turn_id: String,
    pub chat_id: String,
    pub outcome: TurnOutcome,
    pub exit_code: Option<i32>,
    pub interrupted: bool,
}

#[derive(Debug, Clone)]
pub struct SpawnPromptOpts<'a> {
    pub executable: &'a Path,
    pub workspace: &'a Path,
    pub chat_id: &'a str,
    pub prompt: &'a str,
    pub model: Option<&'a str>,
    pub yolo: bool,
    pub turn_id: String,
    /// Prefer stream-json so partial events exist before a result line.
    pub stream_json: bool,
    /// Ask mode is read-only and enough for product round-trip markers.
    pub ask_mode: bool,
}

pub fn create_chat(executable: &Path, workspace: &Path) -> Result<String, AdapterError> {
    let output = Command::new(executable)
        .arg("create-chat")
        .current_dir(workspace)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| AdapterError::new(format!("spawn agent create-chat: {error}")))?;
    let stdout = String::from_utf8_lossy(&output.stdout)
        .trim()
        .trim_matches('\r')
        .to_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    if !output.status.success() {
        return Err(AdapterError::new(format!(
            "agent create-chat exited {}: {}",
            output.status.code().unwrap_or(-1),
            if stderr.is_empty() { stdout } else { stderr }
        )));
    }
    if !is_chat_id(&stdout) {
        return Err(AdapterError::new(format!(
            "agent create-chat returned non-UUID chat id: {stdout:?}"
        )));
    }
    Ok(stdout)
}

fn is_chat_id(raw: &str) -> bool {
    !raw.is_empty() && raw.len() <= 128 && raw.chars().all(|ch| ch.is_ascii_hexdigit() || ch == '-')
}

pub fn spawn_prompt(opts: SpawnPromptOpts<'_>) -> Result<ActiveCliTurn, AdapterError> {
    let mut command = Command::new(opts.executable);
    command
        .arg("--print")
        .arg("--output-format")
        .arg(if opts.stream_json {
            "stream-json"
        } else {
            "json"
        })
        .arg("--workspace")
        .arg(opts.workspace)
        .arg("--trust")
        .arg("--resume")
        .arg(opts.chat_id);
    if opts.ask_mode {
        command.arg("--mode").arg("ask");
    }
    if opts.yolo {
        command.arg("--force");
    }
    if let Some(model) = opts.model.filter(|m| !m.is_empty() && *m != "default") {
        command.arg("--model").arg(model);
    }
    command.arg(opts.prompt);
    command
        .current_dir(opts.workspace)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    // Own process group so interrupt can signal the whole tree without
    // affecting the Pharos parent.
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }

    let mut child = command
        .spawn()
        .map_err(|error| AdapterError::new(format!("spawn agent --print: {error}")))?;

    let collector = Arc::new(Mutex::new(CollectedOutput::default()));
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| AdapterError::new("agent stdout missing"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| AdapterError::new("agent stderr missing"))?;
    let collector_out = Arc::clone(&collector);
    let collector_err = Arc::clone(&collector);
    let stdout_thread = thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => {
                    if let Ok(mut guard) = collector_out.lock() {
                        guard.stdout.push_str(&line);
                    }
                }
                Err(_) => break,
            }
        }
    });
    let stderr_thread = thread::spawn(move || {
        let mut buf = String::new();
        let mut reader = BufReader::new(stderr);
        let _ = reader.read_to_string(&mut buf);
        if let Ok(mut guard) = collector_err.lock() {
            guard.stderr.push_str(&buf);
        }
    });
    let reader = Some(thread::spawn(move || {
        let _ = stdout_thread.join();
        let _ = stderr_thread.join();
    }));

    Ok(ActiveCliTurn {
        turn_id: opts.turn_id,
        chat_id: opts.chat_id.to_owned(),
        child,
        collector,
        reader,
    })
}

impl ActiveCliTurn {
    pub fn wait(mut self, timeout: Duration) -> Result<CliTurnResult, AdapterError> {
        let deadline = Instant::now() + timeout;
        loop {
            match self.child.try_wait() {
                Ok(Some(status)) => {
                    return self.finish(status.code(), false);
                }
                Ok(None) => {
                    if Instant::now() >= deadline {
                        let _ = self.signal_interrupt();
                        // Give the process a brief window to exit after SIGINT.
                        let grace = Instant::now() + Duration::from_secs(5);
                        while Instant::now() < grace {
                            match self.child.try_wait() {
                                Ok(Some(status)) => {
                                    return self.finish(status.code(), true);
                                }
                                Ok(None) => thread::sleep(Duration::from_millis(50)),
                                Err(error) => {
                                    return Err(AdapterError::new(format!(
                                        "wait after timeout kill: {error}"
                                    )));
                                }
                            }
                        }
                        let _ = self.child.kill();
                        let status = self.child.wait().ok().and_then(|s| s.code());
                        return self.finish(status, true);
                    }
                    thread::sleep(Duration::from_millis(50));
                }
                Err(error) => {
                    return Err(AdapterError::new(format!("try_wait agent: {error}")));
                }
            }
        }
    }

    pub fn interrupt(mut self) -> Result<CliTurnResult, AdapterError> {
        let _ = self.signal_interrupt();
        let grace = Instant::now() + Duration::from_secs(8);
        while Instant::now() < grace {
            match self.child.try_wait() {
                Ok(Some(status)) => {
                    return self.finish(status.code(), true);
                }
                Ok(None) => thread::sleep(Duration::from_millis(50)),
                Err(error) => {
                    return Err(AdapterError::new(format!(
                        "try_wait after interrupt: {error}"
                    )));
                }
            }
        }
        let _ = self.child.kill();
        let status = self.child.wait().ok().and_then(|s| s.code());
        self.finish(status, true)
    }

    fn signal_interrupt(&mut self) -> Result<(), AdapterError> {
        #[cfg(unix)]
        {
            let pid = self.child.id() as i32;
            // Negative PID = process group (we spawned with process_group(0)).
            let rc = unsafe { libc_kill(-pid, 2) }; // SIGINT
            if rc != 0 {
                let _ = self.child.kill();
            }
            Ok(())
        }
        #[cfg(not(unix))]
        {
            self.child
                .kill()
                .map_err(|error| AdapterError::new(format!("kill agent: {error}")))
        }
    }

    fn finish(
        mut self,
        exit_code: Option<i32>,
        interrupted: bool,
    ) -> Result<CliTurnResult, AdapterError> {
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
        let collected = self
            .collector
            .lock()
            .map(|guard| guard.clone())
            .unwrap_or_default();
        let parsed = parse_cli_output(&collected.stdout);
        let outcome = map_turn_outcome(
            &self.turn_id,
            parsed,
            &collected.stderr,
            exit_code,
            interrupted,
        );
        Ok(CliTurnResult {
            turn_id: self.turn_id,
            chat_id: self.chat_id,
            outcome,
            exit_code,
            interrupted,
        })
    }
}

#[derive(Debug, Clone, Default)]
struct ParsedCliOutput {
    result_text: Option<String>,
    session_id: Option<String>,
    is_error: bool,
    error_message: Option<String>,
    raw_subtype: Option<String>,
}

fn parse_cli_output(stdout: &str) -> ParsedCliOutput {
    let mut parsed = ParsedCliOutput::default();
    // stream-json: one JSON object per line; json mode: single object.
    for chunk in stdout.lines().chain(std::iter::once(stdout.trim())) {
        let line = chunk.trim();
        if line.is_empty() || !line.starts_with('{') {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if let Some(session_id) = value.get("session_id").and_then(Value::as_str) {
            parsed.session_id = Some(session_id.to_owned());
        }
        let type_name = value.get("type").and_then(Value::as_str).unwrap_or("");
        if type_name == "result" {
            parsed.raw_subtype = value
                .get("subtype")
                .and_then(Value::as_str)
                .map(str::to_owned);
            parsed.is_error = value
                .get("is_error")
                .and_then(Value::as_bool)
                .unwrap_or(false)
                || parsed.raw_subtype.as_deref() == Some("error");
            if let Some(result) = value.get("result").and_then(Value::as_str) {
                parsed.result_text = Some(result.to_owned());
            } else if let Some(result) = value.get("result") {
                parsed.result_text = Some(result.to_string());
            }
            if parsed.is_error {
                parsed.error_message = value
                    .get("error")
                    .and_then(|err| {
                        err.as_str().map(str::to_owned).or_else(|| {
                            err.get("message")
                                .and_then(Value::as_str)
                                .map(str::to_owned)
                        })
                    })
                    .or_else(|| parsed.result_text.clone());
            }
        }
        if type_name == "assistant"
            && parsed.result_text.is_none()
            && let Some(text) = extract_assistant_text(&value)
        {
            parsed.result_text = Some(text);
        }
    }
    parsed
}

fn extract_assistant_text(value: &Value) -> Option<String> {
    let content = value
        .pointer("/message/content")
        .and_then(Value::as_array)?;
    let mut parts = Vec::new();
    for item in content {
        if item.get("type").and_then(Value::as_str) == Some("text")
            && let Some(text) = item.get("text").and_then(Value::as_str)
        {
            parts.push(text);
        }
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts.join(""))
    }
}

fn map_turn_outcome(
    turn_id: &str,
    parsed: ParsedCliOutput,
    stderr: &str,
    exit_code: Option<i32>,
    interrupted: bool,
) -> TurnOutcome {
    // Hard rule: an interrupt path must never surface Completed.
    if interrupted {
        let detail = if stderr.trim().is_empty() {
            format!("interrupted (exit={exit_code:?})")
        } else {
            format!(
                "interrupted (exit={exit_code:?}): {}",
                stderr.chars().take(240).collect::<String>()
            )
        };
        return TurnOutcome {
            turn_id: turn_id.to_owned(),
            status: TurnStatus::Interrupted,
            raw_status: "interrupted".into(),
            assistant_text: parsed.result_text.unwrap_or_default(),
            vendor_error: Some(detail),
        };
    }

    if parsed.is_error {
        return TurnOutcome {
            turn_id: turn_id.to_owned(),
            status: TurnStatus::Failed,
            raw_status: parsed.raw_subtype.unwrap_or_else(|| "error".into()),
            assistant_text: parsed.result_text.clone().unwrap_or_default(),
            vendor_error: parsed.error_message.or_else(|| {
                if stderr.trim().is_empty() {
                    None
                } else {
                    Some(stderr.chars().take(240).collect())
                }
            }),
        };
    }

    // SIGINT classic exit without our interrupted flag (belt-and-suspenders).
    if matches!(exit_code, Some(130) | Some(143) | Some(-2)) {
        return TurnOutcome {
            turn_id: turn_id.to_owned(),
            status: TurnStatus::Interrupted,
            raw_status: "interrupted".into(),
            assistant_text: parsed.result_text.unwrap_or_default(),
            vendor_error: Some(format!("signal exit {exit_code:?}")),
        };
    }

    if !matches!(exit_code, Some(0) | None) && parsed.result_text.is_none() {
        return TurnOutcome {
            turn_id: turn_id.to_owned(),
            status: TurnStatus::Failed,
            raw_status: format!("exit-{}", exit_code.unwrap_or(-1)),
            assistant_text: String::new(),
            vendor_error: Some(if stderr.trim().is_empty() {
                format!("agent exited {exit_code:?}")
            } else {
                stderr.chars().take(240).collect()
            }),
        };
    }

    if let Some(text) = parsed.result_text {
        return TurnOutcome {
            turn_id: turn_id.to_owned(),
            status: TurnStatus::Completed,
            raw_status: "completed".into(),
            assistant_text: text,
            vendor_error: None,
        };
    }

    TurnOutcome {
        turn_id: turn_id.to_owned(),
        status: TurnStatus::Failed,
        raw_status: "unknown".into(),
        assistant_text: String::new(),
        vendor_error: Some(format!(
            "no result JSON from agent (exit={exit_code:?}; stderr={})",
            stderr.chars().take(160).collect::<String>()
        )),
    }
}

/// Unix kill(2) without taking a libc crate dependency.
#[cfg(unix)]
unsafe fn libc_kill(pid: i32, sig: i32) -> i32 {
    // libc is linked by std on Unix; declare the symbol locally.
    unsafe extern "C" {
        fn kill(pid: i32, sig: i32) -> i32;
    }
    unsafe { kill(pid, sig) }
}

pub fn agent_version(executable: &Path) -> String {
    Command::new(executable)
        .arg("--version")
        .output()
        .ok()
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .unwrap_or_else(|| "unknown".into())
        .trim()
        .to_owned()
}

pub fn default_msg_test_workspace(stamp: impl std::fmt::Display) -> PathBuf {
    crate::resolve::home_dir()
        .join("personal/pharos-msg-test/peer-phase-a")
        .join(format!("rust-adapter-cursor-{stamp}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_json_result_success() {
        let raw = r#"{"type":"result","subtype":"success","is_error":false,"result":"PONG","session_id":"abc"}"#;
        let parsed = parse_cli_output(raw);
        assert_eq!(parsed.result_text.as_deref(), Some("PONG"));
        assert!(!parsed.is_error);
        assert_eq!(parsed.session_id.as_deref(), Some("abc"));
    }

    #[test]
    fn parse_stream_json_prefers_result_line() {
        let raw = "\
{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"partial\"}]},\"session_id\":\"s1\"}
{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"FINAL\",\"session_id\":\"s1\"}
";
        let parsed = parse_cli_output(raw);
        assert_eq!(parsed.result_text.as_deref(), Some("FINAL"));
    }

    #[test]
    fn interrupt_mapping_never_completed() {
        let outcome = map_turn_outcome(
            "t1",
            ParsedCliOutput {
                result_text: Some("should-not-count".into()),
                ..Default::default()
            },
            "",
            Some(130),
            true,
        );
        assert_eq!(outcome.status, TurnStatus::Interrupted);
        assert_ne!(outcome.status, TurnStatus::Completed);
    }

    #[test]
    fn chat_id_accepts_uuid() {
        assert!(is_chat_id("352180ed-f51b-40d9-a814-3db6718c01ca"));
        assert!(!is_chat_id("not a chat"));
    }
}
