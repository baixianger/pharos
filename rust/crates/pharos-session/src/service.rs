//! Session service consuming `dyn SessionAdapter`.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use pharos_api::{
    CanonicalTurn, ResolveApprovalRequest, SendSessionMessageRequest, SessionActivityStatus,
    SessionProgress, SessionSummary, SteerSessionRequest, TurnStatus,
};
use pharos_codex_adapter::{
    PromptMode, SessionAdapter, StartSessionRequest, TurnStatus as AdapterTurnStatus,
};
use pharos_goals::GoalsStore;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::error::SessionError;
use crate::events::{
    EventSink, emit_progress, emit_session_updated, emit_turn_completed, emit_turn_started,
};

/// Sync SessionService surface (S4 wraps into async HTTP handlers).
pub trait SessionService: Send {
    fn list_sessions(&self) -> Result<Vec<SessionSummary>, SessionError>;
    fn get_session(&self, session_id: &str) -> Result<SessionSummary, SessionError>;
    fn list_history(&self, session_id: &str) -> Result<Vec<CanonicalTurn>, SessionError>;
    fn start_session(
        &self,
        workspace_path: &str,
        mode: Option<&str>,
    ) -> Result<SessionSummary, SessionError>;
    fn send_message(
        &self,
        session_id: &str,
        request: SendSessionMessageRequest,
    ) -> Result<CanonicalTurn, SessionError>;
    fn steer(&self, session_id: &str, request: SteerSessionRequest) -> Result<(), SessionError>;
    fn resolve_approval(
        &self,
        session_id: &str,
        request: ResolveApprovalRequest,
    ) -> Result<(), SessionError>;
    fn progress(&self, session_id: &str) -> Result<SessionProgress, SessionError>;
    fn set_progress(
        &self,
        session_id: &str,
        progress: &SessionProgress,
    ) -> Result<SessionProgress, SessionError>;
}

struct SessionRecord {
    summary: SessionSummary,
    #[allow(dead_code)]
    vendor_thread_id: String,
    turns: Vec<CanonicalTurn>,
}

/// Concrete service: `Mutex<Box<dyn SessionAdapter>>` + goals store + event sink.
pub struct AdapterSessionService {
    adapter: Mutex<Box<dyn SessionAdapter>>,
    sessions: Mutex<HashMap<String, SessionRecord>>,
    goals: Mutex<GoalsStore>,
    events: std::sync::Arc<dyn EventSink>,
    machine_id: String,
    agent_type: String,
}

impl AdapterSessionService {
    pub fn new(
        adapter: Box<dyn SessionAdapter>,
        goals: GoalsStore,
        events: std::sync::Arc<dyn EventSink>,
        machine_id: impl Into<String>,
        agent_type: impl Into<String>,
    ) -> Self {
        Self {
            adapter: Mutex::new(adapter),
            sessions: Mutex::new(HashMap::new()),
            goals: Mutex::new(goals),
            events,
            machine_id: machine_id.into(),
            agent_type: agent_type.into(),
        }
    }
}

impl SessionService for AdapterSessionService {
    fn list_sessions(&self) -> Result<Vec<SessionSummary>, SessionError> {
        let guard = self
            .sessions
            .lock()
            .map_err(|_| SessionError::new("sessions lock"))?;
        Ok(guard.values().map(|r| r.summary.clone()).collect())
    }

    fn get_session(&self, session_id: &str) -> Result<SessionSummary, SessionError> {
        let guard = self
            .sessions
            .lock()
            .map_err(|_| SessionError::new("sessions lock"))?;
        guard
            .get(session_id)
            .map(|r| r.summary.clone())
            .ok_or_else(|| SessionError::new(format!("session not found: {session_id}")))
    }

    fn list_history(&self, session_id: &str) -> Result<Vec<CanonicalTurn>, SessionError> {
        let guard = self
            .sessions
            .lock()
            .map_err(|_| SessionError::new("sessions lock"))?;
        guard
            .get(session_id)
            .map(|r| r.turns.clone())
            .ok_or_else(|| SessionError::new(format!("session not found: {session_id}")))
    }

    fn start_session(
        &self,
        workspace_path: &str,
        mode: Option<&str>,
    ) -> Result<SessionSummary, SessionError> {
        let mut adapter = self
            .adapter
            .lock()
            .map_err(|_| SessionError::new("adapter lock"))?;
        let started = adapter
            .start_session(StartSessionRequest {
                workspace_path: workspace_path.to_owned(),
                model: None,
                mode: mode.map(str::to_owned),
            })
            .map_err(|e| SessionError::Adapter(e.to_string()))?;
        let now = OffsetDateTime::now_utc()
            .format(&Rfc3339)
            .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());
        let summary = SessionSummary {
            session_id: started.session_id.clone(),
            machine_id: self.machine_id.clone(),
            agent_type: self.agent_type.clone(),
            workspace_path: workspace_path.to_owned(),
            title: format!("{} session", self.agent_type),
            status: SessionActivityStatus::Idle,
            latest_message_preview: None,
            updated_at: now,
            avatar_seed: started.session_id.clone(),
            inventory_stale: None,
            connection_route: Some("local".into()),
        };
        {
            let mut sessions = self
                .sessions
                .lock()
                .map_err(|_| SessionError::new("sessions lock"))?;
            sessions.insert(
                started.session_id.clone(),
                SessionRecord {
                    summary: summary.clone(),
                    vendor_thread_id: started.vendor_thread_id,
                    turns: Vec::new(),
                },
            );
        }
        emit_session_updated(self.events.as_ref(), summary.clone());
        Ok(summary)
    }

    fn send_message(
        &self,
        session_id: &str,
        request: SendSessionMessageRequest,
    ) -> Result<CanonicalTurn, SessionError> {
        let mut adapter = self
            .adapter
            .lock()
            .map_err(|_| SessionError::new("adapter lock"))?;
        let started = adapter
            .send_prompt(session_id, &request.text, PromptMode::Queue)
            .map_err(|e| SessionError::Adapter(e.to_string()))?;
        let now = OffsetDateTime::now_utc()
            .format(&Rfc3339)
            .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());
        let turn_number = {
            let sessions = self
                .sessions
                .lock()
                .map_err(|_| SessionError::new("sessions lock"))?;
            sessions
                .get(session_id)
                .map(|r| r.turns.len() as u32 + 1)
                .unwrap_or(1)
        };
        let mut turn = CanonicalTurn {
            turn_id: started.turn_id.clone(),
            session_id: session_id.to_owned(),
            turn_number,
            status: TurnStatus::InProgress,
            created_at: now.clone(),
            completed_at: None,
            assistant_text: vec![],
        };
        emit_turn_started(self.events.as_ref(), turn.clone());

        let outcome = adapter
            .wait_turn(session_id, &started.turn_id, Duration::from_secs(180))
            .map_err(|e| SessionError::Adapter(e.to_string()))?;
        turn.status = map_turn_status(outcome.status);
        // Hard rule: interrupt/failed never reported as Completed.
        if matches!(
            outcome.status,
            AdapterTurnStatus::Interrupted | AdapterTurnStatus::Failed
        ) && turn.status == TurnStatus::Completed
        {
            return Err(SessionError::new(
                "protocol violation: non-success turn mapped to Completed",
            ));
        }
        turn.completed_at = Some(
            OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .unwrap_or_else(|_| now.clone()),
        );
        if !outcome.assistant_text.trim().is_empty() {
            turn.assistant_text = vec![outcome.assistant_text];
        }
        {
            let mut sessions = self
                .sessions
                .lock()
                .map_err(|_| SessionError::new("sessions lock"))?;
            if let Some(rec) = sessions.get_mut(session_id) {
                rec.turns.push(turn.clone());
                rec.summary.status = match turn.status {
                    TurnStatus::InProgress | TurnStatus::NeedsHuman => {
                        SessionActivityStatus::Working
                    }
                    TurnStatus::Completed => SessionActivityStatus::Idle,
                    TurnStatus::Failed | TurnStatus::Cancelled => SessionActivityStatus::Stopped,
                };
                rec.summary.updated_at = turn.completed_at.clone().unwrap_or(now);
                if let Some(preview) = turn.assistant_text.first() {
                    rec.summary.latest_message_preview = Some(preview.clone());
                }
                emit_session_updated(self.events.as_ref(), rec.summary.clone());
            }
        }
        emit_turn_completed(self.events.as_ref(), turn.clone());
        Ok(turn)
    }

    fn steer(&self, session_id: &str, request: SteerSessionRequest) -> Result<(), SessionError> {
        let mut adapter = self
            .adapter
            .lock()
            .map_err(|_| SessionError::new("adapter lock"))?;
        adapter
            .send_prompt(session_id, &request.text, PromptMode::Steer)
            .map_err(|e| SessionError::Adapter(e.to_string()))?;
        Ok(())
    }

    fn resolve_approval(
        &self,
        _session_id: &str,
        _request: ResolveApprovalRequest,
    ) -> Result<(), SessionError> {
        // Live HITL resolve is owned by `pharos-hitl::CodexHitlClient` until
        // SessionAdapter gains defer-approval + resolve_approval methods.
        Err(SessionError::new(
            "resolve_approval via SessionAdapter not supported yet; use pharos-hitl CodexHitlClient",
        ))
    }

    fn progress(&self, session_id: &str) -> Result<SessionProgress, SessionError> {
        let goals = self
            .goals
            .lock()
            .map_err(|_| SessionError::new("goals lock"))?;
        Ok(goals.progress(session_id)?)
    }

    fn set_progress(
        &self,
        session_id: &str,
        progress: &SessionProgress,
    ) -> Result<SessionProgress, SessionError> {
        let goals = self
            .goals
            .lock()
            .map_err(|_| SessionError::new("goals lock"))?;
        if let Some(goal) = &progress.goal {
            goals.set_goal(session_id, &goal.objective, &goal.status)?;
        } else {
            goals.clear_goal(session_id)?;
        }
        goals.replace_todos(session_id, &progress.todos)?;
        let stored = goals.progress(session_id)?;
        drop(goals);
        emit_progress(self.events.as_ref(), session_id, &stored);
        Ok(stored)
    }
}

fn map_turn_status(status: AdapterTurnStatus) -> TurnStatus {
    match status {
        AdapterTurnStatus::InProgress => TurnStatus::InProgress,
        AdapterTurnStatus::Completed => TurnStatus::Completed,
        AdapterTurnStatus::Failed => TurnStatus::Failed,
        AdapterTurnStatus::Interrupted => TurnStatus::Cancelled,
        AdapterTurnStatus::Unknown => TurnStatus::Failed,
    }
}

/// Tiny fake adapter for unit tests (no live Codex).
#[cfg(test)]
pub mod testutil {
    use super::*;
    use pharos_api::AdapterManifest;
    use pharos_codex_adapter::{
        AdapterError, InterruptOutcome, StartedSession, StartedTurn, TurnOutcome,
    };
    use pharos_protocol::AdapterKind;

    pub struct FakeAdapter {
        pub session_id: String,
    }

    impl SessionAdapter for FakeAdapter {
        fn kind(&self) -> AdapterKind {
            AdapterKind::Codex
        }
        fn manifest(&self) -> AdapterManifest {
            AdapterManifest {
                id: "pharos.fake".into(),
                kind: AdapterKind::Codex,
                capabilities: vec!["session.list".into()],
            }
        }
        fn start_session(
            &mut self,
            _request: StartSessionRequest,
        ) -> Result<StartedSession, AdapterError> {
            Ok(StartedSession {
                session_id: self.session_id.clone(),
                vendor_thread_id: self.session_id.clone(),
            })
        }
        fn send_prompt(
            &mut self,
            session_id: &str,
            _prompt: &str,
            _mode: PromptMode,
        ) -> Result<StartedTurn, AdapterError> {
            Ok(StartedTurn {
                session_id: session_id.to_owned(),
                turn_id: "turn-fake-1".into(),
            })
        }
        fn interrupt(&mut self, session_id: &str) -> Result<InterruptOutcome, AdapterError> {
            Ok(InterruptOutcome {
                session_id: session_id.to_owned(),
                turn_id: Some("turn-fake-1".into()),
                turn_status: Some(AdapterTurnStatus::Interrupted),
            })
        }
        fn wait_turn(
            &mut self,
            _session_id: &str,
            turn_id: &str,
            _timeout: Duration,
        ) -> Result<TurnOutcome, AdapterError> {
            Ok(TurnOutcome {
                turn_id: turn_id.to_owned(),
                status: AdapterTurnStatus::Completed,
                raw_status: "completed".into(),
                assistant_text: "PHAROS_FAKE_OK".into(),
                vendor_error: None,
            })
        }
        fn read_turns(&mut self, _session_id: &str) -> Result<Vec<TurnOutcome>, AdapterError> {
            Ok(vec![])
        }
        fn close(&mut self) {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::RecordingEventSink;
    use pharos_api::{SessionGoal, SessionTodo, TodoStatus};
    use std::sync::Arc;
    use tempfile::tempdir;
    use testutil::FakeAdapter;

    #[test]
    fn consumes_dyn_session_adapter_and_emits_progress_events() {
        let dir = tempdir().unwrap();
        let goals = pharos_goals::open_goals_db(dir.path()).unwrap();
        let sink = Arc::new(RecordingEventSink::new());
        let service = AdapterSessionService::new(
            Box::new(FakeAdapter {
                session_id: "fake-sess-1".into(),
            }),
            goals,
            sink.clone(),
            "mac-air",
            "codex",
        );

        let summary = service
            .start_session("/tmp/pharos-fake-ws", Some("yolo"))
            .unwrap();
        assert_eq!(summary.session_id, "fake-sess-1");

        let turn = service
            .send_message(
                "fake-sess-1",
                SendSessionMessageRequest {
                    text: "hello".into(),
                    request_id: None,
                },
            )
            .unwrap();
        assert_eq!(turn.status, TurnStatus::Completed);
        assert_eq!(turn.assistant_text, vec!["PHAROS_FAKE_OK".to_string()]);

        let progress = service
            .set_progress(
                "fake-sess-1",
                &SessionProgress {
                    goal: Some(SessionGoal {
                        objective: "test".into(),
                        status: "active".into(),
                    }),
                    todos: vec![SessionTodo {
                        text: "one".into(),
                        status: TodoStatus::Pending,
                        priority: None,
                    }],
                },
            )
            .unwrap();
        assert_eq!(progress.todos.len(), 1);

        let events = sink.json_values();
        assert!(
            events.iter().any(|v| v["eventType"] == "sessionUpdated"),
            "expected sessionUpdated: {events:?}"
        );
        assert!(
            events.iter().any(|v| v["eventType"] == "turnCompleted"),
            "expected turnCompleted: {events:?}"
        );
        assert!(
            events
                .iter()
                .any(|v| v["eventType"] == "sessionGoalUpdated"),
            "expected sessionGoalUpdated: {events:?}"
        );
        assert!(
            events
                .iter()
                .any(|v| v["eventType"] == "sessionTodosUpdated"),
            "expected sessionTodosUpdated: {events:?}"
        );
    }
}
