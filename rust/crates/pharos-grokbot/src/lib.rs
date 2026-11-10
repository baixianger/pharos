//! Grokbot Thread member (webhook-backed, nick `Pharos`).
//!
//! Ports Swift `GrokbotThreadBridge` + `HumanProxyChannel.notifyThreadMention`.
//! Honest Runtime states: webhook 2xx → `injected`; room `replyOnce` →
//! `completed`; 45 minutes without reply → `failed`.

mod bridge;
mod runtime;
mod webhook;

pub use bridge::{GrokbotPending, GrokbotThreadBridge, HistoryFn, NotifyFn, RuntimeFn};
pub use runtime::{RuntimeClient, RuntimeError};
pub use webhook::{
    NotifyResult, WebhookConfig, default_webhook_env_path, load_webhook_config,
    notify_thread_mention,
};

pub use pharos_protocol::grokbot::{AGENT_KIND, DISPLAY_NICK, MEMBER_ID, REPLY_TIMEOUT_SECS};
