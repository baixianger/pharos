//! Stable `replyOnce` entity IDs (parity with Swift DistributedChatRegistry).

use sha2::{Digest, Sha256};

/// Scope used when the S3 trust-group UUID is not yet available.
pub const REPLY_ONCE_SCOPE_LOCAL: &str = "local";

/// Compute `reply-<sha256 hex>` for an idempotent Thread reply.
///
/// Swift encodes `["pharos-thread-reply-v1", groupUUID, roomID, memberID,
/// originalMessageID]` with sorted-keys JSONEncoder. Arrays keep element order;
/// we emit the same JSON array bytes.
pub fn reply_once_id(
    scope_id: &str,
    room_id: &str,
    member_id: &str,
    original_message_id: &str,
) -> String {
    let key = serde_json::json!([
        "pharos-thread-reply-v1",
        scope_id,
        room_id,
        member_id,
        original_message_id,
    ]);
    let bytes = serde_json::to_vec(&key).expect("replyOnce key is valid JSON");
    let digest = Sha256::digest(&bytes);
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    format!("reply-{hex}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reply_once_id_is_stable() {
        let a = reply_once_id("local", "room-1", "grokbot", "msg-1");
        let b = reply_once_id("local", "room-1", "grokbot", "msg-1");
        assert_eq!(a, b);
        assert!(a.starts_with("reply-"));
        assert_eq!(a.len(), "reply-".len() + 64);
    }

    #[test]
    fn reply_once_id_changes_with_inputs() {
        let a = reply_once_id("local", "room-1", "grokbot", "msg-1");
        let b = reply_once_id("local", "room-1", "grokbot", "msg-2");
        assert_ne!(a, b);
    }
}
