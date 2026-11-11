//! Host reply dispatch for Codex deliveries.
//!
//! The Runtime owns the Codex turn. Once the matching turn completes, the
//! assistant final answer is written back into the Thread as a `replyOnce`
//! reply correlated to the original Mesh message (`reply_to_id`). The write goes
//! through `pharos-thread`'s SQLite store, whose stable reply id makes a retry
//! after a crash idempotent.
//!
//! This is a *dispatch* step with no success fabrication: [`HostReplySink`]
//! returns `Err` unless the reply row actually persisted, so the Runtime can
//! keep the delivery pending instead of claiming `posted`.

use std::path::PathBuf;

use pharos_api::{ReplyThreadMessageRequest, ReplyThreadMessageResponse};
use pharos_thread::{SqliteThreadStore, ThreadError, ThreadService, open_thread_db};

/// One correlated reply to post for a completed Codex delivery.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostReply {
    /// Thread / room name the original message belongs to.
    pub room: String,
    /// Member identity the delivery was routed to (the Codex session member).
    pub member_id: String,
    /// Original Mesh message id; the reply is linked to it.
    pub original_message_id: String,
    /// Assistant final answer text.
    pub text: String,
    /// Delivery idempotency anchor (for logs/events; the stable thread reply id
    /// is derived from member + original message, not from the delivery).
    pub delivery_id: String,
}

impl HostReply {
    /// Reject payloads the Thread store cannot represent honestly.
    pub fn is_postable(&self) -> bool {
        !self.room.trim().is_empty()
            && !self.member_id.trim().is_empty()
            && !self.original_message_id.trim().is_empty()
            && !self.text.trim().is_empty()
    }
}

/// Sink for host replies; production writes the Thread replica, tests record.
pub trait HostReplySink: Send {
    /// Post exactly one idempotent reply and return its stable reply id.
    fn post_reply(&mut self, reply: &HostReply) -> Result<String, String>;
}

/// Production sink writing into the Host Thread replica (`replica.sqlite3`).
pub struct ThreadStoreReplySink {
    data_dir: PathBuf,
    store: Option<SqliteThreadStore>,
}

impl ThreadStoreReplySink {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            store: None,
        }
    }

    fn store(&mut self) -> Result<&SqliteThreadStore, String> {
        if self.store.is_none() {
            self.store = Some(open_thread_db(&self.data_dir).map_err(|error| error.to_string())?);
        }
        Ok(self.store.as_ref().expect("store was just opened"))
    }

    /// Build a sink around an already-open store (unit tests; e.g. in-memory).
    #[cfg(test)]
    pub(crate) fn from_store(store: SqliteThreadStore) -> Self {
        Self {
            data_dir: PathBuf::new(),
            store: Some(store),
        }
    }
}

impl HostReplySink for ThreadStoreReplySink {
    fn post_reply(&mut self, reply: &HostReply) -> Result<String, String> {
        if !reply.is_postable() {
            return Err("reply is missing room/member/message/text".into());
        }
        let request = ReplyThreadMessageRequest {
            as_member: reply.member_id.clone(),
            text: reply.text.clone(),
            message_id: Some(reply.original_message_id.clone()),
        };
        post_correlated_reply(self.store()?, &reply.room, request, Some("codex"))
            .map(|response| response.reply_id)
            .map_err(|error| error.to_string())
    }
}

/// Post one correlated reply, auto-joining an unknown vendor member first.
///
/// The Runtime routes by member id, but the Thread replica may not have a
/// membership row for that vendor session yet (fresh Host replica). Join with a
/// deterministic nick, then retry the same idempotent reply (same `replyOnce`
/// id -> no duplicate).
///
/// Shared by [`ThreadStoreReplySink`] (Codex final-answer relay) and the
/// additive `thread.reply` RPC (DSH plugin reply write-back) so both paths have
/// byte-for-byte identical idempotency and join behavior.
pub(crate) fn post_correlated_reply(
    store: &SqliteThreadStore,
    room: &str,
    request: ReplyThreadMessageRequest,
    joined_member_kind: Option<&str>,
) -> Result<ReplyThreadMessageResponse, ThreadError> {
    match store.reply_message(room, request.clone()) {
        Ok(response) => Ok(response),
        Err(ThreadError::MemberNotFound(_)) => {
            store.join(
                room,
                &request.as_member,
                &deterministic_nick(&request.as_member),
                joined_member_kind,
            )?;
            store.reply_message(room, request)
        }
        Err(error) => Err(error),
    }
}

/// Stable nick for an auto-joined vendor member.
///
/// Identical across restarts so a retried reply resolves the same membership
/// row; the reply itself is keyed by member id, so the nick is display-only.
pub fn deterministic_nick(member_id: &str) -> String {
    let compact: String = member_id
        .chars()
        .filter(|value| value.is_ascii_alphanumeric())
        .collect();
    let tail: String = {
        let reversed: Vec<char> = compact.chars().rev().take(12).collect();
        reversed.into_iter().rev().collect()
    };
    if tail.is_empty() {
        "codex-member".into()
    } else {
        format!("codex-{tail}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pharos_api::SendThreadMessageRequest;
    use pharos_thread::{SenderIdentity, ThreadService};

    const ROOM: &str = "room-a";
    const MEMBER: &str = "codex-thread-1";

    fn seeded_store() -> (SqliteThreadStore, String) {
        let store = SqliteThreadStore::open_in_memory().unwrap();
        store.join(ROOM, "human-member", "Pai", None).unwrap();
        let original = store
            .send_message(
                ROOM,
                &SenderIdentity {
                    member_id: "human-member".into(),
                    nick: "Pai".into(),
                },
                SendThreadMessageRequest {
                    text: "deploy v2".into(),
                    target_member_ids: vec![MEMBER.into()],
                    reply_to_message_id: None,
                },
            )
            .unwrap();
        (store, original.id)
    }

    fn reply(original: &str, text: &str) -> HostReply {
        HostReply {
            room: ROOM.into(),
            member_id: MEMBER.into(),
            original_message_id: original.into(),
            text: text.into(),
            delivery_id: "delivery-1".into(),
        }
    }

    fn with_store(store: SqliteThreadStore) -> ThreadStoreReplySink {
        ThreadStoreReplySink::from_store(store)
    }

    #[test]
    fn post_writes_one_correlated_reply_and_is_idempotent() {
        let (store, original) = seeded_store();
        let mut sink = with_store(store);
        let first = sink
            .post_reply(&reply(&original, "deployed"))
            .expect("first post");
        // A crash between the store write and the Runtime state update retries
        // the same reply: stable replyOnce id, no duplicate row.
        let second = sink
            .post_reply(&reply(&original, "deployed"))
            .expect("replayed post");
        assert_eq!(first, second);
        assert!(first.starts_with("reply-"));

        let store = sink.store.take().unwrap();
        let history = store.cli_read(ROOM, Some(50), None).unwrap();
        assert_eq!(history.messages.len(), 2, "original + exactly one reply");
        let stored = history
            .messages
            .iter()
            .find(|message| message.id == first)
            .expect("reply row");
        assert_eq!(stored.member_id, MEMBER);
        assert_eq!(
            stored
                .reply_to
                .as_ref()
                .map(|value| value.message_id.as_str()),
            Some(original.as_str())
        );
        assert_eq!(stored.text, "deployed");
    }

    #[test]
    fn conflicting_retry_text_is_rejected_not_overwritten() {
        let (store, original) = seeded_store();
        let mut sink = with_store(store);
        sink.post_reply(&reply(&original, "deployed"))
            .expect("first post");
        let error = sink
            .post_reply(&reply(&original, "different text"))
            .unwrap_err();
        assert!(error.contains("reply conflict"), "unexpected: {error}");
    }

    #[test]
    fn missing_original_message_is_an_error_not_a_fake_reply() {
        let (store, original) = seeded_store();
        let mut sink = with_store(store);
        let mut unknown = reply(&original, "deployed");
        unknown.original_message_id = "message-missing".into();
        assert!(sink.post_reply(&unknown).is_err());
    }

    #[test]
    fn auto_joined_member_nick_is_deterministic() {
        assert_eq!(
            deterministic_nick("codex-thread-1"),
            deterministic_nick("codex-thread-1")
        );
        assert_eq!(deterministic_nick("codex-thread-1"), "codex-codexthread1");
        assert_eq!(deterministic_nick(""), "codex-member");
        assert!(deterministic_nick("thread/with spaces").starts_with("codex-"));
    }

    #[test]
    fn unpostable_reply_is_rejected_before_touching_the_store() {
        let (store, original) = seeded_store();
        let mut sink = with_store(store);
        let mut empty = reply(&original, "deployed");
        empty.text = "   ".into();
        assert!(sink.post_reply(&empty).is_err());
        let empty_member = HostReply {
            member_id: String::new(),
            ..reply(&original, "deployed")
        };
        assert!(sink.post_reply(&empty_member).is_err());
    }
}
