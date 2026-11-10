//! ClientEvent helpers matching `pharos-api` DTO wire shapes (S4 WS-bridgeable).

use std::sync::{Arc, Mutex};

use pharos_api::{
    ApprovalDecision, ApprovalRequest, CanonicalTurn, ClientEvent, SessionProgress, SessionSummary,
};

pub trait EventSink: Send + Sync {
    fn emit(&self, event: ClientEvent);
}

/// Test / in-process sink that records events for JSON snapshot asserts.
#[derive(Clone, Default)]
pub struct RecordingEventSink {
    events: Arc<Mutex<Vec<ClientEvent>>>,
}

impl RecordingEventSink {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn events(&self) -> Vec<ClientEvent> {
        self.events.lock().map(|g| g.clone()).unwrap_or_default()
    }

    pub fn json_values(&self) -> Vec<serde_json::Value> {
        self.events()
            .into_iter()
            .filter_map(|e| serde_json::to_value(e).ok())
            .collect()
    }
}

impl EventSink for RecordingEventSink {
    fn emit(&self, event: ClientEvent) {
        if let Ok(mut g) = self.events.lock() {
            g.push(event);
        }
    }
}

pub fn emit_progress(sink: &dyn EventSink, session_id: &str, progress: &SessionProgress) {
    sink.emit(ClientEvent::SessionGoalUpdated {
        session_id: session_id.to_owned(),
        goal: progress.goal.clone(),
    });
    sink.emit(ClientEvent::SessionTodosUpdated {
        session_id: session_id.to_owned(),
        todos: progress.todos.clone(),
    });
}

pub fn emit_approval_required(sink: &dyn EventSink, approval: ApprovalRequest) {
    sink.emit(ClientEvent::ApprovalRequired { approval });
}

pub fn emit_approval_resolved(sink: &dyn EventSink, approval_id: &str, decision: ApprovalDecision) {
    sink.emit(ClientEvent::ApprovalResolved {
        approval_id: approval_id.to_owned(),
        decision,
    });
}

pub fn emit_session_updated(sink: &dyn EventSink, session: SessionSummary) {
    sink.emit(ClientEvent::SessionUpdated { session });
}

pub fn emit_turn_started(sink: &dyn EventSink, turn: CanonicalTurn) {
    sink.emit(ClientEvent::TurnStarted { turn });
}

pub fn emit_turn_completed(sink: &dyn EventSink, turn: CanonicalTurn) {
    sink.emit(ClientEvent::TurnCompleted { turn });
}

/// Stable helpers for snapshot tests (fixed timestamps / ids).
#[cfg(test)]
mod tests {
    use super::*;
    use pharos_api::{ApprovalKind, SessionGoal, SessionTodo, TodoStatus};

    fn sample_progress_events(session_id: &str) -> Vec<ClientEvent> {
        let goal = Some(SessionGoal {
            objective: "Land S2 session-hitl".into(),
            status: "in_progress".into(),
        });
        let todos = vec![
            SessionTodo {
                text: "HITL unit".into(),
                status: TodoStatus::Completed,
                priority: Some("high".into()),
            },
            SessionTodo {
                text: "Codex live".into(),
                status: TodoStatus::InProgress,
                priority: None,
            },
        ];
        vec![
            ClientEvent::SessionGoalUpdated {
                session_id: session_id.to_owned(),
                goal: goal.clone(),
            },
            ClientEvent::SessionTodosUpdated {
                session_id: session_id.to_owned(),
                todos,
            },
        ]
    }

    fn sample_approval_events(session_id: &str, approval_id: &str) -> Vec<ClientEvent> {
        let approval = ApprovalRequest {
            approval_id: approval_id.to_owned(),
            session_id: session_id.to_owned(),
            kind: ApprovalKind::ToolPermission {
                tool_name: "commandExecution".into(),
                params: serde_json::json!({
                    "command": "printf PHAROS_RUST_HITL_OK",
                    "cwd": "/Users/baixianger/personal/pharos-msg-test/peer-hitl/work"
                }),
                explanation: Some("Harmless HITL probe".into()),
            },
            available_choices: Some(vec![
                "rejected".into(),
                "allowedOnce".into(),
                "allowedAlways".into(),
            ]),
        };
        vec![
            ClientEvent::ApprovalRequired {
                approval: approval.clone(),
            },
            ClientEvent::ApprovalUpdated { approval },
            ClientEvent::ApprovalResolved {
                approval_id: approval_id.to_owned(),
                decision: ApprovalDecision::AllowedOnce,
            },
        ]
    }

    #[test]
    fn progress_and_approval_event_json_shapes() {
        let progress = sample_progress_events("sess-snap-1");
        let approvals = sample_approval_events("sess-snap-1", "appr-snap-1");
        let all: Vec<_> = progress.into_iter().chain(approvals).collect();
        let values: Vec<_> = all
            .iter()
            .map(|e| serde_json::to_value(e).expect("serialize"))
            .collect();

        assert_eq!(values[0]["eventType"], "sessionGoalUpdated");
        assert_eq!(values[0]["sessionId"], "sess-snap-1");
        assert_eq!(values[0]["goal"]["objective"], "Land S2 session-hitl");
        assert!(values[0].get("secret").is_none());

        assert_eq!(values[1]["eventType"], "sessionTodosUpdated");
        assert_eq!(values[1]["todos"][0]["status"], "completed");
        assert_eq!(values[1]["todos"][1]["status"], "inProgress");

        assert_eq!(values[2]["eventType"], "approvalRequired");
        assert_eq!(values[2]["approval"]["approvalId"], "appr-snap-1");
        assert_eq!(values[2]["approval"]["kind"]["type"], "toolPermission");
        assert_eq!(
            values[2]["approval"]["kind"]["toolName"],
            "commandExecution"
        );

        assert_eq!(values[3]["eventType"], "approvalUpdated");
        assert_eq!(values[4]["eventType"], "approvalResolved");
        assert_eq!(values[4]["decision"], "allowedOnce");

        let pretty = serde_json::to_string_pretty(&values).unwrap();
        assert!(pretty.contains("\"eventType\": \"sessionGoalUpdated\""));
        assert!(pretty.contains("\"eventType\": \"approvalRequired\""));
        assert!(pretty.contains("\"eventType\": \"approvalResolved\""));
    }
}
