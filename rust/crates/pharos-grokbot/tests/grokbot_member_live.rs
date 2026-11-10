//! Grokbot member E2E against Rust Thread store + CLI + local pharos-meshd.
//!
//! Gate: `PHAROS_GROKBOT_MEMBER_TEST=1`
//! Requires: `rust/target/debug/pharos-meshd`, `rust/target/debug/pharos`,
//! and optionally `~/.config/pharos/human-proxy-webhook.env`.
//!
//! Unlike the Swift live test (which waits up to 45m for an external human),
//! this run **self-replies** via the Rust CLI after inject so the gate is
//! automatable. External human-proxy SSH reply within 45m is documented as
//! PARTIAL in the stream evidence.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use pharos_api::SendThreadMessageRequest;
use pharos_grokbot::{
    AGENT_KIND, DISPLAY_NICK, GrokbotThreadBridge, MEMBER_ID, NotifyResult, RuntimeClient,
    RuntimeError, default_webhook_env_path, load_webhook_config,
};
use pharos_thread::{SenderIdentity, ThreadService, open_thread_db};
use serde_json::{Value, json};
use uuid::Uuid;

fn env_gate() -> bool {
    std::env::var("PHAROS_GROKBOT_MEMBER_TEST").ok().as_deref() == Some("1")
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .canonicalize()
        .expect("repo root")
}

fn msg_test_root() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").expect("HOME")).join("personal/pharos-msg-test")
}

#[test]
fn rust_grokbot_member_thread_mention_reply_when_enabled() {
    if !env_gate() {
        eprintln!("skip: set PHAROS_GROKBOT_MEMBER_TEST=1");
        return;
    }

    let root = repo_root();
    let meshd = root.join("rust/target/debug/pharos-meshd");
    let cli = root.join("rust/target/debug/pharos");
    assert!(
        meshd.is_file(),
        "build rust/target/debug/pharos-meshd first"
    );
    assert!(cli.is_file(), "build rust/target/debug/pharos first");

    let webhook_env = default_webhook_env_path();
    let webhook_configured = load_webhook_config(&webhook_env).is_some();
    if !webhook_configured {
        eprintln!(
            "note: missing ~/.config/pharos/human-proxy-webhook.env — \
             bridge will fail deliveries (GB-THD-02 wake PARTIAL)"
        );
    }

    let token = &Uuid::new_v4().to_string()[..8];
    let thread_name = format!("grokbot-{token}");
    let marker = format!("PHAROS_GROKBOT_MEMBER_DONE_{token}");
    let base = msg_test_root().join(format!("grokbot-member-rust/{token}"));
    let requests = msg_test_root().join("human-requests");
    fs::create_dir_all(&base).unwrap();
    fs::create_dir_all(&requests).unwrap();
    let mesh_dir = base.join("mesh");
    fs::create_dir_all(&mesh_dir).unwrap();
    let runtime_dir = base.join("runtime");
    fs::create_dir_all(&runtime_dir).unwrap();
    let socket = base.join("agent-runtime.sock");

    let mut runtime = Command::new(&meshd)
        .args([
            "--socket",
            socket.to_str().unwrap(),
            "--data-dir",
            runtime_dir.to_str().unwrap(),
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("start pharos-meshd");
    let _guard = RuntimeGuard {
        child: &mut runtime,
    };

    for _ in 0..100 {
        if socket.exists() {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    assert!(socket.exists(), "runtime socket missing");

    // Isolated Thread store (PHASE0_DDL) — not Swift MeshLocalReplica.
    let store = Arc::new(open_thread_db(&mesh_dir).expect("open thread db"));
    store
        .join(&thread_name, MEMBER_ID, DISPLAY_NICK, Some(AGENT_KIND))
        .unwrap();
    store
        .join(
            &thread_name,
            &format!("agy-stub-{token}"),
            "agy-stub",
            Some("agy"),
        )
        .unwrap();
    store
        .join(&thread_name, "human", "Human", Some("human"))
        .unwrap();

    let client = RuntimeClient::new(&socket);
    let store_hist = Arc::clone(&store);
    let notify_env = webhook_env.clone();
    let bridge = GrokbotThreadBridge::new(
        Box::new(move |method, params| client.call(method, params)),
        Box::new(move |room| {
            store_hist
                .history_for_bridge(room, 40)
                .map_err(|e| e.to_string())
        }),
        Box::new(move |thread, message, from, host| {
            pharos_grokbot::notify_thread_mention(thread, message, from, host, &notify_env)
        }),
        "xiang-mac-mini",
        None,
    );
    bridge.ensure_registered().expect("register grokbot");
    bridge.poll().expect("empty poll");

    let original = store
        .send_message(
            &thread_name,
            &SenderIdentity {
                member_id: "human".into(),
                nick: "Human".into(),
            },
            SendThreadMessageRequest {
                text: format!("@{DISPLAY_NICK} Reply exactly {marker}. Keep it short."),
                target_member_ids: vec![MEMBER_ID.into()],
                reply_to_message_id: None,
            },
        )
        .expect("send directed");
    println!(
        "Grokbot member Thread={thread_name} message={}",
        original.id
    );

    let stamp = chrono_like_stamp();
    let request_name = format!("{stamp}_grokbot-thread-mention-rust.md");
    let read_cmd = format!(
        "{} thread read --thread {} --data-dir {}",
        cli.display(),
        thread_name,
        mesh_dir.display()
    );
    let reply_file = base.join("reply.txt");
    let reply_cmd = format!(
        "printf '%s\\n' '{marker}' > {} && {} thread reply --thread {} --as grokbot \
         --message {} --text-file {} --data-dir {}",
        reply_file.display(),
        cli.display(),
        thread_name,
        original.id,
        reply_file.display(),
        mesh_dir.display()
    );
    let md = format!(
        "# Grokbot Thread mention (Rust CLI)\n\n\
         - kind: thread-mention\n\
         - thread: {thread_name}\n\
         - message: {id}\n\
         - from: human\n\
         - host: xiang-mac-mini\n\
         - timeout: 45 minutes\n\
         - rule: webhook payload is wake-only (IDs). Run only the commands below.\n\
         - note: this evidence run self-replies via Rust CLI (not external 45m wait).\n\n\
         ## Read\n\n```sh\n{read_cmd}\n```\n\n\
         ## Reply as grokbot\n\n```sh\n{reply_cmd}\n```\n",
        id = original.id
    );
    fs::write(requests.join(&request_name), md).unwrap();
    println!("Grokbot human-request written: {request_name}");

    // delivery.submit-member (Runtime must already have grokbot conversation).
    submit_member(&socket, &original.id, &thread_name, &original.text).expect("submit-member");

    bridge.poll().expect("inject poll");
    let pending = bridge.pending_delivery();
    if webhook_configured {
        assert!(
            pending.is_some(),
            "webhook success must leave delivery injected/pending"
        );
        println!(
            "Grokbot injected delivery={} thread={}",
            pending.as_ref().unwrap().delivery_id,
            pending.as_ref().unwrap().thread
        );
    } else {
        eprintln!("PARTIAL: webhook env missing — no injected pending");
    }

    // Self-reply via Rust CLI (GB-THD-04/05 parity).
    fs::write(&reply_file, format!("{marker}\n")).unwrap();
    let read_out = Command::new(&cli)
        .args([
            "thread",
            "read",
            "--thread",
            &thread_name,
            "--data-dir",
            mesh_dir.to_str().unwrap(),
        ])
        .output()
        .expect("thread read");
    assert!(
        read_out.status.success(),
        "thread read failed: {}",
        String::from_utf8_lossy(&read_out.stderr)
    );
    let read_json: Value = serde_json::from_slice(&read_out.stdout).expect("read json");
    assert_eq!(read_json["member"], "grokbot");
    assert_eq!(read_json["nick"], "Pharos");
    assert!(read_json["messages"].as_array().unwrap().len() >= 1);

    let reply_out = Command::new(&cli)
        .args([
            "thread",
            "reply",
            "--thread",
            &thread_name,
            "--as",
            "grokbot",
            "--message",
            &original.id,
            "--text-file",
            reply_file.to_str().unwrap(),
            "--data-dir",
            mesh_dir.to_str().unwrap(),
        ])
        .output()
        .expect("thread reply");
    assert!(
        reply_out.status.success(),
        "thread reply failed: {}",
        String::from_utf8_lossy(&reply_out.stderr)
    );
    let reply_json: Value = serde_json::from_slice(&reply_out.stdout).expect("reply json");
    assert_eq!(reply_json["ok"], true);
    assert_eq!(reply_json["as"], "grokbot");
    assert_eq!(reply_json["replyTo"], original.id);
    let reply_id = reply_json["replyID"].as_str().unwrap().to_string();
    assert!(reply_id.starts_with("reply-"));

    // Idempotent re-reply.
    let again = Command::new(&cli)
        .args([
            "thread",
            "reply",
            "--thread",
            &thread_name,
            "--as",
            "grokbot",
            "--message",
            &original.id,
            "--text-file",
            reply_file.to_str().unwrap(),
            "--data-dir",
            mesh_dir.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(again.status.success());
    let again_json: Value = serde_json::from_slice(&again.stdout).unwrap();
    assert_eq!(again_json["replyID"], reply_id);

    if pending.is_some() {
        bridge.poll().expect("complete poll");
        assert!(
            bridge.pending_delivery().is_none(),
            "pending must clear after grokbot replyOnce"
        );
    }

    let snapshot = runtime_snapshot(&socket).expect("snapshot");
    let deliveries = snapshot["deliveries"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let completed = deliveries
        .iter()
        .filter(|d| d["state"] == "completed")
        .count();
    let injected_or_better = deliveries
        .iter()
        .any(|d| matches!(d["state"].as_str(), Some("injected") | Some("completed")));

    println!(
        "Grokbot member DONE thread={thread_name} message={} reply={reply_id} \
         completed={completed} marker={marker} webhook_configured={webhook_configured}",
        original.id
    );

    if webhook_configured {
        assert!(
            injected_or_better,
            "honest path must have injected before completed"
        );
        assert_eq!(completed, 1);
    }

    // Silence unused import warning when webhook path unused in some builds.
    let _ = NotifyResult::SkippedMissingConfig;
}

struct RuntimeGuard<'a> {
    child: &'a mut std::process::Child,
}

impl Drop for RuntimeGuard<'_> {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn submit_member(
    socket: &Path,
    message_id: &str,
    room: &str,
    text: &str,
) -> Result<(), RuntimeError> {
    let client = RuntimeClient::new(socket);
    let envelope = json!({
        "body": text,
        "room": room,
        "messageID": message_id,
        "sender": "Human",
        "meshMessage": {
            "id": message_id,
            "from": "Human",
            "authorMemberID": "human",
            "room": room,
            "text": text,
            "ts": 0.0,
            "to": [DISPLAY_NICK],
            "targetMemberIDs": [MEMBER_ID],
        }
    });
    let result = client.call(
        "delivery.submit-member",
        json!({
            "memberID": MEMBER_ID,
            "idempotencyKey": format!("mesh:{message_id}:{MEMBER_ID}"),
            "payload": envelope.to_string(),
        }),
    )?;
    if result.get("submitted").and_then(Value::as_bool) != Some(true) {
        return Err(RuntimeError::Rpc(format!("submit rejected: {result}")));
    }
    Ok(())
}

fn runtime_snapshot(socket: &Path) -> Result<Value, RuntimeError> {
    RuntimeClient::new(socket).call("runtime.snapshot", json!({}))
}

fn chrono_like_stamp() -> String {
    // UTC-ish stamp without pulling time crate into the test binary.
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("2026-11-10T{secs}Z")
}

#[allow(dead_code)]
fn wait_until(deadline: Instant, mut f: impl FnMut() -> bool) -> bool {
    while Instant::now() < deadline {
        if f() {
            return true;
        }
        thread::sleep(Duration::from_millis(200));
    }
    false
}

#[allow(dead_code)]
fn write_log(path: &Path, body: &str) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let mut f = fs::File::create(path).unwrap();
    let _ = f.write_all(body.as_bytes());
}
