//! SQLite Thread store on PHASE0_DDL (`rooms` / `memberships` / `messages`).

use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use pharos_api::{
    ReplyThreadMessageRequest, ReplyThreadMessageResponse, SendThreadMessageRequest, ThreadMessage,
    ThreadReplyRef, ThreadSummary,
};
use pharos_protocol::{ThreadReceiptState, grokbot};
use pharos_store_schema::{PHASE0_DDL, SCHEMA_VERSION, paths};
use rusqlite::{Connection, OptionalExtension, params};
use uuid::Uuid;

use crate::error::ThreadError;
use crate::reply::{REPLY_ONCE_SCOPE_LOCAL, reply_once_id};
use crate::service::{SenderIdentity, ThreadService};
use crate::{CliReplyTo, CliThreadMessage, ThreadReadPayload, ThreadReplyPayload};

/// Resolve the replica DB path for a Host or mesh `--data-dir`.
///
/// CLI convention (Swift parity): `--data-dir` points at the mesh directory
/// and the DB is `replica.sqlite3` inside it. Host data-dir uses
/// `mesh/replica.sqlite3`.
pub fn resolve_db_path(data_dir: &Path) -> PathBuf {
    let direct = data_dir.join(paths::REPLICA_DB);
    let nested = data_dir.join(paths::MESH_DIR).join(paths::REPLICA_DB);
    if direct.exists() {
        return direct;
    }
    if nested.exists() {
        return nested;
    }
    if data_dir.join(paths::MESH_DIR).is_dir() || data_dir.join(paths::RUNTIME_DIR).is_dir() {
        nested
    } else {
        direct
    }
}

pub fn open_thread_db(data_dir: &Path) -> Result<SqliteThreadStore, ThreadError> {
    let path = resolve_db_path(data_dir);
    SqliteThreadStore::open(&path)
}

#[derive(Debug, Clone)]
pub struct StoredMessage {
    pub id: String,
    pub room_id: String,
    pub room_name: String,
    pub author_member_id: Option<String>,
    pub author_nick: String,
    pub text: String,
    pub ts: f64,
    pub reply_to_message_id: Option<String>,
    pub reply_to_from: Option<String>,
    pub reply_to_preview: Option<String>,
    pub target_member_ids: Vec<String>,
    pub to_nicks: Vec<String>,
}

pub struct SqliteThreadStore {
    conn: Mutex<Connection>,
    /// Trust-group / scope id for replyOnce hashing. S3 may replace with real UUID.
    scope_id: String,
}

impl SqliteThreadStore {
    pub fn open(path: &Path) -> Result<Self, ThreadError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| ThreadError::Store(format!("create db dir: {e}")))?;
        }
        let conn = Connection::open(path)?;
        let store = Self {
            conn: Mutex::new(conn),
            scope_id: REPLY_ONCE_SCOPE_LOCAL.to_string(),
        };
        store.migrate()?;
        Ok(store)
    }

    pub fn open_in_memory() -> Result<Self, ThreadError> {
        let conn = Connection::open_in_memory()?;
        let store = Self {
            conn: Mutex::new(conn),
            scope_id: REPLY_ONCE_SCOPE_LOCAL.to_string(),
        };
        store.migrate()?;
        Ok(store)
    }

    pub fn with_scope(mut self, scope_id: impl Into<String>) -> Self {
        self.scope_id = scope_id.into();
        self
    }

    fn lock(&self) -> Result<MutexGuard<'_, Connection>, ThreadError> {
        self.conn
            .lock()
            .map_err(|_| ThreadError::Store("db lock poisoned".into()))
    }

    fn migrate(&self) -> Result<(), ThreadError> {
        let conn = self.lock()?;
        conn.execute_batch(PHASE0_DDL)?;
        let applied: Option<u32> = conn
            .query_row(
                "SELECT version FROM schema_migrations WHERE version = ?1",
                params![SCHEMA_VERSION],
                |row| row.get(0),
            )
            .optional()?;
        if applied.is_none() {
            let now = rfc3339_now();
            conn.execute(
                "INSERT INTO schema_migrations (version, name, applied_at) VALUES (?1, ?2, ?3)",
                params![SCHEMA_VERSION, "phase0_core", now],
            )?;
        }
        Ok(())
    }

    /// Create a room by name (or return existing). Returns room id.
    pub fn ensure_room(&self, name: &str) -> Result<String, ThreadError> {
        let name = name.trim();
        if name.is_empty() {
            return Err(ThreadError::InvalidRequest("empty thread name".into()));
        }
        let conn = self.lock()?;
        if let Some(id) = Self::room_id_by_name(&conn, name)? {
            return Ok(id);
        }
        let id = Uuid::new_v4().to_string();
        let now = unix_secs();
        conn.execute(
            "INSERT INTO rooms (id, name, created_at, deleted) VALUES (?1, ?2, ?3, 0)",
            params![id, name, now],
        )?;
        Ok(id)
    }

    /// Join (or update nick for) a member in a room named `thread`.
    pub fn join(
        &self,
        thread: &str,
        member_id: &str,
        nick: &str,
        kind: Option<&str>,
    ) -> Result<(), ThreadError> {
        let room_id = self.ensure_room(thread)?;
        let conn = self.lock()?;
        let existing: Option<String> = conn
            .query_row(
                "SELECT id FROM memberships WHERE room_id = ?1 AND member_id = ?2",
                params![room_id, member_id],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(id) = existing {
            conn.execute(
                "UPDATE memberships SET nick = ?1, kind = ?2, deleted = 0 WHERE id = ?3",
                params![nick, kind, id],
            )?;
        } else {
            let id = Uuid::new_v4().to_string();
            conn.execute(
                "INSERT INTO memberships (id, room_id, member_id, nick, kind, deleted)
                 VALUES (?1, ?2, ?3, ?4, ?5, 0)",
                params![id, room_id, member_id, nick, kind],
            )?;
        }
        Ok(())
    }

    fn room_id_by_name(conn: &Connection, name: &str) -> Result<Option<String>, ThreadError> {
        Ok(conn
            .query_row(
                "SELECT id FROM rooms WHERE name = ?1 AND deleted = 0",
                params![name],
                |row| row.get(0),
            )
            .optional()?)
    }

    fn resolve_room(conn: &Connection, thread: &str) -> Result<(String, String), ThreadError> {
        // Accept either room name or room id.
        if let Some(id) = Self::room_id_by_name(conn, thread)? {
            return Ok((id, thread.to_string()));
        }
        let row: Option<(String, String)> = conn
            .query_row(
                "SELECT id, name FROM rooms WHERE id = ?1 AND deleted = 0",
                params![thread],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        row.ok_or_else(|| ThreadError::NotFound(thread.to_string()))
    }

    fn member_nick(
        conn: &Connection,
        room_id: &str,
        member_id: &str,
    ) -> Result<String, ThreadError> {
        conn.query_row(
            "SELECT nick FROM memberships WHERE room_id = ?1 AND member_id = ?2 AND deleted = 0",
            params![room_id, member_id],
            |row| row.get(0),
        )
        .optional()?
        .ok_or_else(|| ThreadError::MemberNotFound(member_id.to_string()))
    }

    fn load_messages(
        &self,
        thread: &str,
        limit: Option<u32>,
        since: Option<&str>,
    ) -> Result<Vec<StoredMessage>, ThreadError> {
        let conn = self.lock()?;
        let (room_id, room_name) = Self::resolve_room(&conn, thread)?;
        let lim = limit.unwrap_or(40).clamp(1, 200) as i64;
        let mut stmt = conn.prepare(
            "SELECT id, author_member_id, author_nick, text, ts, reply_to_message_id,
                    target_member_ids_json
             FROM messages WHERE room_id = ?1 ORDER BY ts ASC, id ASC",
        )?;
        let rows = stmt.query_map(params![room_id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, f64>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, String>(6)?,
            ))
        })?;
        let mut all = Vec::new();
        for row in rows {
            let (id, author_member_id, author_nick, text, ts, reply_to, targets_json) = row?;
            let target_member_ids: Vec<String> = serde_json::from_str(&targets_json)?;
            let mut to_nicks = Vec::new();
            for mid in &target_member_ids {
                if let Ok(nick) = Self::member_nick(&conn, &room_id, mid) {
                    to_nicks.push(nick);
                } else {
                    to_nicks.push(mid.clone());
                }
            }
            let (reply_to_from, reply_to_preview) = if let Some(ref rid) = reply_to {
                let meta: Option<(String, String)> = conn
                    .query_row(
                        "SELECT author_nick, text FROM messages WHERE id = ?1",
                        params![rid],
                        |r| Ok((r.get(0)?, r.get(1)?)),
                    )
                    .optional()?;
                match meta {
                    Some((from, preview)) => (Some(from), Some(preview)),
                    None => (None, None),
                }
            } else {
                (None, None)
            };
            all.push(StoredMessage {
                id,
                room_id: room_id.clone(),
                room_name: room_name.clone(),
                author_member_id,
                author_nick,
                text,
                ts,
                reply_to_message_id: reply_to,
                reply_to_from,
                reply_to_preview,
                target_member_ids,
                to_nicks,
            });
        }
        if let Some(since) = since.filter(|s| !s.is_empty())
            && let Some(idx) = all.iter().position(|m| m.id == since)
        {
            all = all.split_off(idx + 1);
        }
        if all.len() as i64 > lim {
            all = all.split_off(all.len() - lim as usize);
        }
        Ok(all)
    }

    #[allow(clippy::too_many_arguments)]
    fn insert_message(
        conn: &Connection,
        id: &str,
        room_id: &str,
        author_member_id: Option<&str>,
        author_nick: &str,
        text: &str,
        ts: f64,
        reply_to: Option<&str>,
        target_member_ids: &[String],
    ) -> Result<(), ThreadError> {
        let targets = serde_json::to_string(target_member_ids)?;
        conn.execute(
            "INSERT INTO messages (
                id, room_id, author_member_id, author_nick, text, ts,
                reply_to_message_id, target_member_ids_json, attachments_json
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, '[]')",
            params![
                id,
                room_id,
                author_member_id,
                author_nick,
                text,
                ts,
                reply_to,
                targets
            ],
        )?;
        Ok(())
    }

    fn to_cli(m: &StoredMessage) -> CliThreadMessage {
        CliThreadMessage {
            id: m.id.clone(),
            thread: m.room_name.clone(),
            from: m.author_nick.clone(),
            member_id: m.author_member_id.clone().unwrap_or_default(),
            text: m.text.clone(),
            ts: m.ts,
            to: m.to_nicks.clone(),
            target_member_ids: m.target_member_ids.clone(),
            reply_to: match (
                &m.reply_to_message_id,
                &m.reply_to_from,
                &m.reply_to_preview,
            ) {
                (Some(id), Some(from), Some(preview)) => Some(CliReplyTo {
                    message_id: id.clone(),
                    from: from.clone(),
                    preview: preview.clone(),
                }),
                _ => None,
            },
        }
    }

    fn to_api(m: &StoredMessage) -> ThreadMessage {
        ThreadMessage {
            id: m.id.clone(),
            thread_id: m.room_name.clone(),
            sender_id: m.author_member_id.clone().unwrap_or_default(),
            sender_name: m.author_nick.clone(),
            sender_avatar_seed: None,
            text: m.text.clone(),
            timestamp: format_ts(m.ts),
            receipt: ThreadReceiptState::Delivered,
            target_member_ids: m.target_member_ids.clone(),
            reply_to: match (
                &m.reply_to_message_id,
                &m.reply_to_from,
                &m.reply_to_preview,
            ) {
                (Some(id), Some(from), Some(preview)) => Some(ThreadReplyRef {
                    message_id: id.clone(),
                    sender_name: from.clone(),
                    preview: preview.clone(),
                }),
                _ => None,
            },
        }
    }

    fn reply_once_inner(
        &self,
        thread: &str,
        member_id: &str,
        original_message_id: &str,
        text: &str,
    ) -> Result<StoredMessage, ThreadError> {
        let text = text.trim();
        if text.is_empty() {
            return Err(ThreadError::EmptyReply);
        }
        let conn = self.lock()?;
        let (room_id, room_name) = Self::resolve_room(&conn, thread)?;
        let nick = Self::member_nick(&conn, &room_id, member_id)?;

        let original_row: Option<(Option<String>, String, String, String)> = conn
            .query_row(
                "SELECT author_member_id, author_nick, text, target_member_ids_json
                 FROM messages WHERE id = ?1 AND room_id = ?2",
                params![original_message_id, room_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;
        let Some((orig_author_id, orig_nick, orig_text, targets_json)) = original_row else {
            return Err(ThreadError::ReplyTargetMismatch);
        };
        let targets: Vec<String> = serde_json::from_str(&targets_json)?;
        if !targets.contains(&member_id.to_string()) || orig_author_id.as_deref() == Some(member_id)
        {
            return Err(ThreadError::ReplyTargetMismatch);
        }

        let reply_id = reply_once_id(&self.scope_id, &room_id, member_id, original_message_id);
        if let Some(existing) = Self::load_one(&conn, &reply_id)? {
            if existing.author_member_id.as_deref() != Some(member_id)
                || existing.reply_to_message_id.as_deref() != Some(original_message_id)
                || existing.text != text
            {
                return Err(ThreadError::ReplyConflict(reply_id));
            }
            return Ok(existing);
        }

        let ts = unix_secs();
        Self::insert_message(
            &conn,
            &reply_id,
            &room_id,
            Some(member_id),
            &nick,
            text,
            ts,
            Some(original_message_id),
            &[],
        )?;
        Ok(StoredMessage {
            id: reply_id,
            room_id,
            room_name,
            author_member_id: Some(member_id.to_string()),
            author_nick: nick,
            text: text.to_string(),
            ts,
            reply_to_message_id: Some(original_message_id.to_string()),
            reply_to_from: Some(orig_nick),
            reply_to_preview: Some(orig_text),
            target_member_ids: vec![],
            to_nicks: vec![],
        })
    }

    fn load_one(conn: &Connection, id: &str) -> Result<Option<StoredMessage>, ThreadError> {
        type MsgRow = (
            String,
            String,
            Option<String>,
            String,
            String,
            f64,
            Option<String>,
            String,
            String,
        );
        let row: Option<MsgRow> = conn
            .query_row(
                "SELECT m.id, r.name, m.author_member_id, m.author_nick, m.text, m.ts,
                        m.reply_to_message_id, m.target_member_ids_json, m.room_id
                 FROM messages m JOIN rooms r ON r.id = m.room_id WHERE m.id = ?1",
                params![id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                        row.get(6)?,
                        row.get(7)?,
                        row.get(8)?,
                    ))
                },
            )
            .optional()?;
        let Some((id, room_name, amid, anick, text, ts, reply, tj, room_id)) = row else {
            return Ok(None);
        };
        let target_member_ids: Vec<String> = serde_json::from_str(&tj)?;
        let (reply_to_from, reply_to_preview) = if let Some(ref rid) = reply {
            let meta: Option<(String, String)> = conn
                .query_row(
                    "SELECT author_nick, text FROM messages WHERE id = ?1",
                    params![rid],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            match meta {
                Some((f, p)) => (Some(f), Some(p)),
                None => (None, None),
            }
        } else {
            (None, None)
        };
        Ok(Some(StoredMessage {
            id,
            room_id,
            room_name,
            author_member_id: amid,
            author_nick: anick,
            text,
            ts,
            reply_to_message_id: reply,
            reply_to_from,
            reply_to_preview,
            target_member_ids,
            to_nicks: vec![],
        }))
    }
}

impl ThreadService for SqliteThreadStore {
    fn list_threads(&self) -> Result<Vec<ThreadSummary>, ThreadError> {
        let conn = self.lock()?;
        let mut stmt =
            conn.prepare("SELECT id, name FROM rooms WHERE deleted = 0 ORDER BY name ASC")?;
        let rooms: Vec<(String, String)> = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect::<Result<_, _>>()?;
        let mut out = Vec::new();
        for (room_id, name) in rooms {
            let mut mstmt = conn.prepare(
                "SELECT member_id FROM memberships WHERE room_id = ?1 AND deleted = 0 ORDER BY nick ASC",
            )?;
            let member_ids: Vec<String> = mstmt
                .query_map(params![room_id], |row| row.get(0))?
                .collect::<Result<_, _>>()?;
            let last: f64 = conn
                .query_row(
                    "SELECT COALESCE(MAX(ts), 0) FROM messages WHERE room_id = ?1",
                    params![room_id],
                    |row| row.get(0),
                )
                .unwrap_or(0.0);
            let _ = room_id;
            out.push(ThreadSummary {
                thread_id: name.clone(),
                title: name,
                member_ids,
                unread_count: 0,
                last_activity_at: format_ts(last),
            });
        }
        Ok(out)
    }

    fn get_thread(&self, thread: &str) -> Result<ThreadSummary, ThreadError> {
        self.list_threads()?
            .into_iter()
            .find(|t| t.thread_id == thread)
            .ok_or_else(|| ThreadError::NotFound(thread.to_string()))
    }

    fn list_messages(
        &self,
        thread: &str,
        limit: Option<u32>,
        since: Option<&str>,
    ) -> Result<Vec<ThreadMessage>, ThreadError> {
        Ok(self
            .load_messages(thread, limit, since)?
            .iter()
            .map(Self::to_api)
            .collect())
    }

    fn send_message(
        &self,
        thread: &str,
        sender: &SenderIdentity,
        req: SendThreadMessageRequest,
    ) -> Result<ThreadMessage, ThreadError> {
        let text = req.text.trim();
        if text.is_empty() {
            return Err(ThreadError::InvalidRequest("empty text".into()));
        }
        let conn = self.lock()?;
        let (room_id, room_name) = Self::resolve_room(&conn, thread)?;
        let nick = Self::member_nick(&conn, &room_id, &sender.member_id)
            .unwrap_or_else(|_| sender.nick.clone());
        let id = Uuid::new_v4().to_string();
        let ts = unix_secs();
        Self::insert_message(
            &conn,
            &id,
            &room_id,
            Some(&sender.member_id),
            &nick,
            text,
            ts,
            req.reply_to_message_id.as_deref(),
            &req.target_member_ids,
        )?;
        drop(conn);
        let stored = self
            .load_messages(thread, Some(200), None)?
            .into_iter()
            .find(|m| m.id == id)
            .ok_or_else(|| ThreadError::Store("insert missing".into()))?;
        let _ = room_name;
        Ok(Self::to_api(&stored))
    }

    fn reply_message(
        &self,
        thread: &str,
        req: ReplyThreadMessageRequest,
    ) -> Result<ReplyThreadMessageResponse, ThreadError> {
        let original = match req.message_id.as_deref() {
            Some(id) if !id.is_empty() => id.to_string(),
            _ => {
                let history = self.load_messages(thread, Some(80), None)?;
                let unreplied = history.iter().rev().find(|m| {
                    m.target_member_ids.contains(&req.as_member)
                        && !history.iter().any(|r| {
                            r.author_member_id.as_deref() == Some(req.as_member.as_str())
                                && r.reply_to_message_id.as_deref() == Some(m.id.as_str())
                        })
                });
                unreplied.map(|m| m.id.clone()).ok_or_else(|| {
                    ThreadError::InvalidRequest(
                        "no unreplied directed message; pass messageId".into(),
                    )
                })?
            }
        };
        let stored = self.reply_once_inner(thread, &req.as_member, &original, &req.text)?;
        Ok(ReplyThreadMessageResponse {
            ok: true,
            thread: thread.to_string(),
            as_member: req.as_member,
            reply_id: stored.id,
            reply_to: original,
        })
    }

    fn cli_read(
        &self,
        thread: &str,
        limit: Option<u32>,
        since: Option<&str>,
    ) -> Result<ThreadReadPayload, ThreadError> {
        let messages = self
            .load_messages(thread, limit, since)?
            .iter()
            .map(Self::to_cli)
            .collect();
        Ok(ThreadReadPayload {
            thread: thread.to_string(),
            member: grokbot::MEMBER_ID.to_string(),
            nick: grokbot::DISPLAY_NICK.to_string(),
            messages,
        })
    }

    fn cli_reply(
        &self,
        thread: &str,
        as_member: &str,
        text: &str,
        message_id: Option<&str>,
    ) -> Result<ThreadReplyPayload, ThreadError> {
        if as_member != grokbot::MEMBER_ID {
            return Err(ThreadError::InvalidRequest(format!(
                "thread reply --as currently supports only {}",
                grokbot::MEMBER_ID
            )));
        }
        let resp = self.reply_message(
            thread,
            ReplyThreadMessageRequest {
                as_member: as_member.to_string(),
                text: text.to_string(),
                message_id: message_id.map(str::to_string),
            },
        )?;
        Ok(ThreadReplyPayload {
            ok: resp.ok,
            thread: resp.thread,
            as_member: resp.as_member,
            reply_id: resp.reply_id,
            reply_to: resp.reply_to,
        })
    }

    fn history_for_bridge(
        &self,
        thread: &str,
        limit: u32,
    ) -> Result<Vec<CliThreadMessage>, ThreadError> {
        Ok(self
            .load_messages(thread, Some(limit), None)?
            .iter()
            .map(Self::to_cli)
            .collect())
    }
}

fn unix_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn rfc3339_now() -> String {
    // Minimal RFC3339 without pulling time crate into this crate's API path.
    let secs = unix_secs() as i64;
    format!("{secs}")
}

fn format_ts(ts: f64) -> String {
    // API wants RFC3339; keep a stable numeric-derived string when time crate
    // formatting is unavailable. S4 may pretty-print.
    if ts <= 0.0 {
        return "1970-01-01T00:00:00Z".into();
    }
    let secs = ts.floor() as i64;
    let nanos = ((ts - secs as f64) * 1_000_000_000.0) as u32;
    // Manual UTC format is enough for store timestamps in tests.
    use std::time::{Duration, UNIX_EPOCH};
    let _ = UNIX_EPOCH + Duration::new(secs as u64, nanos);
    format!("{secs}.{nanos:09}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use pharos_api::SendThreadMessageRequest;

    fn seeded() -> SqliteThreadStore {
        let store = SqliteThreadStore::open_in_memory().unwrap();
        store.join("t1", "human", "Human", Some("human")).unwrap();
        store
            .join(
                "t1",
                grokbot::MEMBER_ID,
                grokbot::DISPLAY_NICK,
                Some(grokbot::AGENT_KIND),
            )
            .unwrap();
        store
    }

    #[test]
    fn send_and_reply_once_idempotent() {
        let store = seeded();
        let msg = store
            .send_message(
                "t1",
                &SenderIdentity {
                    member_id: "human".into(),
                    nick: "Human".into(),
                },
                SendThreadMessageRequest {
                    text: "@Pharos hi".into(),
                    target_member_ids: vec![grokbot::MEMBER_ID.into()],
                    reply_to_message_id: None,
                },
            )
            .unwrap();
        let r1 = store
            .cli_reply("t1", grokbot::MEMBER_ID, "ack", Some(&msg.id))
            .unwrap();
        let r2 = store
            .cli_reply("t1", grokbot::MEMBER_ID, "ack", Some(&msg.id))
            .unwrap();
        assert_eq!(r1.reply_id, r2.reply_id);
        assert!(r1.reply_id.starts_with("reply-"));
        let conflict = store.cli_reply("t1", grokbot::MEMBER_ID, "other", Some(&msg.id));
        assert!(matches!(conflict, Err(ThreadError::ReplyConflict(_))));
    }

    #[test]
    fn cli_read_respects_since_and_limit() {
        let store = seeded();
        let sender = SenderIdentity {
            member_id: "human".into(),
            nick: "Human".into(),
        };
        let a = store
            .send_message(
                "t1",
                &sender,
                SendThreadMessageRequest {
                    text: "one".into(),
                    target_member_ids: vec![],
                    reply_to_message_id: None,
                },
            )
            .unwrap();
        let _b = store
            .send_message(
                "t1",
                &sender,
                SendThreadMessageRequest {
                    text: "two".into(),
                    target_member_ids: vec![],
                    reply_to_message_id: None,
                },
            )
            .unwrap();
        let read = store.cli_read("t1", Some(10), Some(&a.id)).unwrap();
        assert_eq!(read.messages.len(), 1);
        assert_eq!(read.messages[0].text, "two");
        assert_eq!(read.member, "grokbot");
        assert_eq!(read.nick, "Pharos");
    }

    #[test]
    fn unreplied_directed_auto_select() {
        let store = seeded();
        let msg = store
            .send_message(
                "t1",
                &SenderIdentity {
                    member_id: "human".into(),
                    nick: "Human".into(),
                },
                SendThreadMessageRequest {
                    text: "@Pharos ping".into(),
                    target_member_ids: vec![grokbot::MEMBER_ID.into()],
                    reply_to_message_id: None,
                },
            )
            .unwrap();
        let reply = store
            .cli_reply("t1", grokbot::MEMBER_ID, "pong", None)
            .unwrap();
        assert_eq!(reply.reply_to, msg.id);
    }
}
