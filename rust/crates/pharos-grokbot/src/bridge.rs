//! Grokbot Thread bridge — Runtime poll → wake webhook → honest ack states.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use pharos_protocol::grokbot;
use pharos_protocol::runtime_methods;
use pharos_thread::CliThreadMessage;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::runtime::{RuntimeClient, RuntimeError};
use crate::webhook::{NotifyResult, default_webhook_env_path, notify_thread_mention};

pub type RuntimeFn = Box<dyn Fn(&str, Value) -> Result<Value, RuntimeError> + Send + Sync>;
pub type HistoryFn = Box<dyn Fn(&str) -> Result<Vec<CliThreadMessage>, String> + Send + Sync>;
pub type NotifyFn = Box<dyn Fn(&str, &str, &str, &str) -> NotifyResult + Send + Sync>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GrokbotPending {
    pub delivery_id: String,
    pub thread: String,
    pub message_id: String,
    pub from: String,
    pub host: String,
    pub injected_at: Instant,
}

pub struct GrokbotThreadBridge {
    runtime: RuntimeFn,
    history: HistoryFn,
    notify: NotifyFn,
    host_label: String,
    driver_id: String,
    conversation_id: Mutex<Option<String>>,
    sequence: Mutex<u64>,
    pending: Mutex<Option<GrokbotPending>>,
    polling: Mutex<bool>,
    accepting: Mutex<bool>,
}

impl GrokbotThreadBridge {
    pub fn new(
        runtime: RuntimeFn,
        history: HistoryFn,
        notify: NotifyFn,
        host_label: impl Into<String>,
        driver_id: Option<String>,
    ) -> Self {
        Self {
            runtime,
            history,
            notify,
            host_label: host_label.into(),
            driver_id: driver_id.unwrap_or_else(|| format!("grokbot-thread:{}", Uuid::new_v4())),
            conversation_id: Mutex::new(None),
            sequence: Mutex::new(0),
            pending: Mutex::new(None),
            polling: Mutex::new(false),
            accepting: Mutex::new(true),
        }
    }

    /// Production wiring: UDS Runtime + ThreadStore history + real webhook env.
    pub fn with_runtime_client(
        client: RuntimeClient,
        history: HistoryFn,
        host_label: impl Into<String>,
        webhook_env: Option<PathBuf>,
    ) -> Self {
        let env = webhook_env.unwrap_or_else(default_webhook_env_path);
        let runtime: RuntimeFn = Box::new(move |method, params| client.call(method, params));
        let notify: NotifyFn = Box::new(move |thread, message, from, host| {
            notify_thread_mention(thread, message, from, host, &env)
        });
        Self::new(runtime, history, notify, host_label, None)
    }

    pub fn pending_delivery(&self) -> Option<GrokbotPending> {
        self.pending.lock().ok().and_then(|g| g.clone())
    }

    pub fn ensure_registered(&self) -> Result<(), RuntimeError> {
        (self.runtime)(
            runtime_methods::DRIVER_REGISTER,
            json!({
                "driverID": self.driver_id,
                "kind": grokbot::AGENT_KIND,
                "capabilities": ["delivery.poll"],
            }),
        )?;
        let mut conv = self
            .conversation_id
            .lock()
            .map_err(|_| RuntimeError::Rpc("lock".into()))?;
        if conv.is_none() {
            let registered = (self.runtime)(
                runtime_methods::CONVERSATION_REGISTER,
                json!({
                    "driverID": self.driver_id,
                    "kind": grokbot::AGENT_KIND,
                    "vendorSessionID": grokbot::MEMBER_ID,
                    "memberID": grokbot::MEMBER_ID,
                }),
            )?;
            let id = registered
                .get("id")
                .and_then(Value::as_str)
                .ok_or_else(|| RuntimeError::Rpc("Runtime did not register grokbot".into()))?
                .to_string();
            *conv = Some(id);
        }
        let conversation_id = conv
            .clone()
            .ok_or_else(|| RuntimeError::Rpc("missing conversation".into()))?;
        drop(conv);

        let mut seq = self
            .sequence
            .lock()
            .map_err(|_| RuntimeError::Rpc("lock".into()))?;
        *seq += 1;
        let sequence = *seq;
        drop(seq);

        let accepting = *self
            .accepting
            .lock()
            .map_err(|_| RuntimeError::Rpc("lock".into()))?;
        let pending = self
            .pending
            .lock()
            .map_err(|_| RuntimeError::Rpc("lock".into()))?
            .is_some();

        (self.runtime)(
            runtime_methods::CONVERSATION_STATE,
            json!({
                "conversationID": conversation_id,
                "presence": if accepting { "online" } else { "offline" },
                "activity": if pending { "running" } else { "idle" },
                "attention": "none",
                "persistence": "persistent",
                "source": "nativeProtocol",
                "sourceEpoch": self.driver_id,
                "sequence": sequence,
            }),
        )?;
        Ok(())
    }

    /// Poll Runtime, wake proxy on new directed mail, advance honest states.
    pub fn poll(&self) -> Result<(), String> {
        {
            let mut polling = self.polling.lock().map_err(|_| "lock".to_string())?;
            if *polling {
                return Ok(());
            }
            *polling = true;
        }
        let result = self.poll_inner();
        if let Ok(mut polling) = self.polling.lock() {
            *polling = false;
        }
        result
    }

    fn poll_inner(&self) -> Result<(), String> {
        self.ensure_registered().map_err(|e| e.to_string())?;
        let conversation_id = self
            .conversation_id
            .lock()
            .map_err(|_| "lock".to_string())?
            .clone()
            .ok_or_else(|| "missing conversation".to_string())?;

        if let Some(current) = self.pending_delivery() {
            if self.room_has_reply(&current)? {
                (self.runtime)(
                    runtime_methods::DELIVERY_ACK,
                    json!({
                        "deliveryID": current.delivery_id,
                        "state": "completed",
                        "detail": "grokbot replyOnce persisted",
                    }),
                )
                .map_err(|e| e.to_string())?;
                *self.pending.lock().map_err(|_| "lock".to_string())? = None;
            } else if current.injected_at.elapsed()
                >= Duration::from_secs(grokbot::REPLY_TIMEOUT_SECS)
            {
                (self.runtime)(
                    runtime_methods::DELIVERY_ACK,
                    json!({
                        "deliveryID": current.delivery_id,
                        "state": "failed",
                        "detail": "grokbot reply timeout (45m)",
                    }),
                )
                .map_err(|e| e.to_string())?;
                *self.pending.lock().map_err(|_| "lock".to_string())? = None;
            }
            return Ok(());
        }

        let accepting = *self.accepting.lock().map_err(|_| "lock".to_string())?;
        if !accepting {
            return Ok(());
        }

        let records = (self.runtime)(
            runtime_methods::DELIVERY_POLL,
            json!({ "conversationID": conversation_id }),
        )
        .map_err(|e| e.to_string())?;
        let records = records.as_array().cloned().unwrap_or_default();
        let Some(record) = records.first() else {
            return Ok(());
        };
        let delivery_id = record
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let payload = record.get("payload").and_then(Value::as_str).unwrap_or("");
        let envelope: Value = serde_json::from_str(payload).unwrap_or(Value::Null);
        let message = envelope.get("meshMessage").cloned().unwrap_or(Value::Null);
        let targets = message
            .get("targetMemberIDs")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let targets_ok = targets
            .iter()
            .any(|v| v.as_str() == Some(grokbot::MEMBER_ID));
        let room = envelope
            .get("room")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let message_id = envelope
            .get("messageID")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let sender = envelope
            .get("sender")
            .and_then(Value::as_str)
            .or_else(|| message.get("from").and_then(Value::as_str))
            .unwrap_or("")
            .to_string();

        if !targets_ok || room.is_empty() || message_id.is_empty() || sender.is_empty() {
            if !delivery_id.is_empty() {
                (self.runtime)(
                    runtime_methods::DELIVERY_ACK,
                    json!({
                        "deliveryID": delivery_id,
                        "state": "failed",
                        "detail": "Missing explicit Mesh target binding for grokbot",
                    }),
                )
                .map_err(|e| e.to_string())?;
            }
            return Ok(());
        }

        let notify_result = (self.notify)(&room, &message_id, &sender, &self.host_label);
        match notify_result {
            NotifyResult::Posted { .. } => {
                (self.runtime)(
                    runtime_methods::DELIVERY_ACK,
                    json!({
                        "deliveryID": delivery_id,
                        "state": "injected",
                        "detail": "human-proxy webhook posted (wake-only)",
                    }),
                )
                .map_err(|e| e.to_string())?;
                *self.pending.lock().map_err(|_| "lock".to_string())? = Some(GrokbotPending {
                    delivery_id,
                    thread: room,
                    message_id,
                    from: sender,
                    host: self.host_label.clone(),
                    injected_at: Instant::now(),
                });
            }
            NotifyResult::SkippedMissingConfig => {
                (self.runtime)(
                    runtime_methods::DELIVERY_ACK,
                    json!({
                        "deliveryID": delivery_id,
                        "state": "failed",
                        "detail": "human-proxy webhook env missing",
                    }),
                )
                .map_err(|e| e.to_string())?;
            }
            NotifyResult::Failed(detail) => {
                (self.runtime)(
                    runtime_methods::DELIVERY_ACK,
                    json!({
                        "deliveryID": delivery_id,
                        "state": "failed",
                        "detail": format!("human-proxy webhook failed: {detail}"),
                    }),
                )
                .map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }

    fn room_has_reply(&self, current: &GrokbotPending) -> Result<bool, String> {
        let messages = (self.history)(&current.thread)?;
        Ok(messages.iter().any(|m| {
            m.member_id == grokbot::MEMBER_ID
                && m.reply_to
                    .as_ref()
                    .map(|r| r.message_id == current.message_id)
                    .unwrap_or(false)
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct FixtureRuntime {
        conversation_id: String,
        queue: Mutex<Vec<Value>>,
        acks: Mutex<HashMap<String, String>>,
    }

    impl FixtureRuntime {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                conversation_id: "conv-grokbot".into(),
                queue: Mutex::new(Vec::new()),
                acks: Mutex::new(HashMap::new()),
            })
        }

        fn enqueue(&self, room: &str, message_id: &str, sender: &str, text: &str) {
            let envelope = json!({
                "body": text,
                "room": room,
                "messageID": message_id,
                "sender": sender,
                "meshMessage": {
                    "id": message_id,
                    "from": sender,
                    "room": room,
                    "text": text,
                    "targetMemberIDs": [grokbot::MEMBER_ID],
                }
            });
            self.queue.lock().unwrap().push(json!({
                "id": Uuid::new_v4().to_string(),
                "payload": envelope.to_string(),
                "state": "queued",
            }));
        }

        fn handle(self: &Arc<Self>, method: &str, params: Value) -> Result<Value, RuntimeError> {
            match method {
                "driver.register" => Ok(json!({"ok": true})),
                "conversation.register" => Ok(json!({"id": self.conversation_id})),
                "conversation.state" => Ok(json!({"ok": true})),
                "delivery.poll" => Ok(Value::Array(self.queue.lock().unwrap().clone())),
                "delivery.ack" => {
                    let id = params
                        .get("deliveryID")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let state = params
                        .get("state")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    self.acks.lock().unwrap().insert(id.clone(), state.clone());
                    if matches!(state.as_str(), "injected" | "failed" | "completed") {
                        self.queue
                            .lock()
                            .unwrap()
                            .retain(|r| r.get("id").and_then(Value::as_str) != Some(id.as_str()));
                    }
                    Ok(json!({"ok": true}))
                }
                other => Err(RuntimeError::Rpc(format!("unexpected {other}"))),
            }
        }
    }

    #[test]
    fn webhook_success_is_injected_not_replied() {
        let runtime = FixtureRuntime::new();
        let history: Arc<Mutex<Vec<CliThreadMessage>>> = Arc::new(Mutex::new(Vec::new()));
        let notify_count = Arc::new(AtomicUsize::new(0));

        let rt = Arc::clone(&runtime);
        let hist = Arc::clone(&history);
        let nc = Arc::clone(&notify_count);
        let bridge = GrokbotThreadBridge::new(
            Box::new(move |m, p| rt.handle(m, p)),
            Box::new(move |room| {
                Ok(hist
                    .lock()
                    .unwrap()
                    .iter()
                    .filter(|m| m.thread == room)
                    .cloned()
                    .collect())
            }),
            Box::new(move |_, _, _, _| {
                nc.fetch_add(1, Ordering::SeqCst);
                NotifyResult::Posted { status_code: 200 }
            }),
            "mini",
            Some("drv-test".into()),
        );

        bridge.ensure_registered().unwrap();
        bridge.poll().unwrap();
        assert!(bridge.pending_delivery().is_none());

        runtime.enqueue("thread-a", "msg-1", "human", "@Pharos hello");
        bridge.poll().unwrap();
        let pending = bridge.pending_delivery().unwrap();
        assert_eq!(pending.message_id, "msg-1");
        assert_eq!(pending.thread, "thread-a");
        assert_eq!(notify_count.load(Ordering::SeqCst), 1);
        assert_eq!(
            runtime
                .acks
                .lock()
                .unwrap()
                .get(&pending.delivery_id)
                .map(String::as_str),
            Some("injected")
        );

        bridge.poll().unwrap();
        assert_eq!(
            bridge.pending_delivery().map(|p| p.delivery_id),
            Some(pending.delivery_id.clone())
        );

        history.lock().unwrap().push(CliThreadMessage {
            id: "reply-1".into(),
            thread: "thread-a".into(),
            from: grokbot::DISPLAY_NICK.into(),
            member_id: grokbot::MEMBER_ID.into(),
            text: "ack".into(),
            ts: 1.0,
            to: vec!["human".into()],
            target_member_ids: vec![],
            reply_to: Some(pharos_thread::CliReplyTo {
                message_id: "msg-1".into(),
                from: "human".into(),
                preview: "hello".into(),
            }),
        });
        bridge.poll().unwrap();
        assert!(bridge.pending_delivery().is_none());
        assert_eq!(
            runtime
                .acks
                .lock()
                .unwrap()
                .get(&pending.delivery_id)
                .map(String::as_str),
            Some("completed")
        );
    }

    #[test]
    fn missing_webhook_fails_delivery() {
        let runtime = FixtureRuntime::new();
        let rt = Arc::clone(&runtime);
        let bridge = GrokbotThreadBridge::new(
            Box::new(move |m, p| rt.handle(m, p)),
            Box::new(|_| Ok(vec![])),
            Box::new(|_, _, _, _| NotifyResult::SkippedMissingConfig),
            "mini",
            Some("drv-test".into()),
        );
        bridge.ensure_registered().unwrap();
        runtime.enqueue("thread-b", "msg-2", "human", "@grokbot ping");
        bridge.poll().unwrap();
        assert!(bridge.pending_delivery().is_none());
        let failed = runtime.acks.lock().unwrap().values().any(|s| s == "failed");
        assert!(failed);
    }
}
