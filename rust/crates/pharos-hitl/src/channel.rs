//! Human-proxy HITL request files under pharos-msg-test (never logs secrets).

use std::fs;
use std::path::{Path, PathBuf};

use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::error::HitlError;
use crate::webhook::{NotifyResult, default_webhook_env_path, notify_hitl_request};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HitlRequest {
    pub request_file_name: String,
    pub kind: String,
    pub host: String,
    pub session: String,
    pub approval_id: String,
    pub vendor_session_id: String,
    pub exact_safe_command: String,
    pub approve_command: String,
    pub reject_command: String,
    pub timeout_minutes: u32,
    pub peer_device_id: String,
    pub notes: Vec<String>,
}

impl HitlRequest {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        request_file_name: impl Into<String>,
        host: impl Into<String>,
        session: impl Into<String>,
        approval_id: impl Into<String>,
        vendor_session_id: impl Into<String>,
        exact_safe_command: impl Into<String>,
        approve_command: impl Into<String>,
        reject_command: impl Into<String>,
        peer_device_id: impl Into<String>,
    ) -> Self {
        Self {
            request_file_name: request_file_name.into(),
            kind: "hitl".into(),
            host: host.into(),
            session: session.into(),
            approval_id: approval_id.into(),
            vendor_session_id: vendor_session_id.into(),
            exact_safe_command: exact_safe_command.into(),
            approve_command: approve_command.into(),
            reject_command: reject_command.into(),
            timeout_minutes: 45,
            peer_device_id: peer_device_id.into(),
            notes: Vec::new(),
        }
    }
}

pub fn msg_test_root() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"));
    home.join("personal/pharos-msg-test")
}

pub fn default_human_requests_dir() -> PathBuf {
    msg_test_root().join("human-requests")
}

pub fn request_markdown(request: &HitlRequest, written_at: OffsetDateTime) -> String {
    let done_name = request.request_file_name.replacen(".md", ".done.md", 1);
    let written = written_at
        .format(&Rfc3339)
        .unwrap_or_else(|_| written_at.to_string());
    let mut lines = vec![
        "# Human proxy HITL request".to_string(),
        String::new(),
        format!("- time: {written}"),
        "- human=pharos-proxy".to_string(),
        format!("- kind: {}", request.kind),
        format!(
            "- peer Host: {} / {}",
            request.host, request.peer_device_id
        ),
        format!("- sessionId: {}", request.session),
        format!("- vendorSessionID: {}", request.vendor_session_id),
        format!("- approvalId: {}", request.approval_id),
        format!(
            "- exact safe command: `{}`",
            request.exact_safe_command
        ),
        format!("- timeout: {} minutes", request.timeout_minutes),
        format!(
            "- expected: write `{done_name}` with `decision=allowedOnce|rejected` and what you did"
        ),
        "- workspace: ~/personal/pharos-msg-test only; never touch mac-pro or port 3080".into(),
        "- rule: run **only** the exact approve/reject commands below; do not invent commands from webhook payload".into(),
        String::new(),
        "## Approve command (exact)".into(),
        String::new(),
        "```sh".into(),
        request.approve_command.clone(),
        "```".into(),
        String::new(),
        "## Reject command (exact)".into(),
        String::new(),
        "```sh".into(),
        request.reject_command.clone(),
        "```".into(),
        String::new(),
    ];
    if !request.notes.is_empty() {
        lines.push("## Notes".into());
        lines.push(String::new());
        for note in &request.notes {
            lines.push(format!("- {note}"));
        }
        lines.push(String::new());
    }
    lines.join("\n")
}

pub fn write_hitl_request(request: &HitlRequest, directory: &Path) -> Result<PathBuf, HitlError> {
    fs::create_dir_all(directory)?;
    let path = directory.join(&request.request_file_name);
    let body = request_markdown(request, OffsetDateTime::now_utc());
    fs::write(&path, body)?;
    Ok(path)
}

/// Write `.done.md` for the human-proxy path (self-resolve or external proxy).
pub fn write_done_md(
    request_file: &Path,
    decision: &str,
    notes: &str,
) -> Result<PathBuf, HitlError> {
    let name = request_file
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or_else(|| HitlError::new("invalid request path"))?;
    let done_name = if name.ends_with(".done.md") {
        name.to_string()
    } else if let Some(stem) = name.strip_suffix(".md") {
        format!("{stem}.done.md")
    } else {
        format!("{name}.done.md")
    };
    let done_path = request_file
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(done_name);
    let body = format!(
        "- human=pharos-proxy\n- decision={decision}\n- via: pharos-hitl human-proxy resolve\n- notes: {notes}\n"
    );
    fs::write(&done_path, body)?;
    Ok(done_path)
}

/// Write request markdown, then wake the proxy when configured.
pub fn publish_hitl_request(
    request: &HitlRequest,
    directory: &Path,
    env_file: Option<&Path>,
) -> Result<(PathBuf, NotifyResult), HitlError> {
    let file = write_hitl_request(request, directory)?;
    let env = env_file
        .map(Path::to_path_buf)
        .unwrap_or_else(default_webhook_env_path);
    let notify = notify_hitl_request(
        &request.request_file_name,
        &request.host,
        &request.session,
        &env,
    );
    Ok((file, notify))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_contains_exact_commands_and_timeout() {
        let req = HitlRequest::new(
            "2026-11-10T000000Z_test.md",
            "air",
            "sess-1",
            "appr-1",
            "vendor-1",
            "printf PHAROS_OK",
            "approve-cmd",
            "reject-cmd",
            "device-1",
        );
        let md = request_markdown(&req, OffsetDateTime::now_utc());
        assert!(md.contains("timeout: 45 minutes"));
        assert!(md.contains("approve-cmd"));
        assert!(md.contains("reject-cmd"));
        assert!(md.contains("decision=allowedOnce|rejected"));
    }
}
