use crate::delivery::{
    DeliveryDispatchResult, DeliveryJob, DeliveryWorker, format_delivery_prompt,
};
use crate::error::AdapterError;
use crate::resolve::resolve_agy_executable;
use crate::session::{
    InterruptOutcome, PromptMode, SessionAdapter, StartSessionRequest, StartedSession, StartedTurn,
    TurnOutcome, TurnStatus,
};
use crate::transport::{AcpSpawnOptions, AcpTransport};
use pharos_api::AdapterManifest;
use pharos_protocol::AdapterKind;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

#[derive(Clone)]
struct ActiveTurn {
    request_id: u64,
    turn_id: String,
}

/// Agy ACP (`agy acp --stdio`) session + delivery adapter (S5c).
pub struct AgySessionAdapter {
    transport: AcpTransport,
    /// Pharos session id → vendor ACP sessionId
    sessions: HashMap<String, String>,
    /// session id → active turn
    active_turns: HashMap<String, ActiveTurn>,
    /// Completed turn outcomes retained for `read_turns`.
    turn_history: HashMap<String, Vec<TurnOutcome>>,
}

impl AgySessionAdapter {
    pub fn connect() -> Result<Self, AdapterError> {
        let executable = resolve_agy_executable().map_err(AdapterError::new)?;
        Self::connect_executable(&executable, None, true)
    }

    pub fn connect_executable(
        executable: &Path,
        isolated_gemini_dir: Option<&Path>,
        dangerously_skip_permissions: bool,
    ) -> Result<Self, AdapterError> {
        let transport = AcpTransport::spawn(AcpSpawnOptions {
            executable: executable.to_path_buf(),
            workspace_hint: None,
            isolated_gemini_dir: isolated_gemini_dir.map(Path::to_path_buf),
            app_data_dir_name: "antigravity-cli".into(),
            dangerously_skip_permissions,
        })?;
        Ok(Self {
            transport,
            sessions: HashMap::new(),
            active_turns: HashMap::new(),
            turn_history: HashMap::new(),
        })
    }

    /// Isolated gemini-dir under msg-test (auth seeded; never logs secrets).
    pub fn connect_isolated(gemini_dir: &Path) -> Result<Self, AdapterError> {
        let executable = resolve_agy_executable().map_err(AdapterError::new)?;
        Self::connect_executable(&executable, Some(gemini_dir), true)
    }

    fn vendor_session(&self, session_id: &str) -> Result<String, AdapterError> {
        self.sessions
            .get(session_id)
            .cloned()
            .ok_or_else(|| AdapterError::new(format!("unknown session: {session_id}")))
    }

    fn push_history(&mut self, session_id: &str, outcome: TurnOutcome) {
        self.turn_history
            .entry(session_id.to_owned())
            .or_default()
            .push(outcome);
    }

    pub fn take_notifications(&mut self) -> Vec<Value> {
        self.transport.take_notifications()
    }

    pub fn wait_until_idle(
        &mut self,
        session_id: &str,
        timeout: Duration,
    ) -> Result<(), AdapterError> {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if !self.active_turns.contains_key(session_id) {
                let _ = self.transport.take_notifications();
                return Ok(());
            }
            if let Some(active) = self.active_turns.get(session_id).cloned() {
                // Non-blocking peek: try a very short wait.
                match self
                    .transport
                    .wait_prompt(active.request_id, Duration::from_millis(50))
                {
                    Ok(terminal) => {
                        let status = TurnStatus::from_stop_reason(&terminal.stop_reason);
                        let outcome = TurnOutcome {
                            turn_id: active.turn_id.clone(),
                            status,
                            raw_status: terminal.stop_reason,
                            assistant_text: terminal.assistant_text,
                            vendor_error: terminal.error,
                        };
                        self.active_turns.remove(session_id);
                        self.push_history(session_id, outcome);
                        return Ok(());
                    }
                    Err(error) if error.message.contains("timed out") => {
                        // still in flight
                    }
                    Err(error) => return Err(error),
                }
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        Err(AdapterError::new(
            "timed out waiting for Agy session idle before next prompt",
        ))
    }
}

impl SessionAdapter for AgySessionAdapter {
    fn kind(&self) -> AdapterKind {
        AdapterKind::Agy
    }

    fn manifest(&self) -> AdapterManifest {
        AdapterManifest {
            id: "pharos.agy".to_string(),
            kind: AdapterKind::Agy,
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
        let cwd = request.workspace_path.clone();
        std::fs::create_dir_all(&cwd)
            .map_err(|error| AdapterError::new(format!("create workspace: {error}")))?;

        let params = json!({
            "cwd": cwd,
            "mcpServers": [],
        });

        let result = self.transport.request("session/new", params)?;
        let vendor_session_id = result
            .get("sessionId")
            .and_then(Value::as_str)
            .ok_or_else(|| AdapterError::new("session/new missing sessionId"))?
            .to_owned();

        // Hot-swap model via ACP config option. Shape is configId/value
        // (agy 1.5.5); the older `config: {model}` object is rejected.
        if let Some(model) = request
            .model
            .as_ref()
            .filter(|m| !m.is_empty() && *m != "default")
        {
            let _ = self.transport.request(
                "session/set_config_option",
                json!({
                    "sessionId": vendor_session_id,
                    "configId": "model",
                    "value": model,
                }),
            );
        }

        let session_id = vendor_session_id.clone();
        self.sessions
            .insert(session_id.clone(), vendor_session_id.clone());
        self.turn_history.entry(session_id.clone()).or_default();
        Ok(StartedSession {
            session_id,
            vendor_thread_id: vendor_session_id,
        })
    }

    fn send_prompt(
        &mut self,
        session_id: &str,
        prompt: &str,
        mode: PromptMode,
    ) -> Result<StartedTurn, AdapterError> {
        let vendor = self.vendor_session(session_id)?;
        match mode {
            PromptMode::Queue => {
                self.wait_until_idle(session_id, Duration::from_secs(45))?;
            }
            PromptMode::Steer => {
                // ACP allows mid-turn append via another session/prompt; if no
                // active turn, behave like Queue.
            }
        }
        let (request_id, turn_id) = self.transport.start_prompt(&vendor, prompt)?;
        self.active_turns.insert(
            session_id.to_owned(),
            ActiveTurn {
                request_id,
                turn_id: turn_id.clone(),
            },
        );
        Ok(StartedTurn {
            session_id: session_id.to_owned(),
            turn_id,
        })
    }

    fn interrupt(&mut self, session_id: &str) -> Result<InterruptOutcome, AdapterError> {
        let vendor = self.vendor_session(session_id)?;
        let Some(active) = self.active_turns.get(session_id).cloned() else {
            return Ok(InterruptOutcome {
                session_id: session_id.to_owned(),
                turn_id: None,
                turn_status: None,
            });
        };
        self.transport.cancel_session(&vendor)?;
        let outcome = self.wait_turn(session_id, &active.turn_id, Duration::from_secs(60))?;
        // Hard rule: the interrupt path must never surface Completed.
        // If cancel races a natural `end_turn`, remap to Failed (vendor already
        // finished; interrupt did not "succeed as completed").
        let turn_status = match outcome.status {
            TurnStatus::Completed => {
                return Err(AdapterError::new(format!(
                    "interrupt reported completed (protocol violation); raw={}",
                    outcome.raw_status
                )));
            }
            other => other,
        };
        Ok(InterruptOutcome {
            session_id: session_id.to_owned(),
            turn_id: Some(active.turn_id),
            turn_status: Some(turn_status),
        })
    }

    fn wait_turn(
        &mut self,
        session_id: &str,
        turn_id: &str,
        timeout: Duration,
    ) -> Result<TurnOutcome, AdapterError> {
        // Already finished and recorded?
        if let Some(history) = self.turn_history.get(session_id)
            && let Some(found) = history.iter().find(|t| t.turn_id == turn_id).cloned()
            && found.status.is_terminal()
        {
            return Ok(found);
        }

        let active =
            self.active_turns.get(session_id).cloned().ok_or_else(|| {
                AdapterError::new(format!("no active turn for session {session_id}"))
            })?;
        if active.turn_id != turn_id {
            return Err(AdapterError::new(format!(
                "turn mismatch: waiting for {turn_id}, active is {}",
                active.turn_id
            )));
        }

        let terminal = self.transport.wait_prompt(active.request_id, timeout)?;
        let status = TurnStatus::from_stop_reason(&terminal.stop_reason);
        let outcome = TurnOutcome {
            turn_id: turn_id.to_owned(),
            status,
            raw_status: terminal.stop_reason,
            assistant_text: terminal.assistant_text,
            vendor_error: terminal.error,
        };
        self.active_turns.remove(session_id);
        self.push_history(session_id, outcome.clone());
        let _ = self.transport.take_notifications();
        Ok(outcome)
    }

    fn read_turns(&mut self, session_id: &str) -> Result<Vec<TurnOutcome>, AdapterError> {
        let _ = self.vendor_session(session_id)?;
        Ok(self
            .turn_history
            .get(session_id)
            .cloned()
            .unwrap_or_default())
    }

    fn close(&mut self) {
        self.transport.close();
        self.sessions.clear();
        self.active_turns.clear();
        self.turn_history.clear();
    }
}

impl DeliveryWorker for AgySessionAdapter {
    fn dispatch(&mut self, job: DeliveryJob) -> Result<DeliveryDispatchResult, AdapterError> {
        if !self.sessions.contains_key(&job.session_id) {
            return Ok(DeliveryDispatchResult::failed(
                job.delivery_id,
                format!("unknown Agy session {}", job.session_id),
            ));
        }
        let prompt = format_delivery_prompt(&job.payload, &job.session_id);
        let started = match self.send_prompt(&job.session_id, &prompt, PromptMode::Queue) {
            Ok(started) => started,
            Err(error) => {
                return Ok(DeliveryDispatchResult::failed(
                    job.delivery_id,
                    format!("Agy session/prompt failed before dispatch: {error}"),
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
                        format!("Agy wait_turn failed: {error}"),
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
                        format!("Agy turn completed without assistant text; {detail}"),
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
                format!("Agy turn interrupted; {detail}"),
            )),
            TurnStatus::Failed => Ok(DeliveryDispatchResult::failed_turn(
                job.delivery_id,
                outcome.turn_id,
                format!("Agy turn failed; {detail}"),
            )),
            other => Ok(DeliveryDispatchResult::failed_turn(
                job.delivery_id,
                outcome.turn_id,
                format!("Agy turn ended in non-success status {other:?}; {detail}"),
            )),
        }
    }
}

impl Drop for AgySessionAdapter {
    fn drop(&mut self) {
        self.close();
    }
}

/// Convenience re-export path helper.
pub fn msg_test_root() -> PathBuf {
    crate::resolve::msg_test_root()
}

#[cfg(test)]
mod tests {
    use crate::session::TurnStatus;

    #[test]
    fn stop_reason_cancelled_is_interrupted_not_completed() {
        let status = TurnStatus::from_stop_reason("cancelled");
        assert_eq!(status, TurnStatus::Interrupted);
        assert_ne!(status, TurnStatus::Completed);
    }

    #[test]
    fn stop_reason_end_turn_is_completed() {
        assert_eq!(
            TurnStatus::from_stop_reason("end_turn"),
            TurnStatus::Completed
        );
    }
}
