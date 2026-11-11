//! **Fake** S1/S2 stand-ins for S4 acceptance (not live mesh/runtime).
//!
//! Every type and constructor is prefixed / documented as fake so evidence and
//! code review cannot mistake them for production adapters.

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use pharos_api::{
    CanonicalTurn, ClientEvent, HostInventorySnapshot, HostInventoryStatus, PharosApiError,
    ProjectSummary, ReplyThreadMessageRequest, ReplyThreadMessageResponse, ResolveApprovalRequest,
    SendSessionMessageRequest, SendThreadMessageRequest, SessionActivityStatus, SessionGoal,
    SessionProgress, SessionSummary, SessionTodo, SteerSessionRequest, ThreadMessage,
    ThreadSummary, TodoStatus, TurnStatus,
};
use pharos_hitl::{QuestionnaireAnswer, StoredDecision};
use pharos_protocol::ThreadReceiptState;
use tokio::sync::RwLock;

use super::session::{
    CreateSessionRequest, SessionCapabilities, SessionConfigPatch, SessionConfigView,
    SessionLifecycleResponse, standard_modes,
};
use super::thread::CreateThreadRequest;
use super::{EventBus, SessionService, ThreadService};

const FAKE_THREAD_ID: &str = "fake-thread-1";
const FAKE_SESSION_ID: &str = "fake-session-1";
const FAKE_PROJECT_PATH: &str = "/tmp/pharos-fake-project";

/// In-memory **fake** thread service for S4 HTTP/WS gates.
#[derive(Debug, Clone)]
pub struct FakeThreadService {
    inner: Arc<RwLock<FakeThreadState>>,
    events: EventBus,
}

#[derive(Debug, Default)]
struct FakeThreadState {
    threads: HashMap<String, ThreadSummary>,
    messages: HashMap<String, Vec<ThreadMessage>>,
    next_msg: u64,
}

impl FakeThreadService {
    /// Build a fake with one seed thread and one seed message.
    pub fn new(events: EventBus) -> Self {
        let mut threads = HashMap::new();
        threads.insert(
            FAKE_THREAD_ID.to_string(),
            ThreadSummary {
                thread_id: FAKE_THREAD_ID.to_string(),
                title: "Fake Thread (S4)".to_string(),
                member_ids: vec!["human".into(), "grokbot".into()],
                unread_count: 0,
                last_activity_at: "2026-11-10T00:00:00Z".into(),
            },
        );
        let mut messages = HashMap::new();
        messages.insert(
            FAKE_THREAD_ID.to_string(),
            vec![ThreadMessage {
                id: "fake-msg-1".into(),
                thread_id: FAKE_THREAD_ID.to_string(),
                sender_id: "human".into(),
                sender_name: "Human".into(),
                sender_avatar_seed: None,
                text: "hello from FakeThreadService".into(),
                timestamp: "2026-11-10T00:00:00Z".into(),
                receipt: ThreadReceiptState::Pending,
                target_member_ids: vec![],
                reply_to: None,
            }],
        );
        Self {
            inner: Arc::new(RwLock::new(FakeThreadState {
                threads,
                messages,
                next_msg: 2,
            })),
            events,
        }
    }
}

#[async_trait]
impl ThreadService for FakeThreadService {
    async fn list_threads(&self) -> Result<Vec<ThreadSummary>, PharosApiError> {
        let guard = self.inner.read().await;
        Ok(guard.threads.values().cloned().collect())
    }

    async fn get_thread(&self, thread_id: &str) -> Result<ThreadSummary, PharosApiError> {
        let guard = self.inner.read().await;
        guard
            .threads
            .get(thread_id)
            .cloned()
            .ok_or_else(|| PharosApiError::ThreadNotFound {
                id: thread_id.to_string(),
            })
    }

    async fn list_messages(&self, thread_id: &str) -> Result<Vec<ThreadMessage>, PharosApiError> {
        let guard = self.inner.read().await;
        if !guard.threads.contains_key(thread_id) {
            return Err(PharosApiError::ThreadNotFound {
                id: thread_id.to_string(),
            });
        }
        Ok(guard.messages.get(thread_id).cloned().unwrap_or_default())
    }

    async fn send_message(
        &self,
        thread_id: &str,
        request: SendThreadMessageRequest,
    ) -> Result<ThreadMessage, PharosApiError> {
        let mut guard = self.inner.write().await;
        if !guard.threads.contains_key(thread_id) {
            return Err(PharosApiError::ThreadNotFound {
                id: thread_id.to_string(),
            });
        }
        let id = format!("fake-msg-{}", guard.next_msg);
        guard.next_msg += 1;
        let msg = ThreadMessage {
            id: id.clone(),
            thread_id: thread_id.to_string(),
            sender_id: "human".into(),
            sender_name: "Human".into(),
            sender_avatar_seed: None,
            text: request.text,
            timestamp: "2026-11-10T00:00:01Z".into(),
            receipt: ThreadReceiptState::Pending,
            target_member_ids: request.target_member_ids,
            reply_to: None,
        };
        guard
            .messages
            .entry(thread_id.to_string())
            .or_default()
            .push(msg.clone());
        self.events.publish(ClientEvent::ThreadMessageReceived {
            thread_message: msg.clone(),
        });
        Ok(msg)
    }

    async fn reply(
        &self,
        thread_id: &str,
        request: ReplyThreadMessageRequest,
    ) -> Result<ReplyThreadMessageResponse, PharosApiError> {
        let mut guard = self.inner.write().await;
        if !guard.threads.contains_key(thread_id) {
            return Err(PharosApiError::ThreadNotFound {
                id: thread_id.to_string(),
            });
        }
        let reply_id = format!("fake-msg-{}", guard.next_msg);
        guard.next_msg += 1;
        let reply_to = request
            .message_id
            .clone()
            .unwrap_or_else(|| "fake-msg-1".into());
        let msg = ThreadMessage {
            id: reply_id.clone(),
            thread_id: thread_id.to_string(),
            sender_id: request.as_member.clone(),
            sender_name: request.as_member.clone(),
            sender_avatar_seed: None,
            text: request.text,
            timestamp: "2026-11-10T00:00:02Z".into(),
            receipt: ThreadReceiptState::Pending,
            target_member_ids: vec![],
            reply_to: None,
        };
        guard
            .messages
            .entry(thread_id.to_string())
            .or_default()
            .push(msg.clone());
        self.events.publish(ClientEvent::ThreadMessageReceived {
            thread_message: msg,
        });
        Ok(ReplyThreadMessageResponse {
            ok: true,
            thread: thread_id.to_string(),
            as_member: request.as_member,
            reply_id,
            reply_to,
        })
    }

    async fn create_thread(
        &self,
        request: CreateThreadRequest,
    ) -> Result<ThreadSummary, PharosApiError> {
        let thread_id = request.thread_id.trim();
        if thread_id.is_empty() {
            return Err(PharosApiError::InvalidRequest {
                message: "threadId must not be empty".into(),
            });
        }
        let mut guard = self.inner.write().await;
        if let Some(existing) = guard.threads.get(thread_id) {
            return Ok(existing.clone());
        }
        let summary = ThreadSummary {
            thread_id: thread_id.to_string(),
            title: thread_id.to_string(),
            member_ids: if request.member_ids.is_empty() {
                vec!["human".into(), "grokbot".into()]
            } else {
                request.member_ids
            },
            unread_count: 0,
            last_activity_at: "2026-11-10T00:00:00Z".into(),
        };
        guard.threads.insert(thread_id.to_string(), summary.clone());
        guard.messages.entry(thread_id.to_string()).or_default();
        Ok(summary)
    }
}

/// In-memory **fake** session / inventory / projects service for S4 gates.
#[derive(Debug, Clone)]
pub struct FakeSessionService {
    inner: Arc<RwLock<FakeSessionState>>,
    events: EventBus,
}

#[derive(Debug)]
struct FakeSessionState {
    sessions: HashMap<String, SessionSummary>,
    history: HashMap<String, Vec<CanonicalTurn>>,
    progress: HashMap<String, SessionProgress>,
    projects: Vec<ProjectSummary>,
    /// In-memory model/mode per session (fake adapter exposes both fields).
    configs: HashMap<String, FakeSessionConfig>,
    next_turn: u32,
}

#[derive(Debug, Clone)]
struct FakeSessionConfig {
    model: String,
    mode: String,
}

impl Default for FakeSessionConfig {
    fn default() -> Self {
        Self {
            model: "fake-1".to_string(),
            mode: "safe".to_string(),
        }
    }
}

impl FakeSessionService {
    /// Build a fake with one seed session, progress, and project.
    pub fn new(events: EventBus) -> Self {
        let mut sessions = HashMap::new();
        sessions.insert(
            FAKE_SESSION_ID.to_string(),
            SessionSummary {
                session_id: FAKE_SESSION_ID.to_string(),
                machine_id: "fake-host".into(),
                agent_type: "fake".into(),
                workspace_path: FAKE_PROJECT_PATH.into(),
                title: "Fake Session (S4)".into(),
                status: SessionActivityStatus::Idle,
                latest_message_preview: Some("seeded by FakeSessionService".into()),
                updated_at: "2026-11-10T00:00:00Z".into(),
                avatar_seed: "fake".into(),
                inventory_stale: Some(false),
                connection_route: Some("fake".into()),
            },
        );
        let mut history = HashMap::new();
        history.insert(FAKE_SESSION_ID.to_string(), vec![]);
        let mut progress = HashMap::new();
        progress.insert(
            FAKE_SESSION_ID.to_string(),
            SessionProgress {
                goal: Some(SessionGoal {
                    objective: "Exercise S4 HTTP mounts".into(),
                    status: "in_progress".into(),
                }),
                todos: vec![SessionTodo {
                    text: "Serve /health + OpenAPI + static UI".into(),
                    status: TodoStatus::InProgress,
                    priority: Some("high".into()),
                }],
            },
        );
        let projects = vec![ProjectSummary {
            project_id: Some("fake-project-1".into()),
            project_path: FAKE_PROJECT_PATH.into(),
            name: "Fake Project (S4)".into(),
            tracked_devices: vec!["fake-host".into()],
            active_sessions_count: 1,
            related_session_ids: Some(vec![FAKE_SESSION_ID.into()]),
        }];
        let mut configs = HashMap::new();
        configs.insert(FAKE_SESSION_ID.to_string(), FakeSessionConfig::default());
        Self {
            inner: Arc::new(RwLock::new(FakeSessionState {
                sessions,
                history,
                progress,
                projects,
                configs,
                next_turn: 1,
            })),
            events,
        }
    }
}

#[async_trait]
impl SessionService for FakeSessionService {
    async fn list_sessions(&self) -> Result<Vec<SessionSummary>, PharosApiError> {
        let guard = self.inner.read().await;
        Ok(guard.sessions.values().cloned().collect())
    }

    async fn get_session(&self, session_id: &str) -> Result<SessionSummary, PharosApiError> {
        let guard = self.inner.read().await;
        guard
            .sessions
            .get(session_id)
            .cloned()
            .ok_or_else(|| PharosApiError::SessionNotFound {
                id: session_id.to_string(),
            })
    }

    async fn list_history(&self, session_id: &str) -> Result<Vec<CanonicalTurn>, PharosApiError> {
        let guard = self.inner.read().await;
        if !guard.sessions.contains_key(session_id) {
            return Err(PharosApiError::SessionNotFound {
                id: session_id.to_string(),
            });
        }
        Ok(guard.history.get(session_id).cloned().unwrap_or_default())
    }

    async fn send_message(
        &self,
        session_id: &str,
        request: SendSessionMessageRequest,
    ) -> Result<CanonicalTurn, PharosApiError> {
        let mut guard = self.inner.write().await;
        if !guard.sessions.contains_key(session_id) {
            return Err(PharosApiError::SessionNotFound {
                id: session_id.to_string(),
            });
        }
        let turn_number = guard.next_turn;
        guard.next_turn += 1;
        {
            let session = guard.sessions.get_mut(session_id).expect("checked");
            session.status = SessionActivityStatus::Working;
            session.latest_message_preview = Some(request.text.clone());
            session.updated_at = "2026-11-10T00:00:03Z".into();
        }
        let turn = CanonicalTurn {
            turn_id: format!("fake-turn-{turn_number}"),
            session_id: session_id.to_string(),
            turn_number,
            status: TurnStatus::Completed,
            created_at: "2026-11-10T00:00:03Z".into(),
            completed_at: Some("2026-11-10T00:00:03Z".into()),
            assistant_text: vec![format!("fake echo: {}", request.text)],
        };
        guard
            .history
            .entry(session_id.to_string())
            .or_default()
            .push(turn.clone());
        let updated = guard.sessions.get(session_id).expect("checked").clone();
        self.events
            .publish(ClientEvent::SessionUpdated { session: updated });
        self.events
            .publish(ClientEvent::TurnCompleted { turn: turn.clone() });
        Ok(turn)
    }

    async fn steer(
        &self,
        session_id: &str,
        _request: SteerSessionRequest,
    ) -> Result<(), PharosApiError> {
        let guard = self.inner.read().await;
        if !guard.sessions.contains_key(session_id) {
            return Err(PharosApiError::SessionNotFound {
                id: session_id.to_string(),
            });
        }
        Ok(())
    }

    async fn resolve_approval(
        &self,
        session_id: &str,
        request: ResolveApprovalRequest,
    ) -> Result<(), PharosApiError> {
        let guard = self.inner.read().await;
        if !guard.sessions.contains_key(session_id) {
            return Err(PharosApiError::SessionNotFound {
                id: session_id.to_string(),
            });
        }
        self.events.publish(ClientEvent::ApprovalResolved {
            approval_id: request.approval_id,
            decision: request.decision,
        });
        Ok(())
    }

    async fn progress(&self, session_id: &str) -> Result<SessionProgress, PharosApiError> {
        let guard = self.inner.read().await;
        guard
            .progress
            .get(session_id)
            .cloned()
            .ok_or_else(|| PharosApiError::SessionNotFound {
                id: session_id.to_string(),
            })
    }

    async fn list_projects(&self) -> Result<Vec<ProjectSummary>, PharosApiError> {
        let guard = self.inner.read().await;
        Ok(guard.projects.clone())
    }

    async fn inventory(&self) -> Result<HostInventorySnapshot, PharosApiError> {
        let sessions = self.list_sessions().await?;
        Ok(HostInventorySnapshot {
            sessions,
            status: HostInventoryStatus {
                supported_agents: vec!["fake".into()],
                unavailable_agents: vec![],
            },
        })
    }

    async fn create_session(
        &self,
        request: CreateSessionRequest,
    ) -> Result<SessionSummary, PharosApiError> {
        if request.workspace_path.trim().is_empty() {
            return Err(PharosApiError::InvalidRequest {
                message: "workspacePath must not be empty".into(),
            });
        }
        let mut guard = self.inner.write().await;
        let session_id = format!("fake-session-{}", guard.sessions.len() + 1);
        let summary = SessionSummary {
            session_id: session_id.clone(),
            machine_id: "fake-host".into(),
            agent_type: "fake".into(),
            workspace_path: request.workspace_path,
            title: format!("Fake Session {}", guard.sessions.len() + 1),
            status: SessionActivityStatus::Idle,
            latest_message_preview: None,
            updated_at: "2026-11-10T00:00:00Z".into(),
            avatar_seed: "fake".into(),
            inventory_stale: Some(false),
            connection_route: Some("fake".into()),
        };
        guard.sessions.insert(session_id.clone(), summary.clone());
        guard.history.entry(session_id.clone()).or_default();
        guard.progress.insert(
            session_id.clone(),
            SessionProgress {
                goal: None,
                todos: Vec::new(),
            },
        );
        guard
            .configs
            .insert(session_id, FakeSessionConfig::default());
        Ok(summary)
    }

    async fn session_config(&self, session_id: &str) -> Result<SessionConfigView, PharosApiError> {
        let guard = self.inner.read().await;
        if !guard.sessions.contains_key(session_id) {
            return Err(PharosApiError::SessionNotFound {
                id: session_id.to_string(),
            });
        }
        Ok(fake_config_view(session_id, guard.configs.get(session_id)))
    }

    async fn update_session_config(
        &self,
        session_id: &str,
        patch: SessionConfigPatch,
    ) -> Result<SessionConfigView, PharosApiError> {
        patch
            .validate()
            .map_err(|message| PharosApiError::InvalidRequest { message })?;
        let mut guard = self.inner.write().await;
        if !guard.sessions.contains_key(session_id) {
            return Err(PharosApiError::SessionNotFound {
                id: session_id.to_string(),
            });
        }
        let config = guard.configs.entry(session_id.to_string()).or_default();
        if let Some(model) = &patch.model {
            config.model = model.trim().to_string();
        }
        if let Some(mode) = &patch.mode {
            config.mode = mode.trim().to_string();
        }
        let config = guard.configs.get(session_id).cloned();
        Ok(fake_config_view(session_id, config.as_ref()))
    }

    async fn stop_session(
        &self,
        session_id: &str,
    ) -> Result<SessionLifecycleResponse, PharosApiError> {
        self.set_status(session_id, SessionActivityStatus::Stopped)
            .await?;
        Ok(SessionLifecycleResponse {
            ok: true,
            session_id: session_id.to_string(),
            status: "stopped".to_string(),
        })
    }

    async fn revive_session(
        &self,
        session_id: &str,
    ) -> Result<SessionLifecycleResponse, PharosApiError> {
        self.set_status(session_id, SessionActivityStatus::Idle)
            .await?;
        Ok(SessionLifecycleResponse {
            ok: true,
            session_id: session_id.to_string(),
            status: "idle".to_string(),
        })
    }

    async fn send_message_with_attachments(
        &self,
        session_id: &str,
        request: SendSessionMessageRequest,
        attachment_ids: Vec<String>,
    ) -> Result<CanonicalTurn, PharosApiError> {
        if attachment_ids.iter().any(|id| id.trim().is_empty()) {
            return Err(PharosApiError::InvalidRequest {
                message: "attachmentIds must not contain blank ids".into(),
            });
        }
        // The fake adapter "accepts" attachments: they are validated by the
        // HTTP layer and acknowledged here (no fake success for real adapters).
        self.send_message(session_id, request).await
    }

    async fn resolve_approval_decision(
        &self,
        session_id: &str,
        approval_id: &str,
        decision: StoredDecision,
        _answers: Option<&[QuestionnaireAnswer]>,
    ) -> Result<(), PharosApiError> {
        {
            let guard = self.inner.read().await;
            if !guard.sessions.contains_key(session_id) {
                return Err(PharosApiError::SessionNotFound {
                    id: session_id.to_string(),
                });
            }
        }
        match decision.to_api() {
            Some(decision) => {
                self.resolve_approval(
                    session_id,
                    ResolveApprovalRequest {
                        approval_id: approval_id.to_string(),
                        decision,
                    },
                )
                .await
            }
            // `cancelled` means "stop the in-flight turn"; the fake adapter has
            // no live turn to cancel, so it is acknowledged without publishing a
            // (frozen-enum-incompatible) ApprovalResolved event.
            None => Ok(()),
        }
    }
}

/// Build the fake adapter's honest supported configuration view.
fn fake_config_view(session_id: &str, config: Option<&FakeSessionConfig>) -> SessionConfigView {
    let default = FakeSessionConfig::default();
    let config = config.unwrap_or(&default);
    SessionConfigView {
        session_id: session_id.to_string(),
        supported: true,
        supported_fields: vec!["model".to_string(), "mode".to_string()],
        model: Some(config.model.clone()),
        mode: Some(config.mode.clone()),
        models: vec![config.model.clone()],
        modes: standard_modes(),
        capabilities: SessionCapabilities {
            attachments: true,
            commands: false,
            stop: true,
            revive: true,
        },
        readonly: false,
    }
}

impl FakeSessionService {
    async fn set_status(
        &self,
        session_id: &str,
        status: SessionActivityStatus,
    ) -> Result<(), PharosApiError> {
        let mut guard = self.inner.write().await;
        let Some(session) = guard.sessions.get_mut(session_id) else {
            return Err(PharosApiError::SessionNotFound {
                id: session_id.to_string(),
            });
        };
        session.status = status;
        session.updated_at = "2026-11-10T00:00:04Z".into();
        let updated = session.clone();
        drop(guard);
        self.events
            .publish(ClientEvent::SessionUpdated { session: updated });
        Ok(())
    }
}

/// **Fake** event pump helper: publishes a deterministic burst of `ClientEvent`s
/// so the WS acceptance test can assert frames without real S1/S2 backends.
#[derive(Clone, Debug)]
pub struct FakeEventBus {
    bus: EventBus,
}

impl FakeEventBus {
    pub fn new(bus: EventBus) -> Self {
        Self { bus }
    }

    pub fn bus(&self) -> EventBus {
        self.bus.clone()
    }

    /// Push the canonical fake pump sequence used by S4 WS evidence.
    pub fn pump_demo_events(&self) {
        self.bus.publish(ClientEvent::MemberStatusChanged {
            member_name: "fake-member".into(),
            status: "online".into(),
        });
        self.bus.publish(ClientEvent::SessionConnectionRestored {
            session_id: FAKE_SESSION_ID.into(),
        });
        self.bus.publish(ClientEvent::ThreadMessageReceived {
            thread_message: ThreadMessage {
                id: "fake-ws-msg-1".into(),
                thread_id: FAKE_THREAD_ID.into(),
                sender_id: "fake-pump".into(),
                sender_name: "FakeEventBus".into(),
                sender_avatar_seed: None,
                text: "ws pump demo".into(),
                timestamp: "2026-11-10T00:00:10Z".into(),
                receipt: ThreadReceiptState::Pending,
                target_member_ids: vec![],
                reply_to: None,
            },
        });
    }
}

/// Seed ids exported for tests/evidence (all fake).
pub mod ids {
    pub const THREAD: &str = super::FAKE_THREAD_ID;
    pub const SESSION: &str = super::FAKE_SESSION_ID;
}

#[cfg(test)]
mod tests {
    use pharos_hitl::StoredDecision;

    use super::*;

    fn fake() -> FakeSessionService {
        FakeSessionService::new(EventBus::new(32))
    }

    #[tokio::test]
    async fn fake_config_is_supported_and_patchable() {
        let service = fake();
        let view = service.session_config(ids::SESSION).await.expect("config");
        assert!(view.supported);
        assert_eq!(view.supported_fields, vec!["model", "mode"]);
        assert_eq!(view.model.as_deref(), Some("fake-1"));
        assert_eq!(view.mode.as_deref(), Some("safe"));
        assert_eq!(view.models, vec!["fake-1"]);
        assert_eq!(view.modes.len(), 2);
        assert!(view.capabilities.attachments);
        assert!(!view.capabilities.commands);
        assert!(view.capabilities.stop);
        assert!(view.capabilities.revive);
        assert!(!view.readonly);

        let updated = service
            .update_session_config(
                ids::SESSION,
                SessionConfigPatch {
                    model: Some("fake-2".into()),
                    mode: Some("yolo".into()),
                },
            )
            .await
            .expect("update");
        assert_eq!(updated.model.as_deref(), Some("fake-2"));
        assert_eq!(updated.mode.as_deref(), Some("yolo"));
        // Persisted for the in-memory session.
        assert_eq!(
            service
                .session_config(ids::SESSION)
                .await
                .expect("config")
                .mode
                .as_deref(),
            Some("yolo")
        );
        // Invalid patch is a client error, never silently accepted.
        let error = service
            .update_session_config(
                ids::SESSION,
                SessionConfigPatch {
                    model: None,
                    mode: Some("turbo".into()),
                },
            )
            .await
            .expect_err("invalid mode");
        assert!(matches!(error, PharosApiError::InvalidRequest { .. }));
        assert!(matches!(
            service.session_config("missing").await.unwrap_err(),
            PharosApiError::SessionNotFound { .. }
        ));
        assert!(matches!(
            service
                .update_session_config(
                    "missing",
                    SessionConfigPatch {
                        model: Some("x".into()),
                        mode: None,
                    }
                )
                .await
                .unwrap_err(),
            PharosApiError::SessionNotFound { .. }
        ));
    }

    #[tokio::test]
    async fn fake_stop_and_revive_toggle_status_and_publish() {
        let events = EventBus::new(16);
        let mut subscriber = events.subscribe();
        let service = FakeSessionService::new(events);
        let stopped = service.stop_session(ids::SESSION).await.expect("stop");
        assert!(stopped.ok);
        assert_eq!(stopped.status, "stopped");
        assert_eq!(
            service
                .get_session(ids::SESSION)
                .await
                .expect("session")
                .status,
            SessionActivityStatus::Stopped
        );
        let revived = service.revive_session(ids::SESSION).await.expect("revive");
        assert_eq!(revived.status, "idle");
        assert_eq!(
            service
                .get_session(ids::SESSION)
                .await
                .expect("session")
                .status,
            SessionActivityStatus::Idle
        );
        let mut saw_updated = false;
        for _ in 0..2 {
            if let Ok(ClientEvent::SessionUpdated { .. }) = subscriber.recv().await {
                saw_updated = true;
            }
        }
        assert!(
            saw_updated,
            "lifecycle transitions must publish SessionUpdated"
        );
        assert!(matches!(
            service.stop_session("missing").await.unwrap_err(),
            PharosApiError::SessionNotFound { .. }
        ));
    }

    #[tokio::test]
    async fn fake_accepts_attachment_ids() {
        let service = fake();
        let turn = service
            .send_message_with_attachments(
                ids::SESSION,
                SendSessionMessageRequest {
                    text: "with attachment".into(),
                    request_id: None,
                },
                vec!["0123456789abcdef0123456789abcdef".into()],
            )
            .await
            .expect("send with attachments");
        assert_eq!(turn.session_id, ids::SESSION);
        let error = service
            .send_message_with_attachments(
                ids::SESSION,
                SendSessionMessageRequest {
                    text: "bad".into(),
                    request_id: None,
                },
                vec!["  ".into()],
            )
            .await
            .expect_err("blank attachment id");
        assert!(matches!(error, PharosApiError::InvalidRequest { .. }));
        assert!(matches!(
            service
                .send_message_with_attachments(
                    "missing",
                    SendSessionMessageRequest {
                        text: "x".into(),
                        request_id: None,
                    },
                    vec!["id".into()],
                )
                .await
                .unwrap_err(),
            PharosApiError::SessionNotFound { .. }
        ));
    }

    #[tokio::test]
    async fn fake_resolves_extended_decisions() {
        let service = fake();
        // `cancelled` is acknowledged without a frozen-enum event.
        service
            .resolve_approval_decision(ids::SESSION, "a-cancel", StoredDecision::Cancelled, None)
            .await
            .expect("cancel");
        // Legacy decisions keep the existing resolution path.
        service
            .resolve_approval_decision(ids::SESSION, "a-legacy", StoredDecision::AllowedOnce, None)
            .await
            .expect("legacy");
        assert!(matches!(
            service
                .resolve_approval_decision("missing", "a", StoredDecision::Cancelled, None)
                .await
                .unwrap_err(),
            PharosApiError::SessionNotFound { .. }
        ));
    }
}
