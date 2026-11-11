//! Headless mesh node CLI for RFC-007 S3 smoke (msg-test data dirs only).
//!
//! Subcommands: init | invite | accept | serve | hello | call | sync-pull | sync-push | status

use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

use pharos_iroh::PeerDial;
use pharos_mesh::{
    HostRuntimeCallRequest, IssueInvitationArgs, MeshPeerRecord, ReplicaSyncPullRequest,
    ReplicaSyncPushRequest, SyncedMessage, accept_invitation, decode_ticket, encode_ticket,
    init_node, issue_invitation, load_identity, load_peers, load_signing_key, open_handle,
    save_peer, verify_acceptance,
};
use pharos_protocol::host_session::{
    HostApprovalDecision, HostSessionActionPayload, HostSessionActionRequest,
    HostSessionQueryRequest,
};
use serde_json::json;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
    if let Err(err) = run().await {
        eprintln!("pharos-mesh-node: {err}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let cmd = argv.first().cloned().ok_or_else(usage)?;
    let flags = parse_flags(&argv[1..]);

    match cmd.as_str() {
        "init" => {
            let data_dir = path_flag(&flags, "--data-dir")?;
            let name = str_flag_or(&flags, "--name", "mesh-node");
            let (identity, _) = init_node(&data_dir, &name).map_err(err)?;
            println!("{}", serde_json::to_string_pretty(&identity).map_err(err)?);
        }
        "invite" => {
            let data_dir = path_flag(&flags, "--data-dir")?;
            let identity = load_identity(&data_dir).map_err(err)?;
            let signing = load_signing_key(&data_dir).map_err(err)?;
            let endpoint = if let Some(id) = flags.get("--endpoint-id") {
                id.clone()
            } else {
                let handle = open_handle(data_dir.clone(), None, true)
                    .await
                    .map_err(err)?;
                handle.endpoint_id_string()
            };
            let ticket = str_flag_or(&flags, "--address-ticket", "local");
            let invitation = issue_invitation(
                &signing,
                IssueInvitationArgs {
                    trust_group_id: &identity.trust_group_id,
                    membership_epoch: identity.membership_epoch,
                    inviter_device_id: &identity.device_id,
                    inviter_endpoint_id: &endpoint,
                    inviter_address_ticket: &ticket,
                    inviter_roles: identity.roles.clone(),
                    requested_roles: vec!["host".into(), "replica".into()],
                    lifetime_ms: 10 * 60 * 1000,
                },
            )
            .map_err(err)?;
            println!("{}", encode_ticket(&invitation).map_err(err)?);
        }
        "accept" => {
            let data_dir = path_flag(&flags, "--data-dir")?;
            let invitation_ticket = str_flag(&flags, "--invitation")?;
            let name = str_flag_or(&flags, "--name", "peer");
            let invitation = decode_ticket(&invitation_ticket).map_err(err)?;
            let (mut identity, signing) = init_node(&data_dir, &name).map_err(err)?;
            identity.trust_group_id = invitation.trust_group_id.clone();
            identity.membership_epoch = invitation.membership_epoch;
            std::fs::write(
                data_dir.join("node-identity.json"),
                serde_json::to_vec_pretty(&identity).map_err(err)?,
            )
            .map_err(err)?;
            let handle = open_handle(data_dir.clone(), None, true)
                .await
                .map_err(err)?;
            let acceptance = accept_invitation(
                &invitation,
                &signing,
                &identity.device_id,
                &handle.endpoint_id_string(),
                vec!["host".into(), "replica".into()],
            )
            .map_err(err)?;
            verify_acceptance(&invitation, &acceptance).map_err(err)?;
            save_peer(
                &data_dir,
                &MeshPeerRecord {
                    device_id: invitation.inviter_device_id.clone(),
                    endpoint_id: invitation.inviter_endpoint_id.clone(),
                    display_name: "inviter".into(),
                    roles: invitation.inviter_roles.clone(),
                    endpoint_addr_json: Some(invitation.inviter_address_ticket.clone()),
                },
            )
            .map_err(err)?;
            let store = pharos_replica::ReplicaStore::open(&data_dir).map_err(err)?;
            store
                .upsert_trust_group(
                    &identity.trust_group_id,
                    identity.membership_epoch as i64,
                    "{}",
                )
                .map_err(err)?;
            store
                .upsert_device_identity(
                    &invitation.inviter_device_id,
                    &invitation.inviter_signing_public_key_b64,
                    "{}",
                )
                .map_err(err)?;
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({
                    "identity": identity,
                    "acceptance": acceptance,
                    "endpointId": handle.endpoint_id_string(),
                }))
                .map_err(err)?
            );
        }
        "serve" => {
            let data_dir = path_flag(&flags, "--data-dir")?;
            let runtime_socket = flags.get("--runtime-socket").map(PathBuf::from);
            let relay_disabled = flags.contains_key("--relay-disabled");
            let handle = open_handle(data_dir.clone(), runtime_socket, relay_disabled)
                .await
                .map_err(err)?;
            let identity = load_identity(&data_dir).map_err(err)?;
            print_json(json!({
                "status": "listening",
                "deviceId": identity.device_id,
                "trustGroupId": identity.trust_group_id,
                "membershipEpoch": identity.membership_epoch,
                "endpointId": handle.endpoint_id_string(),
                "endpointAddr": handle.endpoint_addr(),
            }))?;
            tokio::signal::ctrl_c().await.map_err(err)?;
        }
        "hello" => {
            let data_dir = path_flag(&flags, "--data-dir")?;
            let peer_endpoint = str_flag(&flags, "--peer-endpoint")?;
            let peer_addr = flags.get("--peer-addr").cloned();
            let relay_disabled = flags.contains_key("--relay-disabled");
            let handle = open_handle(data_dir, None, relay_disabled)
                .await
                .map_err(err)?;
            let peer = peer_dial(&peer_endpoint, peer_addr.as_deref())?;
            let hello = handle
                .peer_host_runtime_hello(peer, Duration::from_secs(20))
                .await
                .map_err(err)?;
            println!("{}", serde_json::to_string_pretty(&hello).map_err(err)?);
        }
        "call" => {
            let data_dir = path_flag(&flags, "--data-dir")?;
            let peer_endpoint = str_flag(&flags, "--peer-endpoint")?;
            let peer_addr = flags.get("--peer-addr").cloned();
            let host_device_id = str_flag(&flags, "--host-device-id")?;
            let request_file = path_flag(&flags, "--request-file")?;
            let relay_disabled = flags.contains_key("--relay-disabled");
            let jsonrpc_request = std::fs::read_to_string(&request_file).map_err(err)?;
            let handle = open_handle(data_dir, None, relay_disabled)
                .await
                .map_err(err)?;
            let peer = peer_dial(&peer_endpoint, peer_addr.as_deref())?;
            let response = handle
                .peer_host_runtime_call(
                    peer,
                    HostRuntimeCallRequest {
                        host_device_id,
                        jsonrpc_request,
                    },
                    Duration::from_secs(30),
                )
                .await
                .map_err(err)?;
            println!("{}", serde_json::to_string_pretty(&response).map_err(err)?);
        }
        "host-session-query" => {
            let (data_dir, peer, host_device_id, relay_disabled) = host_session_peer(&flags)?;
            let kind = str_flag_or(&flags, "--kind", "list");
            let request = match kind.as_str() {
                "list" => HostSessionQueryRequest::list_sessions(host_device_id),
                "get" => HostSessionQueryRequest::get_session(
                    host_device_id,
                    str_flag(&flags, "--session")?,
                ),
                "history" => HostSessionQueryRequest::session_history(
                    host_device_id,
                    str_flag(&flags, "--session")?,
                ),
                other => {
                    return Err(format!(
                        "unknown --kind {other:?} (expected list|get|history)"
                    ));
                }
            };
            let handle = open_handle(data_dir, None, relay_disabled)
                .await
                .map_err(err)?;
            let response = handle
                .peer_host_session_query(peer, request, Duration::from_secs(30))
                .await
                .map_err(err)?;
            print_json(response)?;
        }
        "host-session-action" => {
            let (data_dir, peer, host_device_id, relay_disabled) = host_session_peer(&flags)?;
            let session_id = str_flag(&flags, "--session")?;
            let action_kind = str_flag_or(&flags, "--action", "send");
            let action = match action_kind.as_str() {
                "send" => HostSessionActionPayload::SendMessage {
                    text: str_flag(&flags, "--text")?,
                    request_id: flags.get("--request-id").cloned(),
                },
                "steer" => HostSessionActionPayload::Steer {
                    text: str_flag(&flags, "--text")?,
                },
                "approve" | "resolve-approval" => HostSessionActionPayload::ResolveApproval {
                    approval_id: str_flag(&flags, "--approval-id")?,
                    decision: parse_approval_decision(&str_flag_or(
                        &flags,
                        "--decision",
                        "allowedOnce",
                    ))?,
                },
                "stop" => HostSessionActionPayload::Stop {
                    force: flags.contains_key("--force"),
                },
                other => {
                    return Err(format!(
                        "unknown --action {other:?} (expected send|steer|approve|stop)"
                    ));
                }
            };
            let action_id = str_flag_or(&flags, "--action-id", &uuid::Uuid::new_v4().to_string());
            let idempotency_key = str_flag_or(
                &flags,
                "--idempotency-key",
                &uuid::Uuid::new_v4().to_string(),
            );
            let request = HostSessionActionRequest::new(
                action_id,
                host_device_id,
                session_id,
                idempotency_key,
                action,
            );
            let handle = open_handle(data_dir, None, relay_disabled)
                .await
                .map_err(err)?;
            let response = handle
                .peer_host_session_action(peer, request, Duration::from_secs(60))
                .await
                .map_err(err)?;
            print_json(response)?;
        }
        "sync-push" => {
            let data_dir = path_flag(&flags, "--data-dir")?;
            let peer_endpoint = str_flag(&flags, "--peer-endpoint")?;
            let peer_addr = flags.get("--peer-addr").cloned();
            let room = str_flag_or(&flags, "--room", "smoke-room");
            let text = str_flag_or(&flags, "--text", "hello-from-mesh");
            let relay_disabled = flags.contains_key("--relay-disabled");
            let handle = open_handle(data_dir, None, relay_disabled)
                .await
                .map_err(err)?;
            let message = SyncedMessage {
                id: uuid::Uuid::new_v4().to_string(),
                room_id: room,
                author_member_id: Some(handle.device_id().to_string()),
                author_nick: "mesh".into(),
                text,
                ts: now_ts(),
                reply_to_message_id: None,
                target_member_ids_json: "[]".into(),
                attachments_json: "[]".into(),
            };
            handle
                .upsert_local_message(message.clone())
                .await
                .map_err(err)?;
            let peer = peer_dial(&peer_endpoint, peer_addr.as_deref())?;
            let response = handle
                .peer_sync_push(
                    peer,
                    ReplicaSyncPushRequest {
                        messages: vec![message],
                    },
                    Duration::from_secs(20),
                )
                .await
                .map_err(err)?;
            println!("{}", serde_json::to_string_pretty(&response).map_err(err)?);
        }
        "sync-pull" => {
            let data_dir = path_flag(&flags, "--data-dir")?;
            let peer_endpoint = str_flag(&flags, "--peer-endpoint")?;
            let peer_addr = flags.get("--peer-addr").cloned();
            let room = flags.get("--room").cloned();
            let relay_disabled = flags.contains_key("--relay-disabled");
            let handle = open_handle(data_dir, None, relay_disabled)
                .await
                .map_err(err)?;
            let peer = peer_dial(&peer_endpoint, peer_addr.as_deref())?;
            let response = handle
                .peer_sync_pull(
                    peer,
                    ReplicaSyncPullRequest {
                        room_id: room,
                        since_ts: 0.0,
                        limit: 100,
                    },
                    Duration::from_secs(20),
                )
                .await
                .map_err(err)?;
            println!("{}", serde_json::to_string_pretty(&response).map_err(err)?);
        }
        "status" => {
            let data_dir = path_flag(&flags, "--data-dir")?;
            let identity = load_identity(&data_dir).map_err(err)?;
            let peers = load_peers(&data_dir).map_err(err)?;
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({
                    "identity": identity,
                    "peers": peers,
                }))
                .map_err(err)?
            );
        }
        "print-endpoint" => {
            let data_dir = path_flag(&flags, "--data-dir")?;
            let relay_disabled = flags.contains_key("--relay-disabled");
            let handle = open_handle(data_dir, None, relay_disabled)
                .await
                .map_err(err)?;
            println!(
                "{}",
                serde_json::to_string(&json!({
                    "endpointId": handle.endpoint_id_string(),
                    "endpointAddr": handle.endpoint_addr(),
                    "deviceId": handle.device_id(),
                }))
                .map_err(err)?
            );
        }
        other => return Err(format!("unknown command: {other}\n{}", usage())),
    }
    Ok(())
}

fn peer_dial(endpoint_id: &str, addr: Option<&str>) -> Result<PeerDial, String> {
    let endpoint_id: pharos_iroh::EndpointId = endpoint_id
        .parse()
        .map_err(|e| format!("invalid endpoint id: {e}"))?;
    let addr = match addr {
        Some(raw) if !raw.is_empty() && raw != "local" => {
            match serde_json::from_str::<pharos_iroh::EndpointAddr>(raw) {
                Ok(parsed) => Some(parsed),
                Err(_) => Some(pharos_iroh::EndpointAddr::new(endpoint_id)),
            }
        }
        _ => Some(pharos_iroh::EndpointAddr::new(endpoint_id)),
    };
    Ok(PeerDial { endpoint_id, addr })
}

fn host_session_peer(
    flags: &HashMap<String, String>,
) -> Result<(PathBuf, PeerDial, String, bool), String> {
    let data_dir = path_flag(flags, "--data-dir")?;
    let peer_endpoint = str_flag(flags, "--peer-endpoint")?;
    let peer_addr = flags.get("--peer-addr").cloned();
    let host_device_id = str_flag(flags, "--host-device-id")?;
    let relay_disabled = flags.contains_key("--relay-disabled");
    let peer = peer_dial(&peer_endpoint, peer_addr.as_deref())?;
    Ok((data_dir, peer, host_device_id, relay_disabled))
}

fn parse_approval_decision(raw: &str) -> Result<HostApprovalDecision, String> {
    match raw {
        "allowedOnce" | "allowed-once" => Ok(HostApprovalDecision::AllowedOnce),
        "allowedAlways" | "allowed-always" => Ok(HostApprovalDecision::AllowedAlways),
        "rejected" => Ok(HostApprovalDecision::Rejected),
        other => Err(format!(
            "unknown --decision {other:?} (expected allowedOnce|allowedAlways|rejected)"
        )),
    }
}

fn parse_flags(args: &[String]) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let mut i = 0;
    while i < args.len() {
        let key = &args[i];
        if key.starts_with("--") {
            if i + 1 < args.len() && !args[i + 1].starts_with("--") {
                map.insert(key.clone(), args[i + 1].clone());
                i += 2;
            } else {
                map.insert(key.clone(), "1".into());
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    map
}

fn path_flag(flags: &HashMap<String, String>, name: &str) -> Result<PathBuf, String> {
    Ok(PathBuf::from(str_flag(flags, name)?))
}

fn str_flag(flags: &HashMap<String, String>, name: &str) -> Result<String, String> {
    flags
        .get(name)
        .cloned()
        .ok_or_else(|| format!("missing {name}"))
}

fn str_flag_or(flags: &HashMap<String, String>, name: &str, default: &str) -> String {
    flags
        .get(name)
        .cloned()
        .unwrap_or_else(|| default.to_string())
}

fn usage() -> String {
    "usage: pharos-mesh-node <init|invite|accept|serve|hello|call|host-session-query|host-session-action|sync-pull|sync-push|status|print-endpoint> --data-dir DIR ...\n\n  host-session-query  --data-dir DIR --peer-endpoint ID --host-device-id ID [--peer-addr ADDR] [--kind list|get|history] [--session ID]\n  host-session-action --data-dir DIR --peer-endpoint ID --host-device-id ID --session ID [--action send|steer|approve|stop] [--text TEXT] [--approval-id ID] [--decision allowedOnce|allowedAlways|rejected] [--request-id ID] [--action-id ID] [--force]".into()
}

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

fn print_json(value: impl serde::Serialize) -> Result<(), String> {
    println!("{}", serde_json::to_string_pretty(&value).map_err(err)?);
    let _ = std::io::stdout().flush();
    Ok(())
}

fn now_ts() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn approval_decisions_accept_wire_and_kebab_names() {
        assert_eq!(
            parse_approval_decision("allowedOnce").unwrap(),
            HostApprovalDecision::AllowedOnce
        );
        assert_eq!(
            parse_approval_decision("allowed-always").unwrap(),
            HostApprovalDecision::AllowedAlways
        );
        assert_eq!(
            parse_approval_decision("rejected").unwrap(),
            HostApprovalDecision::Rejected
        );
        assert!(parse_approval_decision("yes").is_err());
    }

    #[test]
    fn peer_dial_parses_endpoint_id() {
        let key = pharos_iroh::SecretKey::generate();
        let endpoint = key.public();
        let dial = peer_dial(&endpoint.to_string(), None).unwrap();
        assert_eq!(dial.endpoint_id, endpoint);
    }
}
