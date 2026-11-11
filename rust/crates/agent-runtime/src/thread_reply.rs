//! Additive `thread.reply` RPC: DSH reply write-back into the Host Thread replica.
//!
//! The DSH plugin (`integrations/dsh-plugin-pharos`) owns the vendor loop: it
//! polls a delivery, injects it with `agent.followup`, correlates the claimed
//! message to its turn, and once the turn ends calls this RPC once with the
//! assistant text. That keeps the Rust `pharos-adapter-dsh` thin (it never posts
//! a room reply itself) and leaves the choice of write-back path to the owner:
//! approach B (this RPC) is additive and side-effect free unless called, so
//! switching it off means dropping the plugin's `thread.reply` call and keeping
//! the canonical DSH mesh tool instead.
//!
//! Idempotency and honesty:
//! - the reply id is `pharos-thread`'s stable `replyOnce` id derived from
//!   `(scope, room id, member, original message id)`, so an identical retry
//!   returns the same `reply_id` and never inserts a second row;
//! - a conflicting text for the same `(room, member, messageId)` is an error
//!   (`reply conflict`), never an overwrite;
//! - unknown room / unknown-or-unaddressed message / oversized text are explicit
//!   errors;
//! - `ok: true` is only returned after the row persisted (no fabricated success).
//!
//! `messageId` semantics: callers that need replay-safe idempotency must pass it
//! (the DSH plugin always does). When omitted, the underlying store replies to
//! the newest *unreplied directed* message in the room and the resolved anchor is
//! returned as `replyTo`; a retried call is then free to pick the next unreplied
//! message, so omission is accepted but explicitly not replay-safe.

use std::path::PathBuf;

use pharos_api::ReplyThreadMessageRequest;
use pharos_thread::{SqliteThreadStore, ThreadError, open_thread_db, resolve_db_path};
use serde_json::Value;

use crate::reply_sink::post_correlated_reply;
use crate::{MAX_REPLY_BYTES, Registry, RuntimeError, RuntimeResult, value};

/// Member kind recorded when this RPC auto-joins a member missing from the
/// replica (display metadata only; the reply is keyed by member id).
const JOINED_MEMBER_KIND: &str = "dsh";

/// Lazily opened Host Thread replica used by `thread.reply`.
///
/// The path is re-resolved on every call so a Host that creates/relocates
/// `<thread-data-dir>/mesh/` after the runtime started (or that shares the
/// `--thread-data-dir` with the web data dir) is picked up instead of pinning a
/// stale database.
pub(crate) struct ThreadReplyStore {
    thread_data_dir: PathBuf,
    open: Option<(PathBuf, SqliteThreadStore)>,
}

impl ThreadReplyStore {
    pub(crate) fn new(thread_data_dir: PathBuf) -> Self {
        Self {
            thread_data_dir,
            open: None,
        }
    }

    fn store(&mut self) -> Result<&SqliteThreadStore, RuntimeError> {
        let path = resolve_db_path(&self.thread_data_dir);
        let reopen = match &self.open {
            Some((current, _)) => current != &path,
            None => true,
        };
        if reopen {
            let store = open_thread_db(&self.thread_data_dir)
                .map_err(|error| RuntimeError::internal(format!("open thread replica: {error}")))?;
            self.open = Some((path, store));
        }
        Ok(&self
            .open
            .as_ref()
            .expect("thread replica was just opened")
            .1)
    }

    /// Validate one `thread.reply` call and post the idempotent reply.
    pub(crate) fn post(&mut self, params: &Value) -> RuntimeResult {
        let room = non_empty_string(params, "room")?;
        let as_member = non_empty_string(params, "asMember")?;
        let text = non_empty_string(params, "text")?;
        if text.len() > MAX_REPLY_BYTES {
            return Err(RuntimeError::invalid(format!(
                "text exceeds {MAX_REPLY_BYTES} bytes"
            )));
        }
        let message_id = match params.get("messageId") {
            None | Some(Value::Null) => None,
            Some(Value::String(id)) => {
                let id = id.trim();
                if id.is_empty() {
                    return Err(RuntimeError::invalid(
                        "messageId must be a non-empty string when provided",
                    ));
                }
                Some(id.to_string())
            }
            Some(_) => {
                return Err(RuntimeError::invalid(
                    "messageId must be a non-empty string when provided",
                ));
            }
        };
        let request = ReplyThreadMessageRequest {
            as_member,
            text,
            message_id,
        };
        let response =
            post_correlated_reply(self.store()?, &room, request, Some(JOINED_MEMBER_KIND))
                .map_err(thread_error)?;
        value(response)
    }
}

fn non_empty_string(params: &Value, key: &str) -> Result<String, RuntimeError> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| RuntimeError::invalid(format!("{key} must be a non-empty string")))
}

/// Map a store error to an explicit JSON-RPC error (never a fake success).
fn thread_error(error: ThreadError) -> RuntimeError {
    match error {
        ThreadError::NotFound(thread) => {
            RuntimeError::not_found(format!("Unknown thread/room: {thread}"))
        }
        ThreadError::ReplyTargetMismatch => RuntimeError::invalid(
            "messageId does not exist in that room, or it was not addressed to asMember",
        ),
        ThreadError::EmptyReply => RuntimeError::invalid("text must not be empty"),
        ThreadError::ReplyConflict(reply_id) => RuntimeError::invalid(format!(
            "reply conflict: {reply_id} already exists with different text; refusing to overwrite"
        )),
        ThreadError::InvalidRequest(message) => RuntimeError::invalid(message),
        ThreadError::MemberNotFound(member) => {
            RuntimeError::internal(format!("thread member not found: {member}"))
        }
        ThreadError::Store(message) => RuntimeError::internal(message),
    }
}

impl Registry {
    /// `thread.reply` dispatch: exactly one idempotent correlated reply.
    pub(crate) fn thread_reply(&mut self, params: &Value) -> RuntimeResult {
        self.thread_reply_store.post(params)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::new_id;
    use crate::reply_sink::deterministic_nick;
    use pharos_api::SendThreadMessageRequest;
    use pharos_thread::{SenderIdentity, ThreadService};
    use serde_json::json;
    use std::fs;
    use std::path::Path;

    const ROOM: &str = "room-reply";
    const OTHER_ROOM: &str = "room-other";
    const MEMBER: &str = "dsh-session-1";
    const HUMAN: &str = "human-1";

    fn temp_dir() -> PathBuf {
        PathBuf::from(format!("/tmp/pharos-thread-reply-test-{}", new_id()))
    }

    /// Seed the Host layout (`<dir>/mesh/replica.sqlite3`): a human member and
    /// one message per `texts` entry, each directed at `member`.
    fn seed(directory: &Path, room: &str, member: &str, texts: &[&str]) -> Vec<String> {
        fs::create_dir_all(directory.join("mesh")).unwrap();
        let store = open_thread_db(directory).unwrap();
        store.join(room, HUMAN, "Pai", Some("human")).unwrap();
        texts
            .iter()
            .map(|text| {
                store
                    .send_message(
                        room,
                        &SenderIdentity {
                            member_id: HUMAN.into(),
                            nick: "Pai".into(),
                        },
                        SendThreadMessageRequest {
                            text: (*text).into(),
                            target_member_ids: vec![member.into()],
                            reply_to_message_id: None,
                        },
                    )
                    .unwrap()
                    .id
            })
            .collect()
    }

    fn registry(directory: &Path) -> Registry {
        Registry::load(directory.to_path_buf())
            .unwrap()
            .with_thread_data_dir(directory.to_path_buf())
    }

    fn reply_params(room: &str, member: &str, text: &str, message_id: Option<&str>) -> Value {
        let mut params = json!({"room": room, "asMember": member, "text": text});
        if let Some(message_id) = message_id {
            params["messageId"] = json!(message_id);
        }
        params
    }

    #[test]
    fn capability_is_advertised_in_runtime_hello() {
        let directory = temp_dir();
        let mut registry = registry(&directory);
        let hello = registry.invoke("runtime.hello", &json!({})).unwrap();
        let capabilities = hello["capabilities"].as_array().unwrap();
        assert!(
            capabilities
                .iter()
                .any(|value| value.as_str() == Some("thread-reply-v1")),
            "runtime.hello must advertise thread-reply-v1: {capabilities:?}"
        );
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn replayed_reply_is_idempotent_and_visible_via_store_cli_read() {
        let directory = temp_dir();
        let originals = seed(&directory, ROOM, MEMBER, &["deploy v2"]);
        let original = originals[0].as_str();
        let mut registry = registry(&directory);

        let params = reply_params(ROOM, MEMBER, "deployed v2", Some(original));
        let first = registry.invoke("thread.reply", &params).unwrap();
        assert_eq!(first["ok"], json!(true));
        assert_eq!(first["thread"], json!(ROOM));
        assert_eq!(first["as"], json!(MEMBER));
        assert_eq!(first["replyTo"], json!(original));
        let reply_id = first["replyId"].as_str().unwrap().to_string();
        assert!(reply_id.starts_with("reply-"), "stable replyOnce id");

        // Identical retry (crash between store write and ack): same id, one row.
        let second = registry.invoke("thread.reply", &params).unwrap();
        assert_eq!(second["replyId"], json!(reply_id));
        assert_eq!(second["replyTo"], json!(original));

        // Parity: the row is what the store/CLI sees, correlated to the original.
        let store = open_thread_db(&directory).unwrap();
        let history = store.cli_read(ROOM, Some(50), None).unwrap();
        assert_eq!(history.messages.len(), 2, "original + exactly one reply");
        let stored = history
            .messages
            .iter()
            .find(|message| message.id == reply_id)
            .expect("reply row");
        assert_eq!(stored.member_id, MEMBER);
        assert_eq!(stored.text, "deployed v2");
        assert_eq!(
            stored
                .reply_to
                .as_ref()
                .map(|value| value.message_id.as_str()),
            Some(original)
        );
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn conflicting_text_for_same_anchor_is_rejected_not_overwritten() {
        let directory = temp_dir();
        let originals = seed(&directory, ROOM, MEMBER, &["deploy v2"]);
        let original = originals[0].as_str();
        let mut registry = registry(&directory);

        registry
            .invoke(
                "thread.reply",
                &reply_params(ROOM, MEMBER, "deployed v2", Some(original)),
            )
            .unwrap();
        let error = registry
            .invoke(
                "thread.reply",
                &reply_params(ROOM, MEMBER, "different answer", Some(original)),
            )
            .unwrap_err();
        assert!(
            error.message.contains("reply conflict"),
            "unexpected: {}",
            error.message
        );

        let store = open_thread_db(&directory).unwrap();
        let history = store.cli_read(ROOM, Some(50), None).unwrap();
        assert_eq!(history.messages.len(), 2, "no second/overwritten row");
        let reply = history
            .messages
            .iter()
            .find(|message| message.member_id == MEMBER)
            .expect("reply row");
        assert_eq!(reply.text, "deployed v2");
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn empty_room_member_and_text_are_rejected_before_touching_the_store() {
        let directory = temp_dir();
        seed(&directory, ROOM, MEMBER, &["deploy v2"]);
        let mut registry = registry(&directory);

        for params in [
            reply_params("", MEMBER, "text", None),
            reply_params("   ", MEMBER, "text", None),
            reply_params(ROOM, "", "text", None),
            reply_params(ROOM, "  ", "text", None),
            reply_params(ROOM, MEMBER, "", None),
            reply_params(ROOM, MEMBER, "   ", None),
        ] {
            let error = registry.invoke("thread.reply", &params).unwrap_err();
            assert!(
                error.message.contains("non-empty string"),
                "unexpected: {}",
                error.message
            );
        }
        // A whitespace-only/omitted messageId is explicit, not silently dropped.
        let mut blank_anchor = reply_params(ROOM, MEMBER, "text", None);
        blank_anchor["messageId"] = json!("   ");
        assert!(registry.invoke("thread.reply", &blank_anchor).is_err());

        let oversized = "x".repeat(MAX_REPLY_BYTES + 1);
        let error = registry
            .invoke(
                "thread.reply",
                &reply_params(ROOM, MEMBER, &oversized, None),
            )
            .unwrap_err();
        assert!(
            error.message.contains("exceeds"),
            "unexpected: {}",
            error.message
        );

        let store = open_thread_db(&directory).unwrap();
        let history = store.cli_read(ROOM, Some(50), None).unwrap();
        assert_eq!(history.messages.len(), 1, "rejected calls wrote nothing");
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn unknown_room_is_an_explicit_error() {
        let directory = temp_dir();
        seed(&directory, ROOM, MEMBER, &["deploy v2"]);
        let mut registry = registry(&directory);
        let error = registry
            .invoke(
                "thread.reply",
                &reply_params("never-created", MEMBER, "nope", None),
            )
            .unwrap_err();
        assert!(
            error.message.contains("Unknown thread/room"),
            "unexpected: {}",
            error.message
        );
        assert!(!error.message.is_empty());
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn unknown_or_unaddressed_message_id_is_an_explicit_error() {
        let directory = temp_dir();
        let _originals = seed(&directory, ROOM, MEMBER, &["deploy v2"]);
        let other = seed(&directory, OTHER_ROOM, MEMBER, &["other room message"]);
        let mut registry = registry(&directory);

        let unknown = registry
            .invoke(
                "thread.reply",
                &reply_params(ROOM, MEMBER, "text", Some("message-missing")),
            )
            .unwrap_err();
        assert!(
            unknown.message.contains("messageId does not exist"),
            "unexpected: {}",
            unknown.message
        );

        // A real message anchored in a different room is not a valid anchor here.
        let from_other_room = registry
            .invoke(
                "thread.reply",
                &reply_params(ROOM, MEMBER, "text", Some(other[0].as_str())),
            )
            .unwrap_err();
        assert!(
            from_other_room.message.contains("messageId does not exist"),
            "unexpected: {}",
            from_other_room.message
        );
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn unknown_member_is_auto_joined_deterministically_then_reply_is_idempotent() {
        let directory = temp_dir();
        let originals = seed(&directory, ROOM, MEMBER, &["deploy v2"]);
        let original = originals[0].as_str();
        let mut registry = registry(&directory);

        let params = reply_params(ROOM, MEMBER, "deployed v2", Some(original));
        let first = registry.invoke("thread.reply", &params).unwrap();
        let reply_id = first["replyId"].as_str().unwrap().to_string();

        let store = open_thread_db(&directory).unwrap();
        let history = store.cli_read(ROOM, Some(50), None).unwrap();
        let reply = history
            .messages
            .iter()
            .find(|message| message.id == reply_id)
            .expect("reply row");
        assert_eq!(
            reply.from,
            deterministic_nick(MEMBER),
            "auto-join uses the deterministic vendor nick"
        );
        assert_eq!(reply.member_id, MEMBER);

        // Replay after the auto-join resolves the same member: still one reply.
        let second = registry.invoke("thread.reply", &params).unwrap();
        assert_eq!(second["replyId"], json!(reply_id));
        assert_eq!(
            store.cli_read(ROOM, Some(50), None).unwrap().messages.len(),
            2
        );
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn omitted_message_id_uses_store_anchor_but_is_not_replay_safe() {
        let directory = temp_dir();
        let originals = seed(
            &directory,
            ROOM,
            MEMBER,
            &["first directed", "second directed"],
        );
        let mut registry = registry(&directory);

        // No messageId: the store resolves the newest unreplied directed message.
        let first = registry
            .invoke("thread.reply", &reply_params(ROOM, MEMBER, "answer", None))
            .unwrap();
        assert_eq!(first["replyTo"], json!(originals[1].as_str()));
        // Documented caveat: a retried anchor-less call is not replay-safe; it
        // resolves the next unreplied message instead of returning the same id.
        let second = registry
            .invoke("thread.reply", &reply_params(ROOM, MEMBER, "answer", None))
            .unwrap();
        assert_eq!(second["replyTo"], json!(originals[0].as_str()));
        assert_ne!(first["replyId"], second["replyId"]);
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn omitted_message_id_without_unreplied_target_is_an_explicit_error() {
        let directory = temp_dir();
        // A room with only a human-authored (undirected) message.
        fs::create_dir_all(directory.join("mesh")).unwrap();
        {
            let store = open_thread_db(&directory).unwrap();
            store.join(ROOM, HUMAN, "Pai", Some("human")).unwrap();
            store
                .send_message(
                    ROOM,
                    &SenderIdentity {
                        member_id: HUMAN.into(),
                        nick: "Pai".into(),
                    },
                    SendThreadMessageRequest {
                        text: "undirected".into(),
                        target_member_ids: vec![],
                        reply_to_message_id: None,
                    },
                )
                .unwrap();
        }
        let mut registry = registry(&directory);
        let error = registry
            .invoke("thread.reply", &reply_params(ROOM, MEMBER, "answer", None))
            .unwrap_err();
        assert!(
            error.message.contains("no unreplied directed message"),
            "unexpected: {}",
            error.message
        );
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn lazy_store_opens_only_when_called_and_picks_up_later_database() {
        let directory = temp_dir();
        let mut registry = registry(&directory);
        // Never called yet: loading the registry must not create a replica.
        assert!(!resolve_db_path(&directory).exists());

        // The Host replica appears after the runtime started (web data dir/mesh).
        let originals = seed(&directory, ROOM, MEMBER, &["late message"]);
        let response = registry
            .invoke(
                "thread.reply",
                &reply_params(ROOM, MEMBER, "late answer", Some(originals[0].as_str())),
            )
            .unwrap();
        assert_eq!(response["ok"], json!(true));
        assert!(
            resolve_db_path(&directory).ends_with("mesh/replica.sqlite3"),
            "host layout `<data-dir>/mesh/replica.sqlite3` is resolved"
        );
        fs::remove_dir_all(directory).ok();
    }
}
