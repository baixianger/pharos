//! Human-proxy webhook wake (ID-only payloads). Never logs the webhook key.

use std::fs;
use std::path::{Path, PathBuf};

use pharos_protocol::{ThreadMentionWake, WebhookKind};
use pharos_store_schema::host_config;
use serde_json::json;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WebhookConfig {
    pub url: String,
    pub key: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NotifyResult {
    SkippedMissingConfig,
    Posted { status_code: u16 },
    Failed(String),
}

pub fn default_webhook_env_path() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"));
    home.join(host_config::HUMAN_PROXY_WEBHOOK_ENV)
}

/// Parse `PHAROS_HUMAN_PROXY_WEBHOOK_URL` / `PHAROS_HUMAN_PROXY_WEBHOOK_KEY`.
/// Returns `None` when the file is missing or either value is empty.
pub fn load_webhook_config(env_file: &Path) -> Option<WebhookConfig> {
    let text = fs::read_to_string(env_file).ok()?;
    let mut url = None;
    let mut key = None;
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let k = k.trim();
        let mut v = v.trim().to_string();
        if (v.starts_with('"') && v.ends_with('"')) || (v.starts_with('\'') && v.ends_with('\'')) {
            v = v[1..v.len() - 1].to_string();
        }
        match k {
            "PHAROS_HUMAN_PROXY_WEBHOOK_URL" => url = Some(v),
            "PHAROS_HUMAN_PROXY_WEBHOOK_KEY" => key = Some(v),
            _ => {}
        }
    }
    let url = url?.trim().to_string();
    let key = key?.trim().to_string();
    if url.is_empty() || key.is_empty() {
        return None;
    }
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return None;
    }
    Some(WebhookConfig { url, key })
}

/// Wake-only Thread mention. Payload carries IDs only — never message text.
pub fn notify_thread_mention(
    thread: &str,
    message_id: &str,
    from: &str,
    host: &str,
    env_file: &Path,
) -> NotifyResult {
    if thread.is_empty()
        || message_id.is_empty()
        || from.is_empty()
        || host.is_empty()
        || thread.len() > 256
        || message_id.len() > 256
        || from.len() > 256
        || host.len() > 256
    {
        return NotifyResult::Failed("invalid thread-mention ids".into());
    }
    let Some(config) = load_webhook_config(env_file) else {
        return NotifyResult::SkippedMissingConfig;
    };
    let wake = ThreadMentionWake {
        kind: WebhookKind::ThreadMention,
        thread: thread.to_string(),
        message: message_id.to_string(),
        from: from.to_string(),
        host: host.to_string(),
    };
    // Serialize via the contract type, then ensure camelCase keys match protocol doc.
    let body = match serde_json::to_value(&wake) {
        Ok(v) => v,
        Err(e) => return NotifyResult::Failed(e.to_string()),
    };
    // Protocol doc uses flat keys: kind/thread/message/from/host (kebab kind).
    // ThreadMentionWake already serializes kind as "thread-mention".
    let _ = json!({
        "kind": "thread-mention",
        "thread": thread,
        "message": message_id,
        "from": from,
        "host": host,
    });
    post_webhook_json(&config, &body)
}

fn post_webhook_json(config: &WebhookConfig, body: &serde_json::Value) -> NotifyResult {
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(5))
        .timeout_read(std::time::Duration::from_secs(15))
        .build();
    match agent
        .post(&config.url)
        .set("Content-Type", "application/json")
        .set("Authorization", &format!("Bearer {}", config.key))
        .send_json(body)
    {
        Ok(resp) => {
            let code = resp.status();
            if (200..300).contains(&code) {
                NotifyResult::Posted { status_code: code }
            } else {
                NotifyResult::Failed(format!("HTTP {code}"))
            }
        }
        Err(ureq::Error::Status(code, _)) => NotifyResult::Failed(format!("HTTP {code}")),
        Err(e) => NotifyResult::Failed(e.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn missing_env_is_skipped() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("missing.env");
        let result = notify_thread_mention("t1", "m1", "human", "mini", &path);
        assert_eq!(result, NotifyResult::SkippedMissingConfig);
    }

    #[test]
    fn loads_webhook_config() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("human-proxy-webhook.env");
        let mut f = fs::File::create(&path).unwrap();
        writeln!(
            f,
            "PHAROS_HUMAN_PROXY_WEBHOOK_URL=https://example.invalid/hook\nPHAROS_HUMAN_PROXY_WEBHOOK_KEY=secret"
        )
        .unwrap();
        let cfg = load_webhook_config(&path).unwrap();
        assert_eq!(cfg.url, "https://example.invalid/hook");
        assert_eq!(cfg.key, "secret");
    }
}
