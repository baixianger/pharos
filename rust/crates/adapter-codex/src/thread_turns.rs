//! Real-Codex-0.167 `thread/read {includeTurns:true}` hardening.
//!
//! The vendor `thread/read` with `includeTurns:true` is state-dependent on
//! codex-cli 0.167: on a thread whose turn history is not paged in yet it errors
//! with `-32601 list_turns is not supported yet`, and on some long-lived
//! App Server connections a thread that just completed can come back with
//! `thread.turns: []` (observed nondeterministically in live probes). The
//! supported path for those cases is `thread/turns/list {threadId, itemsView:
//! "full", limit}` whose `data[]` entries are the same turn objects.
//!
//! This module normalizes a reply-read request: it keeps the vendor
//! `thread/read` result when turns are present and otherwise merges the
//! `thread/turns/list` turns back into the `thread/read` shape
//! (`thread.turns`), so `pharos_codex_adapter::inspect_turn_reply` sees the real
//! turns instead of polling to `turn-timeout`.
//!
//! Honesty: the fallback only ever supplies turns the vendor itself returned;
//! when both calls fail the original error is propagated (the Runtime then
//! retries/records a timeout) and nothing is invented.

use crate::error::AdapterError;
use crate::transport::AppServerTransport;
use serde_json::{Value, json};

/// Turn page size requested from the vendor history API. One delivery turn is
/// what reply correlation needs; 20 covers the recent page without paging.
pub(crate) const TURNS_LIST_LIMIT: u64 = 20;

/// Whether a request is a `thread/read` that asked for embedded turns and may
/// therefore hit the 0.167 `list_turns`/empty-turns quirk.
pub(crate) fn is_include_turns_read(method: &str, params: &Value) -> bool {
    method == "thread/read" && params.get("includeTurns").and_then(Value::as_bool) == Some(true)
}

/// Issue `thread/read {includeTurns:true}` with the `thread/turns/list`
/// fallback described in the module docs.
///
/// Returns the vendor result unchanged when it already carries turns. When the
/// direct read fails or elides turns, the vendor `thread/turns/list` page is
/// merged into the `thread/read` shape. Only when both vendor calls fail is the
/// direct error returned.
pub(crate) fn thread_read_include_turns(
    transport: &mut dyn AppServerTransport,
    id: Value,
    params: Value,
) -> Result<Value, AdapterError> {
    let thread_id = params
        .get("threadId")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned);
    let direct = transport.request(id, "thread/read", params);
    match direct {
        Ok(result) => {
            if !turns_missing_or_empty(&result) {
                return Ok(result);
            }
            let Some(thread_id) = thread_id else {
                return Ok(result);
            };
            match list_turns(transport, &thread_id) {
                Ok(turns) => Ok(merge_turns(result, &thread_id, turns)),
                // Keep the honest vendor answer: the Runtime then waits /
                // records a timeout instead of acting on synthetic history.
                Err(_) => Ok(result),
            }
        }
        Err(read_error) => {
            let Some(thread_id) = thread_id else {
                return Err(read_error);
            };
            match list_turns(transport, &thread_id) {
                Ok(turns) => Ok(synthetic_thread_read(&thread_id, turns)),
                Err(_) => Err(read_error),
            }
        }
    }
}

fn list_turns(
    transport: &mut dyn AppServerTransport,
    thread_id: &str,
) -> Result<Vec<Value>, AdapterError> {
    let result = transport.request(
        Value::from("pharos-thread-turns-list"),
        "thread/turns/list",
        json!({
            "threadId": thread_id,
            "itemsView": "full",
            "limit": TURNS_LIST_LIMIT,
        }),
    )?;
    turns_from_list_result(&result)
        .ok_or_else(|| AdapterError::new("thread/turns/list response carries no turns array"))
}

/// Turns out of a `thread/turns/list` result (`{data:[...]}` or `{turns:[...]}`,
/// optionally wrapped in an RPC `result`).
fn turns_from_list_result(result: &Value) -> Option<Vec<Value>> {
    const PATHS: [&str; 6] = [
        "/data",
        "/turns",
        "/result/data",
        "/result/turns",
        "/thread/turns",
        "/result/thread/turns",
    ];
    PATHS
        .iter()
        .find_map(|path| result.pointer(path).and_then(Value::as_array).cloned())
}

/// Whether a `thread/read` result carries no usable turns (missing or empty),
/// i.e. the vendor elided them.
fn turns_missing_or_empty(result: &Value) -> bool {
    const PATHS: [&str; 4] = [
        "/thread/turns",
        "/turns",
        "/result/thread/turns",
        "/result/turns",
    ];
    PATHS.iter().all(|path| {
        result
            .pointer(path)
            .and_then(Value::as_array)
            .is_none_or(|turns| turns.is_empty())
    })
}

/// Merge vendor turns into a `thread/read` result without discarding the real
/// thread metadata/read state.
fn merge_turns(mut result: Value, thread_id: &str, turns: Vec<Value>) -> Value {
    if let Some(thread) = result.get_mut("thread").and_then(Value::as_object_mut) {
        thread.insert("turns".into(), Value::Array(turns));
        return result;
    }
    if let Some(thread) = result
        .get_mut("result")
        .and_then(|value| value.get_mut("thread"))
        .and_then(Value::as_object_mut)
    {
        thread.insert("turns".into(), Value::Array(turns));
        return result;
    }
    // Bare `{turns: []}` shape: replace the array in place.
    if let Some(Value::Array(existing)) = result.get_mut("turns") {
        *existing = turns;
        return result;
    }
    synthetic_thread_read(thread_id, turns)
}

/// Shape for a direct read that failed but whose turns the vendor history API
/// could still return: exactly what `inspect_turn_reply` accepts.
fn synthetic_thread_read(thread_id: &str, turns: Vec<Value>) -> Value {
    json!({
        "thread": {"id": thread_id, "turns": turns},
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reply::{ReplyInspection, inspect_turn_reply};
    use crate::transport::RecordedAppServer;

    fn completed_turn() -> Value {
        json!({
            "id": "turn-1",
            "rootTurnId": "turn-1",
            "status": "completed",
            "itemsView": "full",
            "items": [
                {"type": "userMessage", "id": "item-1", "content": [{"type": "text", "text": "只回复 PONG"}]},
                {"type": "agentMessage", "id": "item-2", "text": "PONG", "phase": "final_answer"}
            ],
            "error": null
        })
    }

    #[test]
    fn recognizes_the_include_turns_read_request_only() {
        assert!(is_include_turns_read(
            "thread/read",
            &json!({"threadId": "t1", "includeTurns": true})
        ));
        assert!(!is_include_turns_read(
            "thread/read",
            &json!({"threadId": "t1", "includeTurns": false})
        ));
        assert!(!is_include_turns_read(
            "thread/read",
            &json!({"threadId": "t1"})
        ));
        assert!(!is_include_turns_read(
            "thread/list",
            &json!({"includeTurns": true})
        ));
    }

    #[test]
    fn empty_turns_are_filled_from_the_supported_history_api() {
        let mut transport = RecordedAppServer::new()
            .respond(
                "thread/read",
                json!({"thread": {"id": "t1", "status": {"type": "idle"}, "turns": []}, "readState": {"revision": "r1"}}),
            )
            .respond("thread/turns/list", json!({"data": [completed_turn()], "nextCursor": null}));
        let result = thread_read_include_turns(
            &mut transport,
            json!("read-1"),
            json!({"threadId": "t1", "includeTurns": true}),
        )
        .expect("normalized read");
        assert_eq!(
            transport.methods(),
            ["thread/read", "thread/turns/list"],
            "the history fallback is only used when turns were elided"
        );
        let listed = transport.request_for("thread/turns/list").unwrap();
        assert_eq!(listed.params["threadId"], "t1");
        assert_eq!(listed.params["itemsView"], "full");
        assert_eq!(listed.params["limit"], TURNS_LIST_LIMIT);
        // Thread metadata and read state survive; the real turns are merged in.
        assert_eq!(result["thread"]["status"]["type"], "idle");
        assert_eq!(result["readState"]["revision"], "r1");
        assert_eq!(
            inspect_turn_reply(&result, "turn-1"),
            ReplyInspection::Ready("PONG".to_owned())
        );
    }

    #[test]
    fn list_turns_not_supported_error_falls_back_to_the_history_api() {
        let mut transport = RecordedAppServer::new()
            .respond_error("thread/read", "list_turns is not supported yet")
            .respond("thread/turns/list", json!({"data": [completed_turn()]}));
        let result = thread_read_include_turns(
            &mut transport,
            json!("read-2"),
            json!({"threadId": "t2", "includeTurns": true}),
        )
        .expect("fallback read");
        assert_eq!(result["thread"]["id"], "t2");
        assert_eq!(
            inspect_turn_reply(&result, "turn-1"),
            ReplyInspection::Ready("PONG".to_owned())
        );
    }

    #[test]
    fn populated_turns_skip_the_history_fallback_entirely() {
        let mut transport = RecordedAppServer::new().respond(
            "thread/read",
            json!({"thread": {"id": "t1", "turns": [completed_turn()]}}),
        );
        let result = thread_read_include_turns(
            &mut transport,
            json!("read-3"),
            json!({"threadId": "t1", "includeTurns": true}),
        )
        .expect("direct read");
        assert_eq!(transport.methods(), ["thread/read"]);
        assert_eq!(
            inspect_turn_reply(&result, "turn-1"),
            ReplyInspection::Ready("PONG".to_owned())
        );
    }

    #[test]
    fn empty_turns_with_failing_history_api_keep_the_honest_vendor_answer() {
        let mut transport = RecordedAppServer::new()
            .respond("thread/read", json!({"thread": {"id": "t1", "turns": []}}))
            .respond_error("thread/turns/list", "history unavailable");
        let result = thread_read_include_turns(
            &mut transport,
            json!("read-4"),
            json!({"threadId": "t1", "includeTurns": true}),
        )
        .expect("vendor read result");
        assert_eq!(
            inspect_turn_reply(&result, "turn-1"),
            ReplyInspection::Waiting,
            "no fabricated turns when both vendor calls fail"
        );
    }

    #[test]
    fn both_vendor_calls_failing_propagates_the_original_read_error() {
        let mut transport = RecordedAppServer::new()
            .respond_error("thread/read", "list_turns is not supported yet")
            .respond_error("thread/turns/list", "history unavailable");
        let error = thread_read_include_turns(
            &mut transport,
            json!("read-5"),
            json!({"threadId": "t1", "includeTurns": true}),
        )
        .expect_err("original error");
        assert_eq!(error.message, "list_turns is not supported yet");
    }

    #[test]
    fn bare_turns_shape_is_also_filled() {
        let mut transport = RecordedAppServer::new()
            .respond("thread/read", json!({"turns": []}))
            .respond("thread/turns/list", json!({"turns": [completed_turn()]}));
        let result = thread_read_include_turns(
            &mut transport,
            json!("read-6"),
            json!({"threadId": "t1", "includeTurns": true}),
        )
        .expect("normalized bare read");
        assert_eq!(
            inspect_turn_reply(&result, "turn-1"),
            ReplyInspection::Ready("PONG".to_owned())
        );
    }
}
