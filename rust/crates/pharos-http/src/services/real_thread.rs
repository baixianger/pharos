//! Real S1-backed Thread service for `pharos-web`.
//!
//! Durable SQLite storage lives in `pharos-thread` (PHASE0 `rooms` /
//! `memberships` / `messages` tables). This adapter only:
//!
//! - translates [`pharos_thread::ThreadError`] → [`PharosApiError`],
//! - applies the server's sender identity (HTTP has no per-user identity yet),
//! - normalizes the store's numeric epoch timestamps to RFC3339 for the API
//!   (the browser `Date` parser rejects `"1794411586.349847555"`),
//! - publishes `threadMessageReceived` frames to the WS [`EventBus`].

use std::sync::Arc;

use async_trait::async_trait;
use pharos_api::{
    ClientEvent, PharosApiError, ReplyThreadMessageRequest, ReplyThreadMessageResponse,
    SendThreadMessageRequest, ThreadMessage, ThreadSummary,
};
use pharos_protocol::grokbot;
use pharos_thread::{SenderIdentity, SqliteThreadStore, ThreadError};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
// Trait needed for the inherent store methods; aliased to avoid clashing with
// the S4 HTTP `ThreadService` trait implemented below.
use pharos_thread::ThreadService as CoreThreadService;

use super::{EventBus, ThreadService};
use crate::services::thread::CreateThreadRequest;

/// Default sender used for HTTP-originated Thread messages until the API
/// carries a member identity.
pub const DEFAULT_SENDER_ID: &str = "human";
/// Nick used for [`DEFAULT_SENDER_ID`].
pub const DEFAULT_SENDER_NICK: &str = "Human";
/// Maximum messages returned by `GET /api/v1/threads/{id}/messages`.
pub const MESSAGE_LIMIT: u32 = 200;
/// Upper bound for a Thread id / room name.
const MAX_THREAD_ID_LEN: usize = 120;

/// Thread service backed by the durable [`SqliteThreadStore`].
pub struct RealThreadService {
    store: Arc<SqliteThreadStore>,
    events: EventBus,
    sender: SenderIdentity,
}

impl RealThreadService {
    /// Build with the default HTTP sender identity (`human` / `Human`).
    pub fn new(store: Arc<SqliteThreadStore>, events: EventBus) -> Self {
        Self::with_sender(
            store,
            events,
            SenderIdentity {
                member_id: DEFAULT_SENDER_ID.to_string(),
                nick: DEFAULT_SENDER_NICK.to_string(),
            },
        )
    }

    /// Build with an explicit sender identity (tests / future API auth).
    pub fn with_sender(
        store: Arc<SqliteThreadStore>,
        events: EventBus,
        sender: SenderIdentity,
    ) -> Self {
        Self {
            store,
            events,
            sender,
        }
    }

    fn publish_message(&self, message: &ThreadMessage) {
        self.events.publish(ClientEvent::ThreadMessageReceived {
            thread_message: message.clone(),
        });
    }

    /// Ensure a member row exists in the Thread.
    fn join_member(&self, thread: &str, member_id: &str) -> Result<(), PharosApiError> {
        let (member_id, nick, kind) = member_identity(member_id);
        self.store
            .join(thread, &member_id, &nick, kind)
            .map_err(map_thread_error)
    }
}

#[async_trait]
impl ThreadService for RealThreadService {
    async fn list_threads(&self) -> Result<Vec<ThreadSummary>, PharosApiError> {
        self.store
            .list_threads()
            .map(|threads| threads.into_iter().map(normalize_summary).collect())
            .map_err(map_thread_error)
    }

    async fn get_thread(&self, thread_id: &str) -> Result<ThreadSummary, PharosApiError> {
        self.store
            .get_thread(thread_id)
            .map(normalize_summary)
            .map_err(map_thread_error)
    }

    async fn list_messages(&self, thread_id: &str) -> Result<Vec<ThreadMessage>, PharosApiError> {
        self.store
            .list_messages(thread_id, Some(MESSAGE_LIMIT), None)
            .map(|messages| messages.into_iter().map(normalize_message).collect())
            .map_err(map_thread_error)
    }

    async fn send_message(
        &self,
        thread_id: &str,
        request: SendThreadMessageRequest,
    ) -> Result<ThreadMessage, PharosApiError> {
        // Never create a room implicitly: a send into a missing Thread is 404.
        self.store.get_thread(thread_id).map_err(map_thread_error)?;
        self.join_member(thread_id, &self.sender.member_id)?;
        let message = self
            .store
            .send_message(thread_id, &self.sender, request)
            .map_err(map_thread_error)?;
        let message = normalize_message(message);
        self.publish_message(&message);
        Ok(message)
    }

    async fn reply(
        &self,
        thread_id: &str,
        request: ReplyThreadMessageRequest,
    ) -> Result<ReplyThreadMessageResponse, PharosApiError> {
        let response = self
            .store
            .reply_message(thread_id, request)
            .map_err(map_thread_error)?;
        if let Ok(messages) = self.list_messages(thread_id).await
            && let Some(message) = messages.iter().find(|m| m.id == response.reply_id)
        {
            self.publish_message(message);
        }
        Ok(response)
    }

    async fn create_thread(
        &self,
        request: CreateThreadRequest,
    ) -> Result<ThreadSummary, PharosApiError> {
        let thread_id = validate_thread_id(&request.thread_id)?;
        // Validate every member before touching storage so a bad request cannot
        // leave a half-created room behind.
        let mut members = Vec::with_capacity(request.member_ids.len());
        for member_id in &request.member_ids {
            members.push(validate_member_id(member_id)?);
        }
        // Idempotent: an existing room is reused; requested members are joined
        // if they are not already present.
        self.store
            .ensure_room(thread_id)
            .map_err(map_thread_error)?;
        self.join_member(thread_id, &self.sender.member_id)?;
        for member_id in members {
            self.join_member(thread_id, member_id)?;
        }
        self.store
            .get_thread(thread_id)
            .map(normalize_summary)
            .map_err(map_thread_error)
    }
}

/// Normalize the store's numeric epoch timestamps (`"<secs>.<nanos>"`) to
/// RFC3339 so browser `Date` parsing and the frozen API contract work. Values
/// that are already RFC3339 (or unparsable) are passed through unchanged.
pub fn normalize_timestamp(raw: &str) -> String {
    let (secs_raw, frac_raw) = match raw.split_once('.') {
        Some((secs, frac)) => (secs, frac),
        None => (raw, ""),
    };
    let Ok(secs) = secs_raw.parse::<i64>() else {
        return raw.to_string();
    };
    let mut nanos: i128 = 0;
    if !frac_raw.is_empty() {
        if !frac_raw.bytes().all(|byte| byte.is_ascii_digit()) {
            return raw.to_string();
        }
        let digits: String = frac_raw.chars().take(9).collect();
        let padded = format!("{digits:0<9}");
        nanos = padded.parse::<i128>().unwrap_or(0);
    }
    let Ok(timestamp) = (secs as i128)
        .checked_mul(1_000_000_000)
        .and_then(|base| base.checked_add(nanos))
        .ok_or(())
    else {
        return raw.to_string();
    };
    let Ok(datetime) = OffsetDateTime::from_unix_timestamp_nanos(timestamp) else {
        return raw.to_string();
    };
    datetime
        .format(&Rfc3339)
        .unwrap_or_else(|_| raw.to_string())
}

fn normalize_summary(mut summary: ThreadSummary) -> ThreadSummary {
    summary.last_activity_at = normalize_timestamp(&summary.last_activity_at);
    summary
}

fn normalize_message(mut message: ThreadMessage) -> ThreadMessage {
    message.timestamp = normalize_timestamp(&message.timestamp);
    message
}

fn validate_member_id(raw: &str) -> Result<&str, PharosApiError> {
    let member_id = raw.trim();
    if member_id.is_empty() {
        return Err(PharosApiError::InvalidRequest {
            message: "memberIds must not contain empty entries".into(),
        });
    }
    if member_id.chars().count() > MAX_THREAD_ID_LEN {
        return Err(PharosApiError::InvalidRequest {
            message: format!("memberIds entries must be at most {MAX_THREAD_ID_LEN} characters"),
        });
    }
    if member_id.chars().any(char::is_control) {
        return Err(PharosApiError::InvalidRequest {
            message: "memberIds entries must not contain control characters".into(),
        });
    }
    Ok(member_id)
}

/// Resolve the nick / kind recorded for a member id.
fn member_identity(member_id: &str) -> (String, String, Option<&'static str>) {
    if member_id == grokbot::MEMBER_ID {
        (
            grokbot::MEMBER_ID.to_string(),
            grokbot::DISPLAY_NICK.to_string(),
            Some(grokbot::AGENT_KIND),
        )
    } else {
        (member_id.to_string(), member_id.to_string(), None)
    }
}

fn validate_thread_id(raw: &str) -> Result<&str, PharosApiError> {
    let thread_id = raw.trim();
    if thread_id.is_empty() {
        return Err(PharosApiError::InvalidRequest {
            message: "threadId must not be empty".into(),
        });
    }
    if thread_id.chars().count() > MAX_THREAD_ID_LEN {
        return Err(PharosApiError::InvalidRequest {
            message: format!("threadId must be at most {MAX_THREAD_ID_LEN} characters"),
        });
    }
    if thread_id.chars().any(char::is_control) {
        return Err(PharosApiError::InvalidRequest {
            message: "threadId must not contain control characters".into(),
        });
    }
    Ok(thread_id)
}

/// Map the S1 store error surface onto the frozen HTTP contract errors.
pub fn map_thread_error(error: ThreadError) -> PharosApiError {
    match error {
        ThreadError::NotFound(id) => PharosApiError::ThreadNotFound { id },
        ThreadError::MemberNotFound(id) => PharosApiError::InvalidRequest {
            message: format!("member not found in thread: {id}"),
        },
        ThreadError::ReplyTargetMismatch => PharosApiError::InvalidRequest {
            message: "reply target does not match a directed message for this member".into(),
        },
        ThreadError::EmptyReply => PharosApiError::InvalidRequest {
            message: "reply text must not be empty".into(),
        },
        ThreadError::ReplyConflict(id) => PharosApiError::Conflict {
            message: format!("reply id {id} already exists with different content"),
        },
        ThreadError::InvalidRequest(message) => PharosApiError::InvalidRequest { message },
        ThreadError::Store(message) => PharosApiError::OperationFailed {
            message: format!("thread store: {message}"),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn service() -> RealThreadService {
        let store = Arc::new(SqliteThreadStore::open_in_memory().unwrap());
        RealThreadService::new(store, EventBus::new(8))
    }

    #[tokio::test]
    async fn create_send_list_and_persist_in_store() {
        let service = service();
        let summary = service
            .create_thread(CreateThreadRequest {
                thread_id: "thread-a".into(),
                member_ids: vec!["human".into(), "grokbot".into()],
            })
            .await
            .unwrap();
        assert_eq!(summary.thread_id, "thread-a");
        assert!(summary.member_ids.contains(&"human".to_string()));
        assert!(summary.member_ids.contains(&"grokbot".to_string()));

        let message = service
            .send_message(
                "thread-a",
                SendThreadMessageRequest {
                    text: "hello".into(),
                    target_member_ids: vec!["grokbot".into()],
                    reply_to_message_id: None,
                },
            )
            .await
            .unwrap();
        assert_eq!(message.thread_id, "thread-a");
        assert_eq!(message.sender_id, DEFAULT_SENDER_ID);
        assert_eq!(message.text, "hello");

        let messages = service.list_messages("thread-a").await.unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].id, message.id);

        let threads = service.list_threads().await.unwrap();
        assert_eq!(threads.len(), 1);
        assert_eq!(threads[0].thread_id, "thread-a");
    }

    #[tokio::test]
    async fn create_thread_is_idempotent() {
        let service = service();
        let first = service
            .create_thread(CreateThreadRequest {
                thread_id: "thread-a".into(),
                member_ids: vec![],
            })
            .await
            .unwrap();
        let second = service
            .create_thread(CreateThreadRequest {
                thread_id: "thread-a".into(),
                member_ids: vec!["grokbot".into()],
            })
            .await
            .unwrap();
        assert_eq!(first.thread_id, second.thread_id);
        assert!(second.member_ids.contains(&"grokbot".to_string()));
    }

    #[tokio::test]
    async fn missing_thread_is_not_found_and_not_created_by_send() {
        let service = service();
        let error = service
            .send_message(
                "missing",
                SendThreadMessageRequest {
                    text: "hello".into(),
                    target_member_ids: vec![],
                    reply_to_message_id: None,
                },
            )
            .await
            .unwrap_err();
        assert!(matches!(error, PharosApiError::ThreadNotFound { .. }));
        assert!(service.list_threads().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn invalid_thread_id_rejected() {
        let service = service();
        for bad in ["", "   ", "a\nb"] {
            let error = service
                .create_thread(CreateThreadRequest {
                    thread_id: bad.into(),
                    member_ids: vec![],
                })
                .await
                .unwrap_err();
            assert!(
                matches!(error, PharosApiError::InvalidRequest { .. }),
                "expected invalid request for {bad:?}, got {error:?}"
            );
        }
    }

    #[tokio::test]
    async fn reply_once_is_idempotent_and_published() {
        let events = EventBus::new(16);
        let mut subscriber = events.subscribe();
        let store = Arc::new(SqliteThreadStore::open_in_memory().unwrap());
        let service = RealThreadService::new(store, events);
        service
            .create_thread(CreateThreadRequest {
                thread_id: "thread-a".into(),
                member_ids: vec!["human".into(), "grokbot".into()],
            })
            .await
            .unwrap();
        let message = service
            .send_message(
                "thread-a",
                SendThreadMessageRequest {
                    text: "@Pharos ping".into(),
                    target_member_ids: vec!["grokbot".into()],
                    reply_to_message_id: None,
                },
            )
            .await
            .unwrap();
        let first = service
            .reply(
                "thread-a",
                ReplyThreadMessageRequest {
                    as_member: "grokbot".into(),
                    text: "pong".into(),
                    message_id: Some(message.id.clone()),
                },
            )
            .await
            .unwrap();
        let second = service
            .reply(
                "thread-a",
                ReplyThreadMessageRequest {
                    as_member: "grokbot".into(),
                    text: "pong".into(),
                    message_id: Some(message.id.clone()),
                },
            )
            .await
            .unwrap();
        assert_eq!(first.reply_id, second.reply_id);

        let messages = service.list_messages("thread-a").await.unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(
            messages[1].reply_to.as_ref().map(|r| r.message_id.as_str()),
            Some(message.id.as_str())
        );

        // send + reply both publish threadMessageReceived frames.
        let mut published = 0;
        while let Ok(event) = subscriber.recv().await {
            if matches!(event, ClientEvent::ThreadMessageReceived { .. }) {
                published += 1;
            }
            if published == 3 {
                break;
            }
        }
        assert_eq!(published, 3);
    }

    #[test]
    fn normalize_timestamp_formats_store_epoch_as_rfc3339() {
        // The store emits `"<secs>.<nanos>"`; the browser Date parser needs
        // RFC3339 (regression: real mode rendered "Invalid Date").
        let normalized = normalize_timestamp("1794411586.349847555");
        assert_eq!(normalized, "2026-11-11T15:39:46.349847555Z");
        assert_eq!(normalize_timestamp("0"), "1970-01-01T00:00:00Z");
        assert_eq!(normalize_timestamp("1.5"), "1970-01-01T00:00:01.5Z");
        // Already-RFC3339 or unparsable values pass through untouched.
        assert_eq!(
            normalize_timestamp("2026-11-11T00:00:00Z"),
            "2026-11-11T00:00:00Z"
        );
        assert_eq!(normalize_timestamp("not-a-timestamp"), "not-a-timestamp");
        assert_eq!(normalize_timestamp("12.not-digits"), "12.not-digits");
    }

    #[tokio::test]
    async fn api_timestamps_are_rfc3339() {
        let service = service();
        service
            .create_thread(CreateThreadRequest {
                thread_id: "thread-ts".into(),
                member_ids: vec!["human".into(), "grokbot".into()],
            })
            .await
            .unwrap();
        let message = service
            .send_message(
                "thread-ts",
                SendThreadMessageRequest {
                    text: "hi".into(),
                    target_member_ids: vec![],
                    reply_to_message_id: None,
                },
            )
            .await
            .unwrap();
        assert!(
            message.timestamp.contains('T') && message.timestamp.ends_with('Z'),
            "message timestamp must be RFC3339, got {}",
            message.timestamp
        );
        let threads = service.list_threads().await.unwrap();
        assert!(
            threads[0].last_activity_at.contains('T'),
            "lastActivityAt must be RFC3339, got {}",
            threads[0].last_activity_at
        );
    }

    #[tokio::test]
    async fn invalid_member_id_does_not_create_thread() {
        let service = service();
        let error = service
            .create_thread(CreateThreadRequest {
                thread_id: "thread-bad-member".into(),
                member_ids: vec!["human".into(), "   ".into()],
            })
            .await
            .unwrap_err();
        assert!(matches!(error, PharosApiError::InvalidRequest { .. }));
        assert!(
            service.list_threads().await.unwrap().is_empty(),
            "a rejected member list must not leave a half-created room"
        );
    }
}
