//! Integration: two ReplicaHandles over iroh — hello, sync push/pull, host.runtime.call.

use std::io::{Read, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use pharos_iroh::PeerDial;
use pharos_mesh::{
    HostRuntimeCallRequest, ReplicaSyncPullRequest, ReplicaSyncPushRequest, SyncedMessage,
    init_node, open_handle,
};
use serde_json::json;
use tempfile::tempdir;

#[tokio::test]
async fn peer_hello_sync_and_runtime_call() {
    let root = tempdir().unwrap();
    let host_dir = root.path().join("host");
    let client_dir = root.path().join("client");
    let runtime_dir = root.path().join("runtime");
    std::fs::create_dir_all(&runtime_dir).unwrap();
    let runtime_sock = runtime_dir.join("agent.sock");

    // Minimal JSON-RPC Unix server that accepts delivery.submit-member.
    let sock_path = runtime_sock.clone();
    thread::spawn(move || {
        let _ = std::fs::remove_file(&sock_path);
        let listener = UnixListener::bind(&sock_path).expect("bind runtime sock");
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = Vec::new();
            let mut tmp = [0u8; 4096];
            while let Ok(n) = stream.read(&mut tmp) {
                if n == 0 {
                    break;
                }
                buf.extend_from_slice(&tmp[..n]);
                if buf.contains(&b'\n') {
                    break;
                }
            }
            let response = json!({
                "jsonrpc": "2.0",
                "id": "1",
                "result": {
                    "submitted": true,
                    "deliveryID": "deliv-smoke-1",
                    "delivery": { "id": "deliv-smoke-1", "state": "queued" }
                }
            });
            let _ = stream.write_all(format!("{response}\n").as_bytes());
        }
    });
    // Wait for socket file.
    for _ in 0..50 {
        if runtime_sock.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    let (host_identity, _) = init_node(&host_dir, "host").unwrap();
    // Client joins the same trust group by rewriting identity after init.
    let (mut client_identity, _) = init_node(&client_dir, "client").unwrap();
    client_identity.trust_group_id = host_identity.trust_group_id.clone();
    client_identity.membership_epoch = host_identity.membership_epoch;
    std::fs::write(
        client_dir.join("node-identity.json"),
        serde_json::to_vec_pretty(&client_identity).unwrap(),
    )
    .unwrap();

    let host = open_handle(PathBuf::from(&host_dir), Some(runtime_sock.clone()), true)
        .await
        .expect("host open");
    let client = open_handle(PathBuf::from(&client_dir), None, true)
        .await
        .expect("client open");

    tokio::time::sleep(Duration::from_millis(300)).await;

    let peer = PeerDial {
        endpoint_id: host.endpoint_id(),
        addr: Some(host.endpoint_addr()),
    };

    let hello = client
        .peer_host_runtime_hello(peer.clone(), Duration::from_secs(15))
        .await
        .expect("hello");
    assert_eq!(hello.host_device_id, host_identity.device_id);
    assert!(
        hello
            .capabilities
            .iter()
            .any(|c| c == "delivery.submit-member")
    );

    let message = SyncedMessage {
        id: "msg-1".into(),
        room_id: "room-smoke".into(),
        author_member_id: Some("client".into()),
        author_nick: "client".into(),
        text: "peer-sync-smoke".into(),
        ts: 42.0,
        reply_to_message_id: None,
        target_member_ids_json: "[]".into(),
        attachments_json: "[]".into(),
    };
    let push = client
        .peer_sync_push(
            peer.clone(),
            ReplicaSyncPushRequest {
                messages: vec![message.clone()],
            },
            Duration::from_secs(15),
        )
        .await
        .expect("sync push");
    assert_eq!(push.applied, 1);

    let pull = client
        .peer_sync_pull(
            peer.clone(),
            ReplicaSyncPullRequest {
                room_id: Some("room-smoke".into()),
                since_ts: 0.0,
                limit: 10,
            },
            Duration::from_secs(15),
        )
        .await
        .expect("sync pull");
    assert_eq!(pull.messages.len(), 1);
    assert_eq!(pull.messages[0].text, "peer-sync-smoke");

    let call = client
        .peer_host_runtime_call(
            peer,
            HostRuntimeCallRequest {
                host_device_id: host_identity.device_id.clone(),
                jsonrpc_request: json!({
                    "jsonrpc": "2.0",
                    "id": "1",
                    "method": "delivery.submit-member",
                    "params": {
                        "memberID": "member-1",
                        "idempotencyKey": "mesh:smoke:1",
                        "payload": "{\"body\":\"hi\"}"
                    }
                })
                .to_string(),
            },
            Duration::from_secs(15),
        )
        .await
        .expect("host.runtime.call");
    assert!(call.jsonrpc_response.contains("deliv-smoke-1"));
    assert_eq!(call.host_device_id, host_identity.device_id);

    let _ = Arc::clone(&host);
    let _ = Arc::clone(&client);
}
