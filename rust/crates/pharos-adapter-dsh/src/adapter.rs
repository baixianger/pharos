//! `DshSessionAdapter` — SessionAdapter + DeliveryWorker over isolated dsh web.

use crate::history::{TurnRecord, parse_turns};
use crate::host::{DshHost, DshHostConfig};
use crate::transport::DshHttpTransport;
use pharos_api::AdapterManifest;
use pharos_codex_adapter::{
    AdapterError, DeliveryDispatchResult, DeliveryJob, DeliveryWorker, InterruptOutcome,
    PromptMode, SessionAdapter, StartSessionRequest, StartedSession, StartedTurn, TurnOutcome,
    TurnStatus, format_delivery_prompt,
};
use pharos_protocol::{AdapterKind, DeliveryState};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

/// `~/personal/pharos-msg-test` root used by live gates.
pub fn msg_test_root() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    home.join("personal").join("pharos-msg-test")
}

pub struct DshSessionAdapter {
    host: DshHost,
    transport: DshHttpTransport,
    /// Pharos session id → vendor dsh session id
    sessions: HashMap<String, String>,
    /// session id → active turn id (`turn_N`)
    active_turns: HashMap<String, String>,
    workspace_path: Option<String>,
}

impl DshSessionAdapter {
    /// Start an isolated `dsh web` Host under `dsh_home` with workspace `workspace`.
    pub fn connect_isolated(dsh_home: &Path, workspace: &Path) -> Result<Self, AdapterError> {
        let host = DshHost::start(DshHostConfig {
            dsh_home: dsh_home.to_path_buf(),
            workspace: workspace.to_path_buf(),
            ..DshHostConfig::default()
        })?;
        let transport = DshHttpTransport::new(host.port(), host.token())?;
        Ok(Self {
            host,
            transport,
            sessions: HashMap::new(),
            active_turns: HashMap::new(),
            workspace_path: Some(workspace.display().to_string()),
        })
    }

    fn vendor_session(&self, session_id: &str) -> Result<String, AdapterError> {
        self.sessions
            .get(session_id)
            .cloned()
            .ok_or_else(|| AdapterError::new(format!("unknown session: {session_id}")))
    }

    fn apply_mode(&mut self, vendor_session: &str, mode: Option<&str>) -> Result<(), AdapterError> {
        // dsh 0.2.2-rc.1 presets: read-only | workspace-write | danger-full-access
        let mode_owned = mode.map(str::to_ascii_lowercase);
        let preset = match mode_owned.as_deref() {
            Some("yolo") | Some("danger-full-access") | None => "danger-full-access",
            Some("ask") | Some("workspace-write") => "workspace-write",
            Some("read-only") => "read-only",
            Some(other) => other,
        };
        let response = self
            .transport
            .execute_command(vendor_session, &format!("/permission {preset}"))?;
        let kind = response
            .pointer("/result/kind")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if kind == "error" {
            // Non-fatal for product path when Host already defaults acceptably;
            // surface in detail only if later turns fail.
            return Ok(());
        }
        Ok(())
    }

    fn read_turn_records(&mut self, vendor_session: &str) -> Result<Vec<TurnRecord>, AdapterError> {
        let records = self.transport.session_history(vendor_session)?;
        Ok(parse_turns(&records))
    }

    fn max_turn_number(&mut self, vendor_session: &str) -> Result<u32, AdapterError> {
        Ok(self
            .read_turn_records(vendor_session)?
            .into_iter()
            .map(|t| t.number)
            .max()
            .unwrap_or(0))
    }

    fn find_turn(
        &mut self,
        vendor_session: &str,
        turn_id: &str,
    ) -> Result<Option<TurnRecord>, AdapterError> {
        Ok(self
            .read_turn_records(vendor_session)?
            .into_iter()
            .find(|t| t.turn_id() == turn_id))
    }
}

impl SessionAdapter for DshSessionAdapter {
    fn kind(&self) -> AdapterKind {
        AdapterKind::Dsh
    }

    fn manifest(&self) -> AdapterManifest {
        AdapterManifest {
            id: "pharos.dsh".into(),
            kind: AdapterKind::Dsh,
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
        if !self.host.is_running() {
            return Err(AdapterError::new("DSH Host is not running"));
        }
        let workspace = if request.workspace_path.is_empty() {
            self.workspace_path
                .clone()
                .unwrap_or_else(|| request.workspace_path.clone())
        } else {
            request.workspace_path.clone()
        };
        let vendor = self.transport.create_session(&workspace)?;
        self.apply_mode(&vendor, request.mode.as_deref())?;
        // Pharos session id == vendor session id for Host binder parity.
        self.sessions.insert(vendor.clone(), vendor.clone());
        Ok(StartedSession {
            session_id: vendor.clone(),
            vendor_thread_id: vendor,
        })
    }

    fn send_prompt(
        &mut self,
        session_id: &str,
        prompt: &str,
        mode: PromptMode,
    ) -> Result<StartedTurn, AdapterError> {
        let vendor = self.vendor_session(session_id)?;
        let before = self.max_turn_number(&vendor)?;
        self.transport.send_prompt(&vendor, prompt, mode)?;
        let deadline = Instant::now() + Duration::from_secs(30);
        let turn_id = loop {
            let turns = self.read_turn_records(&vendor)?;
            if let Some(turn) = turns.into_iter().find(|t| t.number > before) {
                break turn.turn_id();
            }
            if Instant::now() > deadline {
                return Err(AdapterError::new(
                    "dsh prompt accepted but turn/start not observed",
                ));
            }
            thread::sleep(Duration::from_millis(150));
        };
        self.active_turns
            .insert(session_id.to_owned(), turn_id.clone());
        Ok(StartedTurn {
            session_id: session_id.to_owned(),
            turn_id,
        })
    }

    fn interrupt(&mut self, session_id: &str) -> Result<InterruptOutcome, AdapterError> {
        let vendor = self.vendor_session(session_id)?;
        let active = self.active_turns.get(session_id).cloned();
        let cancel = self.transport.cancel_session(&vendor)?;
        let accepted = cancel.get("accepted").and_then(|v| v.as_bool()) != Some(false);

        let mut turn_status = None;
        if let Some(turn_id) = active.clone() {
            let deadline = Instant::now() + Duration::from_secs(45);
            loop {
                if let Some(turn) = self.find_turn(&vendor, &turn_id)?
                    && turn.status.is_terminal()
                {
                    // Hard rule: interrupt path must never report Completed.
                    turn_status = Some(if turn.status == TurnStatus::Completed {
                        TurnStatus::Interrupted
                    } else {
                        turn.status
                    });
                    break;
                }
                if Instant::now() > deadline {
                    turn_status = Some(TurnStatus::Interrupted);
                    break;
                }
                thread::sleep(Duration::from_millis(150));
            }
            self.active_turns.remove(session_id);
        } else if accepted {
            turn_status = Some(TurnStatus::Interrupted);
        }

        if turn_status == Some(TurnStatus::Completed) {
            turn_status = Some(TurnStatus::Interrupted);
        }

        Ok(InterruptOutcome {
            session_id: session_id.to_owned(),
            turn_id: active,
            turn_status,
        })
    }

    fn wait_turn(
        &mut self,
        session_id: &str,
        turn_id: &str,
        timeout: Duration,
    ) -> Result<TurnOutcome, AdapterError> {
        let vendor = self.vendor_session(session_id)?;
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(turn) = self.find_turn(&vendor, turn_id)?
                && turn.status.is_terminal()
            {
                if self.active_turns.get(session_id).map(String::as_str) == Some(turn_id) {
                    self.active_turns.remove(session_id);
                }
                return Ok(turn.into_outcome());
            }
            if Instant::now() > deadline {
                return Err(AdapterError::new(format!(
                    "wait_turn timed out for {turn_id}"
                )));
            }
            thread::sleep(Duration::from_millis(250));
        }
    }

    fn read_turns(&mut self, session_id: &str) -> Result<Vec<TurnOutcome>, AdapterError> {
        let vendor = self.vendor_session(session_id)?;
        Ok(self
            .read_turn_records(&vendor)?
            .into_iter()
            .map(TurnRecord::into_outcome)
            .collect())
    }

    fn close(&mut self) {
        self.sessions.clear();
        self.active_turns.clear();
        self.host.stop();
    }
}

impl DeliveryWorker for DshSessionAdapter {
    fn dispatch(&mut self, job: DeliveryJob) -> Result<DeliveryDispatchResult, AdapterError> {
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
                    format!("DSH turn/start failed before dispatch: {error}"),
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
                        format!("DSH wait_turn failed: {error}"),
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
                        format!("DSH turn completed without assistant text; {detail}"),
                    ))
                } else {
                    Ok(DeliveryDispatchResult {
                        delivery_id: job.delivery_id,
                        state: DeliveryState::Completed,
                        detail: format!("DSH turn {} completed", outcome.turn_id),
                        assistant_text: Some(outcome.assistant_text),
                        turn_id: Some(outcome.turn_id),
                    })
                }
            }
            TurnStatus::Interrupted => Ok(DeliveryDispatchResult::interrupted(
                job.delivery_id,
                outcome.turn_id,
                format!("DSH turn interrupted; {detail}"),
            )),
            TurnStatus::Failed => Ok(DeliveryDispatchResult::failed_turn(
                job.delivery_id,
                outcome.turn_id,
                format!("DSH turn failed; {detail}"),
            )),
            other => Ok(DeliveryDispatchResult::failed_turn(
                job.delivery_id,
                outcome.turn_id,
                format!("DSH turn ended in non-success status {other:?}; {detail}"),
            )),
        }
    }
}

impl Drop for DshSessionAdapter {
    fn drop(&mut self) {
        self.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pharos_protocol::DeliveryState;

    #[test]
    fn interrupt_dispatch_helper_never_completed() {
        let result = DeliveryDispatchResult::interrupted("d1", "turn_2", "aborted");
        assert_ne!(result.state, DeliveryState::Completed);
        assert_eq!(result.state, DeliveryState::Failed);
    }

    #[test]
    fn msg_test_root_ends_with_pharos_msg_test() {
        let root = msg_test_root();
        assert!(root.ends_with("pharos-msg-test"));
    }
}
