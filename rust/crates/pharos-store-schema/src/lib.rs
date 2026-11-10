//! RFC-007 Phase 0 on-disk schema contracts.
//!
//! Declares schema version, path conventions, table names, and SQL DDL for the
//! tables every stream may assume. Streams must not invent alternate table
//! names; schema changes require a Phase 0.x bump.

use serde::{Deserialize, Serialize};

/// Same freeze as `pharos-protocol::CONTRACTS_VERSION`.
pub const CONTRACTS_VERSION: &str = "0.1.0";

/// Monotonic on-disk schema integer. Bump with every incompatible DDL change.
pub const SCHEMA_VERSION: u32 = 1;

/// Filename of the schema migrations bookkeeping table.
pub const MIGRATIONS_TABLE: &str = "schema_migrations";

// ---------------------------------------------------------------------------
// Path conventions (relative to a Host data-dir)
// ---------------------------------------------------------------------------

pub mod paths {
    /// Default relative Runtime registry directory.
    pub const RUNTIME_DIR: &str = "runtime";
    /// Default relative mesh/replica SQLite directory.
    pub const MESH_DIR: &str = "mesh";
    /// Replica SQLite file name inside `MESH_DIR`.
    pub const REPLICA_DB: &str = "replica.sqlite3";
    /// Runtime registry JSON (existing pharos-meshd layout).
    pub const RUNTIME_REGISTRY: &str = "runtime/registry.json";
    /// Static Web UI root served by S4.
    pub const WEBUI_DIR: &str = "webui";
    /// Human-proxy request drop directory (tests use pharos-msg-test mirror).
    pub const HUMAN_REQUESTS_DIR: &str = "human-requests";
}

/// Well-known absolute config paths (Host-local, never logged with secrets).
pub mod host_config {
    pub const HUMAN_PROXY_WEBHOOK_ENV: &str = ".config/pharos/human-proxy-webhook.env";
}

// ---------------------------------------------------------------------------
// Table names (S1 Thread, S2 Session/HITL/Goals, S3 Replica, Runtime)
// ---------------------------------------------------------------------------

pub mod tables {
    pub const SCHEMA_MIGRATIONS: &str = "schema_migrations";
    // S3 / Thread durable mailbox
    pub const ROOMS: &str = "rooms";
    pub const MEMBERSHIPS: &str = "memberships";
    pub const MESSAGES: &str = "messages";
    pub const ATTACHMENTS: &str = "attachments";
    pub const TRUST_GROUPS: &str = "trust_groups";
    pub const DEVICE_IDENTITY: &str = "device_identity";
    // Runtime (may remain JSON initially; SQL names reserved for cutover)
    pub const DRIVERS: &str = "drivers";
    pub const CONVERSATIONS: &str = "conversations";
    pub const DELIVERIES: &str = "deliveries";
    // S2
    pub const SESSION_BINDINGS: &str = "session_bindings";
    pub const SESSION_GOALS: &str = "session_goals";
    pub const SESSION_TODOS: &str = "session_todos";
    pub const APPROVALS: &str = "approvals";
    // Projects (daemon-owned per RFC-007 Q8 default)
    pub const PROJECTS: &str = "projects";
    pub const PROJECT_CHECKOUTS: &str = "project_checkouts";
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SchemaMeta {
    pub contracts_version: String,
    pub schema_version: u32,
}

impl SchemaMeta {
    pub fn phase0() -> Self {
        Self {
            contracts_version: CONTRACTS_VERSION.to_string(),
            schema_version: SCHEMA_VERSION,
        }
    }
}

/// Ordered migrations for SCHEMA_VERSION = 1.
pub struct Migration {
    pub version: u32,
    pub name: &'static str,
    pub sql: &'static str,
}

pub const MIGRATIONS: &[Migration] = &[Migration {
    version: 1,
    name: "phase0_core",
    sql: PHASE0_DDL,
}];

/// Canonical DDL streams may apply. Implementations must not rename columns
/// without a schema_version bump.
pub const PHASE0_DDL: &str = r#"
CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS rooms (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL UNIQUE,
    created_at REAL NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS memberships (
    id TEXT PRIMARY KEY NOT NULL,
    room_id TEXT NOT NULL,
    member_id TEXT NOT NULL,
    nick TEXT NOT NULL,
    kind TEXT,
    deleted INTEGER NOT NULL DEFAULT 0,
    UNIQUE(room_id, member_id)
);

CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY NOT NULL,
    room_id TEXT NOT NULL,
    author_member_id TEXT,
    author_nick TEXT NOT NULL,
    text TEXT NOT NULL,
    ts REAL NOT NULL,
    reply_to_message_id TEXT,
    target_member_ids_json TEXT NOT NULL DEFAULT '[]',
    attachments_json TEXT NOT NULL DEFAULT '[]'
);

CREATE INDEX IF NOT EXISTS idx_messages_room_ts ON messages(room_id, ts);

CREATE TABLE IF NOT EXISTS attachments (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    content_type TEXT,
    size_bytes INTEGER,
    blob_path TEXT NOT NULL,
    created_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS trust_groups (
    id TEXT PRIMARY KEY NOT NULL,
    membership_epoch INTEGER NOT NULL DEFAULT 0,
    meta_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS device_identity (
    device_id TEXT PRIMARY KEY NOT NULL,
    public_key_pem TEXT NOT NULL,
    meta_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS drivers (
    id TEXT PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL,
    capabilities_json TEXT NOT NULL DEFAULT '[]',
    last_seen_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY NOT NULL,
    driver_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    member_id TEXT,
    vendor_session_id TEXT,
    state_json TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS deliveries (
    id TEXT PRIMARY KEY NOT NULL,
    conversation_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL UNIQUE,
    payload TEXT NOT NULL,
    state TEXT NOT NULL,
    detail TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS session_bindings (
    thread_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    member_id TEXT NOT NULL,
    nickname TEXT NOT NULL,
    PRIMARY KEY (thread_id, session_id)
);

CREATE TABLE IF NOT EXISTS session_goals (
    session_id TEXT PRIMARY KEY NOT NULL,
    objective TEXT NOT NULL,
    status TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS session_todos (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    text TEXT NOT NULL,
    status TEXT NOT NULL,
    priority TEXT,
    position INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_session_todos_session ON session_todos(session_id, position);

CREATE TABLE IF NOT EXISTS approvals (
    approval_id TEXT PRIMARY KEY NOT NULL,
    session_id TEXT NOT NULL,
    kind_json TEXT NOT NULL,
    available_choices_json TEXT,
    raw_vendor_json TEXT,
    resolved INTEGER NOT NULL DEFAULT 0,
    decision TEXT,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS projects (
    project_id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    project_path TEXT NOT NULL,
    meta_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS project_checkouts (
    host_device_id TEXT NOT NULL,
    project_id TEXT NOT NULL,
    checkout_path TEXT NOT NULL,
    PRIMARY KEY (host_device_id, project_id)
);
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phase0_meta() {
        let meta = SchemaMeta::phase0();
        assert_eq!(meta.contracts_version, "0.1.0");
        assert_eq!(meta.schema_version, 1);
    }

    #[test]
    fn migrations_cover_schema_version() {
        assert_eq!(MIGRATIONS.len(), 1);
        assert_eq!(MIGRATIONS[0].version, SCHEMA_VERSION);
        assert!(PHASE0_DDL.contains("CREATE TABLE IF NOT EXISTS messages"));
        assert!(PHASE0_DDL.contains("CREATE TABLE IF NOT EXISTS deliveries"));
        assert!(PHASE0_DDL.contains("CREATE TABLE IF NOT EXISTS session_goals"));
    }
}
