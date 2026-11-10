//! Cursor `agent` CLI [`SessionAdapter`] + [`DeliveryWorker`].

use crate::cli::{
    ActiveCliTurn, CliTurnResult, SpawnPromptOpts, agent_version, create_chat, spawn_prompt,
};
use crate::resolve::{home_dir, resolve_agent_executable};
use pharos_api::AdapterManifest;
use pharos_codex_adapter::{
    AdapterError, DeliveryDispatchResult, DeliveryJob, DeliveryWorker, InterruptOutcome,
    PromptMode, SessionAdapter, StartSessionRequest, StartedSession, StartedTurn, TurnOutcome,
    TurnStatus, format_delivery_prompt,
};
use pharos_protocol::AdapterKind;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

struct SessionState {
    chat_id: String,
    workspace: PathBuf,
    model: Option<String>,
    yolo: bool,
    /// Completed / observed turns for local `read_turns` (no vendor inventory API).
    turns: Vec<TurnOutcome>,
    active: Option<ActiveCliTurn>,
}

/// Headless Cursor CLI session + delivery adapter (S5d).
pub struct CursorSessionAdapter {
    executable: PathBuf,
    sessions: HashMap<String, SessionState>,
}

impl CursorSessionAdapter {
    pub fn connect() -> Result<Self, AdapterError> {
        let executable = resolve_agent_executable().map_err(AdapterError::new)?;
        Self::connect_executable(&executable)
    }

    pub fn connect_executable(executable: &Path) -> Result<Self, AdapterError> {
        Ok(Self {
            executable: executable.to_path_buf(),
            sessions: HashMap::new(),
        })
    }

    pub fn agent_version(&self) -> String {
        agent_version(&self.executable)
    }

    pub fn executable(&self) -> &Path {
        &self.executable
    }

    fn session_mut(&mut self, session_id: &str) -> Result<&mut SessionState, AdapterError> {
        self.sessions
            .get_mut(session_id)
            .ok_or_else(|| AdapterError::new(format!("unknown session: {session_id}")))
    }

    fn take_active(&mut self, session_id: &str) -> Result<ActiveCliTurn, AdapterError> {
        let session = self.session_mut(session_id)?;
        session
            .active
            .take()
            .ok_or_else(|| AdapterError::new(format!("no active turn for session {session_id}")))
    }

    fn record_outcome(&mut self, session_id: &str, outcome: TurnOutcome) {
        if let Some(session) = self.sessions.get_mut(session_id) {
            if let Some(existing) = session
                .turns
                .iter_mut()
                .find(|turn| turn.turn_id == outcome.turn_id)
            {
                *existing = outcome;
            } else {
                session.turns.push(outcome);
            }
        }
    }
}

impl SessionAdapter for CursorSessionAdapter {
    fn kind(&self) -> AdapterKind {
        AdapterKind::Cursor
    }

    fn manifest(&self) -> AdapterManifest {
        AdapterManifest {
            id: "pharos.cursor".to_string(),
            kind: AdapterKind::Cursor,
            capabilities: vec![
                "message.send".into(),
                "session.resume".into(),
                "session.continue".into(),
                "turn.interrupt".into(),
                // Explicitly NOT advertised (Ink TTY / no public API):
                // session.list, hitl, goal, todo, acp, mid-turn steer
            ],
        }
    }

    fn start_session(
        &mut self,
        request: StartSessionRequest,
    ) -> Result<StartedSession, AdapterError> {
        let workspace = PathBuf::from(&request.workspace_path);
        std::fs::create_dir_all(&workspace).map_err(|error| {
            AdapterError::new(format!("create workspace {}: {error}", workspace.display()))
        })?;
        let chat_id = create_chat(&self.executable, &workspace)?;
        let session_id = chat_id.clone();
        let yolo = request
            .mode
            .as_deref()
            .is_some_and(|mode| mode.eq_ignore_ascii_case("yolo"));
        self.sessions.insert(
            session_id.clone(),
            SessionState {
                chat_id: chat_id.clone(),
                workspace,
                model: request.model.filter(|m| !m.is_empty() && m != "default"),
                yolo,
                turns: Vec::new(),
                active: None,
            },
        );
        Ok(StartedSession {
            session_id,
            vendor_thread_id: chat_id,
        })
    }

    fn send_prompt(
        &mut self,
        session_id: &str,
        prompt: &str,
        mode: PromptMode,
    ) -> Result<StartedTurn, AdapterError> {
        if mode == PromptMode::Steer {
            return Err(AdapterError::new(
                "unsupported: Cursor CLI has no mid-turn steer (no ACP / turn/steer); use Queue + --resume",
            ));
        }
        let turn_id = uuid::Uuid::new_v4().to_string();
        let (workspace, chat_id, model, yolo) = {
            let session = self.session_mut(session_id)?;
            if session.active.is_some() {
                return Err(AdapterError::new(format!(
                    "session {session_id} already has an active turn; wait or interrupt first"
                )));
            }
            (
                session.workspace.clone(),
                session.chat_id.clone(),
                session.model.clone(),
                session.yolo,
            )
        };
        let active = spawn_prompt(SpawnPromptOpts {
            executable: &self.executable,
            workspace: &workspace,
            chat_id: &chat_id,
            prompt,
            model: model.as_deref(),
            yolo,
            turn_id: turn_id.clone(),
            stream_json: true,
            // Product gate uses ask (read-only). Delivery may need tools — use
            // yolo/force when session mode is yolo; still ask when not forcing writes.
            ask_mode: !yolo,
        })?;
        self.session_mut(session_id)?.active = Some(active);
        Ok(StartedTurn {
            session_id: session_id.to_owned(),
            turn_id,
        })
    }

    fn interrupt(&mut self, session_id: &str) -> Result<InterruptOutcome, AdapterError> {
        let Some(active) = self
            .sessions
            .get_mut(session_id)
            .and_then(|session| session.active.take())
        else {
            return Ok(InterruptOutcome {
                session_id: session_id.to_owned(),
                turn_id: None,
                turn_status: None,
            });
        };
        let turn_id = active.turn_id.clone();
        let result = active.interrupt()?;
        // Hard rule: interrupt must never report Completed.
        if result.outcome.status == TurnStatus::Completed {
            return Err(AdapterError::new(
                "interrupt reported completed (protocol violation for Cursor CLI adapter)",
            ));
        }
        let turn_status = Some(result.outcome.status);
        self.record_outcome(session_id, result.outcome);
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
        // Fast path: already recorded (e.g. after interrupt).
        if let Some(session) = self.sessions.get(session_id)
            && let Some(found) = session
                .turns
                .iter()
                .find(|turn| turn.turn_id == turn_id && turn.status.is_terminal())
        {
            return Ok(found.clone());
        }

        let active = self.take_active(session_id)?;
        if active.turn_id != turn_id {
            // Put it back — wrong id.
            let unexpected = active.turn_id.clone();
            self.session_mut(session_id)?.active = Some(active);
            return Err(AdapterError::new(format!(
                "active turn {unexpected} does not match requested {turn_id}"
            )));
        }
        let result: CliTurnResult = active.wait(timeout)?;
        let outcome = result.outcome;
        self.record_outcome(session_id, outcome.clone());
        Ok(outcome)
    }

    fn read_turns(&mut self, session_id: &str) -> Result<Vec<TurnOutcome>, AdapterError> {
        // Honest: Cursor has no non-interactive turn inventory (`agent ls` needs TTY).
        // Return only turns observed through this adapter instance.
        let session = self.session_mut(session_id)?;
        Ok(session.turns.clone())
    }

    fn close(&mut self) {
        let session_ids: Vec<String> = self.sessions.keys().cloned().collect();
        for session_id in session_ids {
            if let Some(active) = self
                .sessions
                .get_mut(&session_id)
                .and_then(|session| session.active.take())
            {
                let _ = active.interrupt();
            }
        }
        self.sessions.clear();
    }
}

impl DeliveryWorker for CursorSessionAdapter {
    fn dispatch(&mut self, job: DeliveryJob) -> Result<DeliveryDispatchResult, AdapterError> {
        if !self.sessions.contains_key(&job.session_id) {
            return Ok(DeliveryDispatchResult::failed(
                job.delivery_id,
                format!(
                    "unsupported/unknown Cursor session {}; start_session before delivery",
                    job.session_id
                ),
            ));
        }
        let prompt = format_delivery_prompt(&job.payload, &job.session_id);
        let started = match self.send_prompt(&job.session_id, &prompt, PromptMode::Queue) {
            Ok(started) => started,
            Err(error) => {
                return Ok(DeliveryDispatchResult::failed(
                    job.delivery_id,
                    format!("Cursor send_prompt failed before dispatch: {error}"),
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
                        format!("Cursor wait_turn failed: {error}"),
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
                        format!("Cursor turn completed without assistant text; {detail}"),
                    ))
                } else {
                    // Rephrase Codex-oriented detail string for Cursor.
                    Ok(DeliveryDispatchResult {
                        delivery_id: job.delivery_id,
                        state: pharos_protocol::DeliveryState::Completed,
                        detail: format!("Cursor turn {} completed", outcome.turn_id),
                        assistant_text: Some(outcome.assistant_text),
                        turn_id: Some(outcome.turn_id),
                    })
                }
            }
            TurnStatus::Interrupted => Ok(DeliveryDispatchResult::interrupted(
                job.delivery_id,
                outcome.turn_id,
                format!("Cursor turn interrupted; {detail}"),
            )),
            TurnStatus::Failed => Ok(DeliveryDispatchResult::failed_turn(
                job.delivery_id,
                outcome.turn_id,
                format!("Cursor turn failed; {detail}"),
            )),
            other => Ok(DeliveryDispatchResult::failed_turn(
                job.delivery_id,
                outcome.turn_id,
                format!("Cursor turn ended in non-success status {other:?}; {detail}"),
            )),
        }
    }
}

impl Drop for CursorSessionAdapter {
    fn drop(&mut self) {
        self.close();
    }
}

/// Convenience: msg-test data directory root for live evidence.
pub fn msg_test_root() -> PathBuf {
    home_dir().join("personal/pharos-msg-test")
}

/// Explicit unsupported helper used by inventory-style callers.
pub fn unsupported_list_chats() -> AdapterError {
    AdapterError::new(
        "unsupported: Cursor `agent ls` requires an interactive TTY (Ink raw mode); non-interactive inventory is unsupported",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use pharos_protocol::DeliveryState;

    #[test]
    fn manifest_is_cursor() {
        let adapter = CursorSessionAdapter {
            executable: PathBuf::from("/dev/null"),
            sessions: HashMap::new(),
        };
        assert_eq!(adapter.kind(), AdapterKind::Cursor);
        assert_eq!(adapter.manifest().kind, AdapterKind::Cursor);
        assert!(
            !adapter
                .manifest()
                .capabilities
                .iter()
                .any(|cap| cap == "session.list")
        );
    }

    #[test]
    fn list_chats_is_explicit_unsupported() {
        let error = unsupported_list_chats();
        assert!(error.message.contains("unsupported"));
        assert!(error.message.contains("TTY"));
    }

    #[test]
    fn interrupt_delivery_helper_never_completed() {
        let result = DeliveryDispatchResult::interrupted("d1", "t1", "cursor interrupted");
        assert_ne!(result.state, DeliveryState::Completed);
        assert_eq!(result.state, DeliveryState::Failed);
    }
}
